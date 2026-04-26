# 第三步：认证方法的路径迁移：vault auth move

机密引擎能搬，认证方法同样能搬。`vault auth move` 用法一致，底层走的也是 `sys/remount` API。

## 3.1 迁移前：确认用户存在

```bash
echo "=== old-login 路径下的用户 ==="
vault list auth/old-login/users/
```

```
Keys
----
bob
```

记录 Accessor：

```bash
AUTH_BEFORE=$(vault auth list -format=json | jq -r '.["old-login/"].accessor')
echo "迁移前 Auth Accessor = $AUTH_BEFORE"
```

## 3.2 执行迁移：old-login/ → corp-userpass/

```bash
vault auth move old-login/ corp-userpass/
```

```
Success! Finished moving auth method old-login/ to corp-userpass/, with migration ID ...
```

## 3.3 验证：用户数据跟着走

```bash
echo "=== 旧路径（应该报错）==="
vault list auth/old-login/users/ 2>&1 | tail -3

echo ""
echo "=== 新路径 ==="
vault list auth/corp-userpass/users/
```

```
Keys
----
bob
```

bob 完整地出现在新路径下，用户名、密码、关联的 Policy 全部保留。

## 3.4 验证：用新路径登录

```bash
echo "=== bob 通过新路径登录 ==="
vault login -method=userpass -path=corp-userpass \
  username=bob password=training
```

登录成功——说明认证方法的内部状态（密码哈希、Policy 绑定）完整迁移。

切回 root token 继续实验：

```bash
export VAULT_TOKEN='root'
```

## 3.5 验证：Accessor 不变

```bash
AUTH_AFTER=$(vault auth list -format=json | jq -r '.["corp-userpass/"].accessor')
echo "迁移后 Auth Accessor = $AUTH_AFTER"

if [ "$AUTH_BEFORE" = "$AUTH_AFTER" ]; then
  echo "✅ Auth Accessor 相同——认证方法搬家成功"
else
  echo "❌ Auth Accessor 不同（不应该出现）"
fi
```

## 3.6 查看最终的认证方法列表

```bash
vault auth list -format=table
```

`old-login/` 消失，`corp-userpass/` 出现。而原来的 `userpass/`（alice 的那个）不受影响。
