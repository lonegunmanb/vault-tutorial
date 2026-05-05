#!/bin/bash

echo "================================================="
echo "  正在为你准备 lease / unwrap / ssh / path-help 实验环境..."
echo "  请稍候，通常需要 30-120 秒；首次拉取数据库镜像可能更久"
echo "================================================="

SETUP_LOG="/tmp/ch5-other-commands-setup.log"
START_TIME=$(date +%s)
TIMEOUT_SECONDS=300

while [ ! -f /tmp/.setup-done ] && [ ! -f /tmp/.setup-failed ]; do
  NOW=$(date +%s)
  if [ $((NOW - START_TIME)) -gt "$TIMEOUT_SECONDS" ]; then
    echo ""
    echo "初始化等待超过 ${TIMEOUT_SECONDS} 秒。最近的后台日志如下："
    tail -80 "$SETUP_LOG" 2>/dev/null || echo "尚未找到 $SETUP_LOG"
    exit 1
  fi
  sleep 1
done

if [ -f /tmp/.setup-failed ]; then
  clear
  echo "实验环境初始化失败。最近的后台日志如下："
  echo ""
  tail -120 "$SETUP_LOG" 2>/dev/null || echo "尚未找到 $SETUP_LOG"
  echo ""
  echo "请刷新实验环境后重试；如果仍失败，请保留以上日志用于定位。"
  exit 1
fi

cd /root
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

clear
echo "环境已就绪！"
echo ""
echo "Vault 版本：$(vault version | head -1 | awk '{print $2}')"
echo ""
echo "已启用的相关机密引擎："
vault secrets list | grep -E "Path|database|ssh-otp|secret/"
echo ""
echo "database/roles/readonly："
vault read database/roles/readonly | grep -E "db_name|default_ttl|max_ttl|creation_statements" || true
echo ""
echo "你现在可以直接执行 vault 命令。"