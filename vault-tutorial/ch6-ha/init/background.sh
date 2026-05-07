#!/bin/bash
set +e

source /root/setup-common.sh

install_vault &
INSTALL_VAULT_PID=$!

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

wait "$INSTALL_VAULT_PID"

for n in 1 2 3; do
  mkdir -p /opt/vault/data-${n}
  chmod 700 /opt/vault/data-${n}
done

# 三份 vault.hcl：每个节点都把 api_addr 配置为指向"自己"，cluster_addr 同理。
# 这正是 6.5 节"4.1 客户端可直接访问每台 Vault"建议的部署形态——
# 当 standby 触发 307 重定向时，Location 头里给出的就是 active 节点自己的 api_addr。
write_node_config() {
  local n=$1
  local api_port=$2
  local cluster_port=$3
  local retry_join_block=$4

  cat > /root/vault-${n}.hcl <<EOF
ui            = true
disable_mlock = true
cluster_name  = "vault-ha-classroom"
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
