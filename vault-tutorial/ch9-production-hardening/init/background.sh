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

# 单节点 Vault：raft 存储 + transit 引擎；不在配置文件里声明任何速率限流，
# 由学员在 step1 中通过 `vault write sys/quotas/rate-limit/...` 现场创建。
cat > /root/vault.hcl <<'EOF'
ui            = false
disable_mlock = true
cluster_name  = "vault-rate-limit-classroom"
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
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
echo "vault 已启动，日志：/var/log/vault.log"
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
echo "vault 已停止"
EOF
chmod +x /root/stop-vault.sh

touch /tmp/.setup-done
