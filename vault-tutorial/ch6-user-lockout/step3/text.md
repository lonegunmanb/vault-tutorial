# 第三步：用 `VAULT_DISABLE_USER_LOCKOUT` 全局关停

正文优先级链中，`VAULT_DISABLE_USER_LOCKOUT` 环境变量位于禁用优先级的**最顶端**——它会**无视**配置文件中的 `user_lockout` 块和挂载点 tune 设置。本步把它加到 Vault 进程的环境里，验证配置文件里的 `user_lockout "userpass"` 块（threshold=3）被完全忽略。

## 3.1 停掉 Vault，并以带环境变量的方式重启

```bash
./stop-vault.sh

# 在系统级把环境变量直接传给 vault 进程
VAULT_DISABLE_USER_LOCKOUT=true \
  nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
sleep 3

# 重启后需要重新解封并使用之前的 root token
vault operator unseal "$UNSEAL_KEY"
export VAULT_TOKEN="$VAULT_TOKEN"
```

> 提示：配置文件保持不变，`user_lockout "userpass"` 块依然在文件里，但它将因环境变量优先级最高而**完全失效**。

## 3.2 连续输错远超阈值的次数

故意把失败次数从 3 提到 8（远高于配置文件里的 lockout_threshold=3）：

```bash
for i in 1 2 3 4 5 6 7 8; do
  vault login -method=userpass username=alice password=wrong-${i} >/dev/null 2>&1
  printf "第 %d 次失败 done\n" "$i"
done
```

## 3.3 用正确密码立即验证：alice **未**被锁定

```bash
vault login -method=userpass username=alice password=correct-horse-battery-staple
```

预期：登录成功，返回新的 token。这与第一步形成鲜明对比——同一份配置文件、同一份 user_lockout 块、同一个用户、相同的错误尝试模式，仅仅因为多了一个 `VAULT_DISABLE_USER_LOCKOUT=true` 环境变量，锁定行为就被全局抑制。

进一步验证 `/sys/locked-users` 中也没有任何被锁用户：

```bash
curl -sS \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  http://127.0.0.1:8200/v1/sys/locked-users | jq '.data.total'
```

预期输出为 `0`。

## 3.4 这一步的核心闭环

学员已在终端里复现了禁用优先级链的最顶层：环境变量 `VAULT_DISABLE_USER_LOCKOUT` 一旦设置，配置文件里的所有 `user_lockout` 块都不再生效。这与"配置文件里 disable_lockout = true"的等价区别是：环境变量法可以在不改任何文件的前提下，作为线上事故的应急开关使用，并通过下一次去掉环境变量的重启即可恢复原配置。
