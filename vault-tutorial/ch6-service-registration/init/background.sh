#!/bin/bash
set +e

source /root/setup-common.sh

install_vault &
INSTALL_VAULT_PID=$!

# 安装 Consul（dev 模式即可，不依赖 ACL 与 TLS）。
install_consul() {
  if command -v consul > /dev/null 2>&1; then
    return 0
  fi
  if ! command -v unzip > /dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq unzip > /dev/null 2>&1
  fi
  CONSUL_VERSION="${CONSUL_VERSION:-1.19.2}"
  curl --connect-timeout 10 --max-time 120 -fsSL \
    "https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_amd64.zip" \
    -o /tmp/consul.zip \
    && unzip -o -q /tmp/consul.zip -d /usr/local/bin/ \
    && chmod +x /usr/local/bin/consul \
    && rm -f /tmp/consul.zip
  consul version || echo "WARNING: consul install failed"
}

install_consul &
INSTALL_CONSUL_PID=$!

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi
if ! command -v dig > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq dnsutils > /dev/null 2>&1
fi

wait "$INSTALL_VAULT_PID"
wait "$INSTALL_CONSUL_PID"

for n in 1 2 3; do
  mkdir -p /opt/vault/data-${n}
  chmod 700 /opt/vault/data-${n}
done

# 三份 vault.hcl：每个节点都加入 service_registration "consul" 块，
# 使其在 Consul 服务目录中以服务名 "vault" 注册自身。
write_node_config() {
  local n=$1
  local api_port=$2
  local cluster_port=$3
  local retry_join_block=$4

  cat > /root/vault-${n}.hcl <<EOF
ui            = true
disable_mlock = true
cluster_name  = "vault-sd-classroom"
log_level     = "info"
pid_file      = "/tmp/vault-${n}.pid"

api_addr      = "http://127.0.0.1:${api_port}"
cluster_addr  = "http://127.0.0.1:${cluster_port}"

storage "raft" {
  path    = "/opt/vault/data-${n}"
  node_id = "node-${n}"
${retry_join_block}
}

listener "tcp" {
  address         = "127.0.0.1:${api_port}"
  cluster_address = "127.0.0.1:${cluster_port}"
  tls_disable     = true
}

service_registration "consul" {
  address = "127.0.0.1:8500"
}
EOF
}

write_node_config 1 8200 8201 ""
write_node_config 2 8210 8211 '
  retry_join {
    leader_api_addr = "http://127.0.0.1:8200"
  }'
write_node_config 3 8220 8221 '
  retry_join {
    leader_api_addr = "http://127.0.0.1:8200"
  }'

cat > /etc/profile.d/vault.sh <<'EOF'
export VAULT_ADDR='http://127.0.0.1:8200'
EOF
chmod +x /etc/profile.d/vault.sh
grep -q "VAULT_ADDR=" /root/.bashrc 2>/dev/null || \
  cat /etc/profile.d/vault.sh >> /root/.bashrc

cat > /root/start-consul.sh <<'EOF'
#!/bin/bash
# 在后台以 dev 模式启动 Consul，HTTP API 监听 8500，DNS 监听 8600。
nohup consul agent -dev \
  -client=127.0.0.1 \
  -bind=127.0.0.1 \
  > /var/log/consul.log 2>&1 &

echo "等待 Consul 就绪 ..."
for i in $(seq 1 30); do
  if curl -sS http://127.0.0.1:8500/v1/status/leader 2>/dev/null | grep -q ':'; then
    echo "Consul 已就绪。"
    exit 0
  fi
  sleep 1
done
echo "WARNING: Consul 30 秒内未就绪"
tail -n 30 /var/log/consul.log
EOF
chmod +x /root/start-consul.sh

cat > /root/start-node.sh <<'EOF'
#!/bin/bash
n=$1
if [ -z "$n" ]; then
  echo "用法：$0 <1|2|3>"
  exit 1
fi
nohup vault server -config=/root/vault-${n}.hcl > /var/log/vault-${n}.log 2>&1 &
echo "node-${n} 已启动，日志：/var/log/vault-${n}.log"
EOF
chmod +x /root/start-node.sh

cd /root
finish_setup
