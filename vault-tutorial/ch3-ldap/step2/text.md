# 第 2 步：Static Role —— 周期轮转固定账号的密码

模型：[3.10 §3](/ch3-ldap)。本步要：

1. 为 `app1` 创建 Static Role，`rotation_period=120s` 便于快速观察
2. `vault read ldap/static-cred/...` 拿到当前密码
3. 用 `ldapsearch -D ... -w "$PASSWORD"` 验证此密码确实可登 LDAP
4. 等 ~130 秒后再读，密码已变；旧密码登 LDAP 失败

---

## 2.1 创建 Static Role

```bash
vault write ldap/static-role/dba-app1 \
  username="app1" \
  dn="cn=app1,ou=ServiceAccounts,dc=example,dc=org" \
  rotation_period="120s"

vault read ldap/static-role/dba-app1
```

`last_vault_rotation` 与 `next_vault_rotation` 是 Vault 追踪轮转时刻的字段。
**首次创建时 Vault 立即执行一次轮转**（这就是为什么初始密码 `initial-pass-1` 立刻就被覆盖了）。

## 2.2 读取当前密码

```bash
PASS_OLD=$(vault read -format=json ldap/static-cred/dba-app1 | jq -r .data.password)
echo "当前密码：$PASS_OLD"
```

## 2.3 用当前密码登 LDAP 验证

```bash
ldapwhoami -x -H ldap://127.0.0.1:389 \
  -D "cn=app1,ou=ServiceAccounts,dc=example,dc=org" -w "$PASS_OLD"
# 应输出: dn:cn=app1,ou=ServiceAccounts,dc=example,dc=org
```

顺手验证一下原始的 `initial-pass-1` **已经不能用了**（已被首次轮转覆盖）：

```bash
ldapwhoami -x -H ldap://127.0.0.1:389 \
  -D "cn=app1,ou=ServiceAccounts,dc=example,dc=org" -w "initial-pass-1" 2>&1 | head -2
# 应输出: ldap_bind: Invalid credentials (49)
```

## 2.4 等 ~130 秒，观察自动轮转

```bash
echo "现在时间：$(date)"
echo "等 130 秒看密码自动轮转..."
sleep 130

PASS_NEW=$(vault read -format=json ldap/static-cred/dba-app1 | jq -r .data.password)
echo "旧密码：$PASS_OLD"
echo "新密码：$PASS_NEW"
[ "$PASS_OLD" != "$PASS_NEW" ] && echo "✅ 密码已自动轮转"

# 旧密码已不可用
ldapwhoami -x -H ldap://127.0.0.1:389 \
  -D "cn=app1,ou=ServiceAccounts,dc=example,dc=org" -w "$PASS_OLD" 2>&1 | head -1

# 新密码可用
ldapwhoami -x -H ldap://127.0.0.1:389 \
  -D "cn=app1,ou=ServiceAccounts,dc=example,dc=org" -w "$PASS_NEW"
```

## 2.5 手动触发一次额外轮转

不想等周期？

```bash
vault write -f ldap/rotate-role/dba-app1
PASS_NEW2=$(vault read -format=json ldap/static-cred/dba-app1 | jq -r .data.password)
echo "强制轮转后的密码：$PASS_NEW2"
```

---

## ✅ 验收

- [ ] 创建 role 后 `initial-pass-1` 已失效，`vault read static-cred` 拿到的密码可登 LDAP
- [ ] 等 ~130 秒后再读，密码不同；旧密码不能登 LDAP，新密码可以
- [ ] `ldap/rotate-role/<name>` 能手动强制再轮转一次

> Static Role **不发 Lease**——`vault read static-cred` 没有 `lease_id`，密码不"过期"，
> 只会被下一次轮转覆盖。这与 [2.3 Lease](/ch2-lease) 的动态凭据语义完全不同，下一步会看到对比。
