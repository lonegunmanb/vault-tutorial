#!/bin/bash

echo "================================================="
echo "  正在为你准备 9.9 LDAP + TOTP 登录网关实验环境..."
echo "  请稍候，预计需要 90-180 秒"
echo "================================================="

while [ ! -f /tmp/.setup-done ]; do
  sleep 2
  echo -n "."
done

echo ""
echo "环境就绪，请按右侧 START 进入第一步。"
