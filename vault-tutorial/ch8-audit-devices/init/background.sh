#!/bin/bash
set +e

source /root/setup-common.sh

install_vault &
INSTALL_VAULT_PID=$!

apt-get update -qq
apt-get install -y -qq jq rsyslog socat > /dev/null 2>&1

wait "$INSTALL_VAULT_PID"

mkdir -p /opt/vault/data
chmod 700 /opt/vault/data
mkdir -p /var/log/vault
chmod 755 /var/log/vault

cat > /root/vault.hcl <<'EOF'
ui            = false
disable_mlock = true
cluster_name  = "vault-audit-classroom"
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

# 启动 rsyslog，并把 local0 facility 单独引到一份方便观察的文件中。
cat > /etc/rsyslog.d/49-vault-audit.conf <<'EOF'
local0.* /var/log/vault/vault-audit.syslog
EOF
service rsyslog restart > /dev/null 2>&1
touch /var/log/vault/vault-audit.syslog
chmod 644 /var/log/vault/vault-audit.syslog

touch /tmp/.setup-done
