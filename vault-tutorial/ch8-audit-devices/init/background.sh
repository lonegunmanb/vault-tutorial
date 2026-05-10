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
# Killercoda Ubuntu 的两个坑：
#   1. /dev/log 被 systemd-journald 的 syslog.socket 占用，rsyslog 收不到消息；
#   2. rsyslog 默认 PrivDrop 到 syslog 用户，对自定义日志路径无写权限。
# 下面一次性消除这两个问题，让 logger 与 vault 的 syslog 审计都能落盘。
cat > /etc/rsyslog.d/49-vault-audit.conf <<'EOF'
local0.* /var/log/vault/vault-audit.syslog
EOF

# 取消 PrivDrop，让 rsyslog 以 root 运行（教学环境专用）。
sed -i 's|^\$PrivDropToUser .*||; s|^\$PrivDropToGroup .*||' /etc/rsyslog.conf
sed -i 's|PrivDropToUser="syslog"||g; s|PrivDropToGroup="syslog"||g' /etc/rsyslog.conf
# 显式让 imuxsock 监听 /dev/log。
if grep -q '^module(load="imuxsock")' /etc/rsyslog.conf; then
  sed -i 's|^module(load="imuxsock").*|module(load="imuxsock" SysSock.Name="/dev/log")|' /etc/rsyslog.conf
fi

# 释放 systemd 对 /dev/log 的占用，再让 rsyslog 自己 bind 该 socket。
systemctl stop syslog.socket 2>/dev/null
systemctl mask syslog.socket 2>/dev/null
pkill -9 rsyslogd 2>/dev/null
rm -f /dev/log
nohup rsyslogd -n -iNONE > /var/log/rsyslogd.out 2>&1 &
sleep 1

touch /var/log/vault/vault-audit.syslog
chown root:root /var/log/vault/vault-audit.syslog
chmod 644 /var/log/vault/vault-audit.syslog

touch /tmp/.setup-done
