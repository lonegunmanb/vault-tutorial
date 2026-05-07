#!/bin/bash
set +e

source /root/setup-common.sh

# 安装 vault 与 jq
install_vault &
INSTALL_VAULT_PID=$!

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

wait "$INSTALL_VAULT_PID"

# 三个节点的 raft 数据目录
for n in 1 2 3 4; do
  mkdir -p /opt/vault/data-${n}
  chmod 700 /opt/vault/data-${n}
done

# 三份 vault.hcl：以端口区分（API: 8200/8210/8220/8230；cluster: 8201/8211/8221/8231）。
# node-1 不带 retry_join，作为 bootstrap 节点；node-2/3/4 通过 retry_join 自动加入 node-1。
write_node_config() {
  local n=$1
  local api_port=$2
  local cluster_port=$3
  local retry_join_block=$4

  cat > /root/vault-${n}.hcl <<EOF
ui            = true
disable_mlock = true
cluster_name  = "vault-classroom"
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
  address     = "127.0.0.1:${api_port}"
  cluster_address = "127.0.0.1:${cluster_port}"
  tls_disable = true
}

default_lease_ttl = "168h"
max_lease_ttl     = "720h"
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
write_node_config 4 8230 8231 '
  retry_join {
    leader_api_addr = "http://127.0.0.1:8200"
  }'

# 实验全程通过 VAULT_ADDR 切换目标节点；默认指向 node-1。
cat > /etc/profile.d/vault.sh <<'EOF'
export VAULT_ADDR='http://127.0.0.1:8200'
EOF
chmod +x /etc/profile.d/vault.sh
grep -q "VAULT_ADDR=" /root/.bashrc 2>/dev/null || \
  cat /etc/profile.d/vault.sh >> /root/.bashrc

# 一个小的便捷启动脚本（学员手动调用，不在 background 中预先起 Vault）。
cat > /root/start-node.sh <<'EOF'
#!/bin/bash
# 用法：./start-node.sh <node-id 1|2|3|4>
# 在后台启动指定节点，日志写到 /var/log/vault-N.log。
n=$1
if [ -z "$n" ]; then
  echo "用法：$0 <1|2|3|4>"
  exit 1
fi
nohup vault server -config=/root/vault-${n}.hcl > /var/log/vault-${n}.log 2>&1 &
echo "node-${n} 已启动，日志：/var/log/vault-${n}.log"
EOF
chmod +x /root/start-node.sh

cd /root
finish_setup
