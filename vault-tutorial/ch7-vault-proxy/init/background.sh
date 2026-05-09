#!/bin/bash
source /root/setup-common.sh

install_vault

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq curl > /dev/null 2>&1
fi

start_vault_dev

vault kv put secret/proxy73/app username="proxy73-demo" password="proxy73-password" > /dev/null
vault kv put secret/proxy73/other username="other" password="not-for-proxy" > /dev/null

vault auth enable approle > /dev/null

cat > /root/proxy73-app-read.hcl <<'EOF'
path "secret/data/proxy73/app" {
  capabilities = ["read"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}
EOF

cat > /root/proxy73-no-read.hcl <<'EOF'
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
EOF

vault policy write proxy73-app-read /root/proxy73-app-read.hcl > /dev/null
vault policy write proxy73-no-read /root/proxy73-no-read.hcl > /dev/null

vault write auth/approle/role/proxy73-app \
  token_policies="proxy73-app-read" \
  token_ttl="30m" \
  token_max_ttl="2h" \
  token_num_uses=0 > /dev/null

vault read -field=role_id auth/approle/role/proxy73-app/role-id > /root/proxy73-role-id
vault write -field=secret_id -force auth/approle/role/proxy73-app/secret-id > /root/proxy73-secret-id
chmod 600 /root/proxy73-role-id /root/proxy73-secret-id

vault token create -policy=proxy73-no-read -ttl=30m -field=token > /root/no-read-token
chmod 600 /root/no-read-token

cat > /root/proxy-config-true.hcl <<'EOF'
pid_file = "/tmp/proxy-true.pid"
log_level = "info"

vault {
  address = "http://127.0.0.1:8200"
  retry {
    num_retries = 3
  }
}

auto_auth {
  method {
    type       = "approle"
    mount_path = "auth/approle"

    config = {
      role_id_file_path                   = "/root/proxy73-role-id"
      secret_id_file_path                 = "/root/proxy73-secret-id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink {
    type = "file"
    config = {
      path = "/root/proxy73-true-token"
    }
  }
}

cache {}

api_proxy {
  use_auto_auth_token = true
}

listener "tcp" {
  address                = "127.0.0.1:8100"
  tls_disable            = true
  require_request_header = true
}
EOF

cat > /root/proxy-config-force.hcl <<'EOF'
pid_file = "/tmp/proxy-force.pid"
log_level = "info"

vault {
  address = "http://127.0.0.1:8200"
  retry {
    num_retries = 3
  }
}

auto_auth {
  method {
    type       = "approle"
    mount_path = "auth/approle"

    config = {
      role_id_file_path                   = "/root/proxy73-role-id"
      secret_id_file_path                 = "/root/proxy73-secret-id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink {
    type = "file"
    config = {
      path = "/root/proxy73-force-token"
    }
  }
}

cache {}

api_proxy {
  use_auto_auth_token = "force"
}

listener "tcp" {
  address                = "127.0.0.1:8101"
  tls_disable            = true
  require_request_header = true
}
EOF

cat > /root/proxy-k8s-persistent-cache.hcl <<'EOF'
vault {
  address = "https://vault.vault.svc:8200"
}

auto_auth {
  method {
    type       = "kubernetes"
    mount_path = "auth/kubernetes"
    config = {
      role = "proxy-sidecar"
    }
  }
}

cache {
  persist "kubernetes" {
    path                       = "/vault/proxy-cache"
    keep_after_import          = true
    exit_on_err                = true
    service_account_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
  }
}

api_proxy {
  use_auto_auth_token = "force"
}

listener "tcp" {
  address                = "127.0.0.1:8100"
  tls_disable            = true
  require_request_header = true
}
EOF

cat > /root/proxy-k8s-init.hcl <<'EOF'
exit_after_auth = true

vault {
  address = "https://vault.vault.svc:8200"
}

auto_auth {
  method {
    type       = "kubernetes"
    mount_path = "auth/kubernetes"
    config = {
      role = "proxy-sidecar"
    }
  }
}

cache {
  persist "kubernetes" {
    path                       = "/vault/proxy-cache"
    keep_after_import          = true
    exit_on_err                = true
    service_account_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
  }
}
EOF

cat > /root/proxy-k8s-pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: proxy-persistent-cache-model
spec:
  serviceAccountName: proxy-sidecar
  volumes:
    - name: proxy-cache
      emptyDir:
        medium: Memory
    - name: proxy-config
      configMap:
        name: proxy-config
  initContainers:
    - name: proxy-init
      image: hashicorp/vault:1.19.2
      args: ["proxy", "-config=/vault/config/proxy-init.hcl"]
      volumeMounts:
        - name: proxy-cache
          mountPath: /vault/proxy-cache
        - name: proxy-config
          mountPath: /vault/config
  containers:
    - name: app
      image: curlimages/curl:8.8.0
      command: ["sh", "-c", "sleep 3600"]
    - name: vault-proxy
      image: hashicorp/vault:1.19.2
      args: ["proxy", "-config=/vault/config/proxy-sidecar.hcl"]
      ports:
        - containerPort: 8100
      volumeMounts:
        - name: proxy-cache
          mountPath: /vault/proxy-cache
        - name: proxy-config
          mountPath: /vault/config
EOF

cd /root
finish_setup