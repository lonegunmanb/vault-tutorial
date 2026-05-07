# 第一步：故意触发 user lockout 并观察 permission denied

## 1.1 启动并初始化 Vault

启动单节点 Vault：

```bash
./start-vault.sh
sleep 3
```

初始化（为简化课堂演示，使用 1/1 分片）：

```bash
vault operator init -key-shares=1 -key-threshold=1 \
  -format=json > /root/init-output.json

UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' /root/init-output.json)
ROOT_TOKEN=$(jq -r '.root_token' /root/init-output.json)

cat >> /etc/profile.d/vault.sh <<EOF
export UNSEAL_KEY='${UNSEAL_KEY}'
export VAULT_TOKEN='${ROOT_TOKEN}'
EOF
source /etc/profile.d/vault.sh

vault operator unseal "$UNSEAL_KEY"
```

## 1.2 启用 userpass 并创建一个测试用户

```bash
vault auth enable userpass
vault write auth/userpass/users/alice password=correct-horse-battery-staple
```

## 1.3 故意输错密码，观察锁定阈值的触发

按预置配置 `lockout_threshold = "3"`，前 3 次失败将得到普通的"invalid username or password"，**第 4 次以后**——即便密码完全正确——都会被立即以"permission denied"拒绝：

```bash
for i in 1 2 3 4 5; do
  echo "=== 第 ${i} 次（错密码） ==="
  vault login -method=userpass username=alice password=wrong-${i} 2>&1 | tail -n 3
done

echo "=== 用正确密码再尝试一次 ==="
vault login -method=userpass username=alice password=correct-horse-battery-staple 2>&1 | tail -n 3
```

预期：前 3 次报"invalid username or password"；第 4 次起以及最后用正确密码的那次，都会立即返回类似 `Code: 403. Errors: * permission denied` 的响应。这就是正文中所讲的"锁定窗口期内 Vault 不再为该用户校验凭据，直接返回 permission denied"。

## 1.4 这一步的核心闭环

锁定阈值为 3、锁定持续时间为 1 分钟的 userpass 配置已生效；学员已在终端里观察到"达到阈值后正确密码也被立即拒绝"这一关键现象。下一步将通过 `/sys/locked-users` 端点把该锁定状态列出来，再主动解锁。
