#!/bin/bash
set +e

source /root/setup-common.sh

install_vault &
INSTALL_VAULT_PID=$!

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

# step5 需要 python3 跑一个轻量 statsd UDP 接收端（多数 Ubuntu 镜像预装，仅作保险）
if ! command -v python3 > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq python3 > /dev/null 2>&1
fi

# step4 需要 prometheus 二进制；直接下载官方 release tarball、只提取 prometheus 主二进制。
# 后台下载以免阻塞 Vault 安装。
(
  if ! command -v prometheus > /dev/null 2>&1; then
    PROM_VER=2.53.0
    curl -fsSLo /tmp/prom.tgz \
      "https://github.com/prometheus/prometheus/releases/download/v${PROM_VER}/prometheus-${PROM_VER}.linux-amd64.tar.gz" \
      && tar -xzf /tmp/prom.tgz -C /tmp \
      && install -m 0755 "/tmp/prometheus-${PROM_VER}.linux-amd64/prometheus" /usr/local/bin/prometheus \
      && rm -rf /tmp/prom.tgz "/tmp/prometheus-${PROM_VER}.linux-amd64"
  fi
) &
INSTALL_PROM_PID=$!

wait "$INSTALL_VAULT_PID"
wait "$INSTALL_PROM_PID"

for n in 1 2 3; do
  mkdir -p /opt/vault/data-${n}
  chmod 700 /opt/vault/data-${n}
done

# 三份 vault.hcl：与 6.6 节实验相同的端口分布（API 8200/8210/8220、cluster 8201/8211/8221），
# 但 listener 绑定到 0.0.0.0 以便 step4 通过 Killercoda 浏览器入口访问 /ui/。
# 顶层 telemetry 块预置最小可用 Prometheus 配置；step3 会教学员追加 prefix_filter。
write_node_config() {
  local n=$1
  local api_port=$2
  local cluster_port=$3
  local retry_join_block=$4

  cat > /root/vault-${n}.hcl <<EOF
ui            = true
disable_mlock = true
cluster_name  = "vault-telemetry-classroom"
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
  address         = "0.0.0.0:${api_port}"
  cluster_address = "127.0.0.1:${cluster_port}"
  tls_disable     = true
}

telemetry {
  prometheus_retention_time = "30s"
  disable_hostname          = true
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

# 一个便捷脚本：找出当前 leader 端口，输出到 stdout。
cat > /root/find-leader.sh <<'EOF'
#!/bin/bash
for port in 8200 8210 8220; do
  is_self=$(curl -sS "http://127.0.0.1:${port}/v1/sys/leader" 2>/dev/null | jq -r '.is_self // false')
  if [ "$is_self" = "true" ]; then
    echo "$port"
    exit 0
  fi
done
echo "no-leader"
exit 1
EOF
chmod +x /root/find-leader.sh

cd /root
finish_setup
