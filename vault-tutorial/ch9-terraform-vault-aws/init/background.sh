#!/bin/bash
set +e

if [ ! -f /root/setup-common.sh ]; then
  echo "ERROR: /root/setup-common.sh not found. Did sync-setup copy scenario assets?" >&2
  exit 1
fi

source /root/setup-common.sh

TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.8.5}"
LAB_DIR="/root/terraform-vault-aws-localstack"
LOCALSTACK_ENDPOINT="http://127.0.0.1:4566"

# Install apt packages serially before any background install function runs.
apt-get update -qq && apt-get install -y -qq jq curl unzip ca-certificates > /dev/null 2>&1

if ! command -v docker > /dev/null 2>&1; then
  apt-get install -y -qq docker.io > /dev/null 2>&1
fi

install_terraform() {
  if command -v terraform > /dev/null 2>&1 \
     && terraform version -json 2>/dev/null | jq -e --arg v "$TERRAFORM_VERSION" '.terraform_version == $v' > /dev/null 2>&1; then
    echo "terraform ${TERRAFORM_VERSION} already installed, skipping download."
    return 0
  fi

  curl --connect-timeout 10 --max-time 180 -fsSL \
    "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
    -o /tmp/terraform.zip \
    && unzip -o -q /tmp/terraform.zip -d /usr/local/bin/ \
    && chmod +x /usr/local/bin/terraform \
    && rm -f /tmp/terraform.zip

  terraform version || echo "WARNING: terraform install failed"
}

install_vault &
INSTALL_VAULT_PID=$!
install_awscli &
INSTALL_AWS_PID=$!
install_terraform &
INSTALL_TERRAFORM_PID=$!
docker pull localstack/localstack:3 > /dev/null 2>&1 &
PULL_LOCALSTACK_PID=$!

wait "$INSTALL_VAULT_PID"
wait "$INSTALL_AWS_PID" 2>/dev/null
wait "$INSTALL_TERRAFORM_PID" 2>/dev/null
wait "$PULL_LOCALSTACK_PID" 2>/dev/null

start_vault_dev

docker rm -f localstack > /dev/null 2>&1 || true
docker run -d --name localstack \
  -p 4566:4566 \
  -e SERVICES=iam,sts,ec2 \
  -e ENFORCE_IAM=1 \
  -e DEBUG=0 \
  localstack/localstack:3 > /dev/null

echo "Waiting for LocalStack IAM/STS/EC2 ready..."
for i in $(seq 1 90); do
  if curl -s ${LOCALSTACK_ENDPOINT}/_localstack/health 2>/dev/null \
       | jq -e '.services.iam == "available" and .services.sts == "available" and .services.ec2 == "available"' > /dev/null 2>&1; then
    echo "LocalStack ready."
    break
  fi
  sleep 1
done

cat > /etc/profile.d/aws.sh <<'EOF'
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""
EOF
chmod +x /etc/profile.d/aws.sh
grep -q "AWS_ACCESS_KEY_ID=" /root/.bashrc 2>/dev/null || cat /etc/profile.d/aws.sh >> /root/.bashrc

create_lab_files() {
  rm -rf "$LAB_DIR"
  mkdir -p "$LAB_DIR/vault-admin-workspace" "$LAB_DIR/operator-workspace"

  cat > "$LAB_DIR/vault-admin-workspace/versions.tf" <<'EOF'
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.7.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "3.17.0"
    }
  }

  backend "local" {
    path = "terraform.tfstate"
  }
}
EOF

  cat > "$LAB_DIR/vault-admin-workspace/variables.tf" <<'EOF'
variable "project_name" {
  type        = string
  description = "Name of this project."
  default     = "dynamic-aws-creds-vault"
}

variable "region" {
  type        = string
  description = "AWS region for all resources."
  default     = "us-east-1"
}

variable "localstack_endpoint" {
  type        = string
  description = "LocalStack edge endpoint used by Terraform and Vault."
  default     = "http://127.0.0.1:4566"
}

variable "aws_access_key" {
  type        = string
  description = "Root AWS access key used by the admin workspace."
  default     = "test"
}

variable "aws_secret_key" {
  type        = string
  description = "Root AWS secret key used by the admin workspace."
  sensitive   = true
  default     = "test"
}
EOF

  cat > "$LAB_DIR/vault-admin-workspace/main.tf" <<'EOF'
