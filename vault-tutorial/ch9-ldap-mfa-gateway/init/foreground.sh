#!/bin/bash

echo "================================================="
echo "  正在为你准备 9.9 Vault OSS LDAP + TOTP 登录网关实验环境..."
echo "  请稍候，预计需要 90-180 秒"
echo "================================================="

while [ ! -f /tmp/.setup-done ]; do
  if [ -f /tmp/.setup-failed ]; then
    echo ""
    echo "环境初始化失败。最近的初始化日志如下："
    echo "-------------------------------------------------"
    tail -80 /var/log/ldap-mfa-init.log 2>/dev/null || true
    echo "-------------------------------------------------"
    exit 1
  fi
  sleep 2
  echo -n "."
done

echo ""
echo "环境就绪，请按右侧 START 进入第一步。"