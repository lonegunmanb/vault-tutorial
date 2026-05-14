#!/bin/bash
set +e

source /root/setup-common.sh

install_vault &
INSTALL_VAULT_PID=$!

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

wait "$INSTALL_VAULT_PID"

mkdir -p /opt/vault/data
chmod 700 /opt/vault/data

# 情景一专用：故意漏掉 cluster_addr 的 raft 配置——用于演示
# "Cluster address must be set when using raft storage" 报错。
cat > /root/vault-broken.hcl <<'EOF'
ui            = false
disable_mlock = true
cluster_name  = "vault-troubleshoot-classroom"
log_level     = "info"
pid_file      = "/tmp/vault.pid"

# 故意只设置 api_addr、不设置 cluster_addr。
api_addr      = "http://127.0.0.1:8200"

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "node-1"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}
EOF

# 情景一修复后专用：在 vault-broken.hcl 基础上补上 cluster_addr。
cat > /root/vault-fixed.hcl <<'EOF'
ui            = false
disable_mlock = true
cluster_name  = "vault-troubleshoot-classroom"
log_level     = "info"
pid_file      = "/tmp/vault.pid"

api_addr      = "http://127.0.0.1:8200"
cluster_addr  = "http://127.0.0.1:8201"

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "node-1"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}
EOF

cat > /etc/profile.d/vault.sh <<'EOF'
export VAULT_ADDR='http://127.0.0.1:8200'
EOF
chmod +x /etc/profile.d/vault.sh
grep -q "VAULT_ADDR=" /root/.bashrc 2>/dev/null || \
  cat /etc/profile.d/vault.sh >> /root/.bashrc

cat > /root/start-vault.sh <<'EOF'
#!/bin/bash
# 用法：./start-vault.sh <config-file>
CONFIG="${1:-/root/vault-fixed.hcl}"
nohup vault server -config="${CONFIG}" > /var/log/vault.log 2>&1 &
echo "vault 已启动，配置=${CONFIG}，日志=/var/log/vault.log"
EOF
chmod +x /root/start-vault.sh

cat > /root/stop-vault.sh <<'EOF'
#!/bin/bash
if [ -f /tmp/vault.pid ]; then
  kill "$(cat /tmp/vault.pid)" 2>/dev/null
  sleep 1
fi
pkill -f "vault server" 2>/dev/null
sleep 1
# 清理 raft 数据目录，便于重复实验。
rm -rf /opt/vault/data/* 2>/dev/null
echo "vault 已停止，数据目录已清理"
EOF
chmod +x /root/stop-vault.sh

touch /tmp/.setup-done