provider "aws" {
  region     = var.region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2 = var.localstack_endpoint
    iam = var.localstack_endpoint
    sts = var.localstack_endpoint
  }
}

provider "vault" {}

resource "aws_iam_user" "secrets_engine" {
  name = "${var.project_name}-user"
}

resource "aws_iam_access_key" "secrets_engine_credentials" {
  user = aws_iam_user.secrets_engine.name
}

resource "aws_iam_user_policy" "secrets_engine" {
  user = aws_iam_user.secrets_engine.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["iam:*"]
        Resource = "*"
      }
    ]
  })
}

resource "vault_aws_secret_backend" "aws" {
  region = var.region
  path   = "${var.project_name}-path"

  access_key = aws_iam_access_key.secrets_engine_credentials.id
  secret_key = aws_iam_access_key.secrets_engine_credentials.secret

  iam_endpoint = var.localstack_endpoint
  sts_endpoint = var.localstack_endpoint

  default_lease_ttl_seconds = 120
  max_lease_ttl_seconds     = 300
}

resource "vault_aws_secret_backend_role" "admin" {
  backend         = vault_aws_secret_backend.aws.path
  name            = "${var.project_name}-role"
  credential_type = "iam_user"

  policy_document = <<EOP
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "iam:*", "ec2:*"
      ],
      "Resource": "*"
    }
  ]
}
EOP
}
EOF

  cat > "$LAB_DIR/vault-admin-workspace/outputs.tf" <<'EOF'
output "backend" {
  value = vault_aws_secret_backend.aws.path
}

output "role" {
  value = vault_aws_secret_backend_role.admin.name
}
EOF

  cat > "$LAB_DIR/operator-workspace/versions.tf" <<'EOF'
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.7.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "3.17.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "2.3.3"
    }
  }

  backend "local" {
    path = "terraform.tfstate"
  }
}
EOF

  cat > "$LAB_DIR/operator-workspace/variables.tf" <<'EOF'
variable "project_name" {
  type        = string
  description = "Name of the operator example project."
  default     = "dynamic-aws-creds-operator"
}

variable "region" {
  type        = string
  description = "AWS region for all resources."
  default     = "us-east-1"
}

variable "vault_state_path" {
  type        = string
  description = "Path to the state file of vault admin workspace."
  default     = "../vault-admin-workspace/terraform.tfstate"
}

variable "ttl" {
  type        = string
  description = "Value for TTL tag."
  default     = "1"
}

variable "localstack_endpoint" {
  type        = string
  description = "LocalStack edge endpoint used by Terraform."
  default     = "http://127.0.0.1:4566"
}

variable "apply_delay" {
  type        = string
  description = "Artificial delay after Vault credentials are read, used to demonstrate lease expiration."
  default     = "0s"
}
EOF

  cat > "$LAB_DIR/operator-workspace/main.tf" <<'EOF'
provider "vault" {}

data "terraform_remote_state" "admin" {
  backend = "local"

  config = {
    path = var.vault_state_path
  }
}

data "vault_aws_access_credentials" "creds" {
  backend = data.terraform_remote_state.admin.outputs.backend
  role    = data.terraform_remote_state.admin.outputs.role
}

data "external" "after_vault_credentials_delay" {
  program = ["bash", "${path.module}/delay.sh", var.apply_delay]

  depends_on = [data.vault_aws_access_credentials.creds]
}

provider "aws" {
  region     = var.region
  access_key = data.vault_aws_access_credentials.creds.access_key
  secret_key = data.vault_aws_access_credentials.creds.secret_key

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2 = var.localstack_endpoint
    iam = var.localstack_endpoint
    sts = var.localstack_endpoint
  }
}

data "aws_availability_zones" "available" {
  state = "available"

  depends_on = [data.external.after_vault_credentials_delay]
}

resource "aws_instance" "main" {
  ami               = "ami-ff0fea8310f3"
  instance_type     = "t2.micro"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name  = "${var.project_name}-instance"
    TTL   = var.ttl
    Owner = "${var.project_name}-guide"
  }
}

output "instance_id" {
  value = aws_instance.main.id
}
EOF

  cat > "$LAB_DIR/operator-workspace/delay.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

duration="${1:-0s}"
sleep "$duration"
printf '{"slept":"%s"}\n' "$duration"
EOF
  chmod +x "$LAB_DIR/operator-workspace/delay.sh"
}

create_lab_files

cd /root
finish_setup