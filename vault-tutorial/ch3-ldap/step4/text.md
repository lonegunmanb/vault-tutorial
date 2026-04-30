# 第 4 步：Library Set —— 服务账号池借出 / 归还时自动换密码

模型：[3.10 §5](/ch3-ldap)。本步要：

1. 创建一个 Library Set 包含 `svc-ops-1/2/3`
2. 借出 → 拿到分配的账号 + 新密码
3. 用旧密码 / 新密码分别尝试登 LDAP，验证"借出瞬间换密"
4. 归还 → 验证 Vault 再次换了密码（前借用人手里的那份不再有效）

---

## 4.1 创建 Library Set

先确认 `svc-ops-1` 现在还是 init 预置的原始密码（为 4.1 之后做对比准备）：

```bash
ldapwhoami -x -H ldap://127.0.0.1:389 \
  -D "cn=svc-ops-1,ou=ServiceAccounts,dc=example,dc=org" -w "ops-initial-pass-1"
# 应输出: dn:cn=svc-ops-1,ou=serviceaccounts,dc=example,dc=org
```

```bash
vault write ldap/library/break-glass-team \
  service_account_names="svc-ops-1,svc-ops-2,svc-ops-3" \
  ttl="2m" \
  max_ttl="10m" \
  disable_check_in_enforcement=false
```

查池子状态：

```bash
vault read ldap/library/break-glass-team/status
```

三个账号都应显示 `available: true`。

> **创建即接管**：`vault write ldap/library/...` 完成的那一刻，Vault 已经把池中所有账号的密码
> 轮成了**只有 Vault 才知道**的随机串。验证一下：
>
> ```bash
> ldapwhoami -x -H ldap://127.0.0.1:389 \
>   -D "cn=svc-ops-1,ou=ServiceAccounts,dc=example,dc=org" -w "ops-initial-pass-1" 2>&1 | head -1
> # 应输出: ldap_bind: Invalid credentials (49)
> ```
>
> 这意味着任何在外面攥着 `ops-initial-pass-1` 的人都立刻失去了访问能力——之后只能通过 check-out
> 拿到 Vault 现场发的新密码。

## 4.2 借出（check-out）一个账号

借出：

```bash
CO=$(vault write -format=json -f ldap/library/break-glass-team/check-out)
echo "$CO" | jq

ACCT=$(echo "$CO" | jq -r .data.service_account_name)
PASS=$(echo "$CO" | jq -r .data.password)
LEASE=$(echo "$CO" | jq -r .lease_id)

echo "借到: $ACCT"
echo "新密码: $PASS"
echo "Lease: $LEASE"
```

## 4.3 验证"借出瞬间换密"

```bash
# 用 Vault 给的新密码可登
ldapwhoami -x -H ldap://127.0.0.1:389 \
  -D "cn=$ACCT,ou=ServiceAccounts,dc=example,dc=org" -w "$PASS"

# 原始密码 ops-initial-pass-1 在 4.1 创建 library 时就已失效，check-out 后依然无效
ldapwhoami -x -H ldap://127.0.0.1:389 \
  -D "cn=$ACCT,ou=ServiceAccounts,dc=example,dc=org" -w "ops-initial-pass-1" 2>&1 | head -1
# 应输出 ldap_bind: Invalid credentials (49)
```

查池子状态：

```bash
vault read ldap/library/break-glass-team/status
```

`$ACCT` 应显示 `available: false`，剩两个还是 `true`。

## 4.4 归还（check-in），观察 Vault 再次换密

记下当前借到的密码 `$PASS`，归还：

```bash
vault write ldap/library/break-glass-team/check-in \
  service_account_names="$ACCT"
```

或等价的 `vault lease revoke "$LEASE"`。

```bash
# 借出期间的密码 $PASS 现在已失效（Vault 在归还瞬间又改了一次密码）
ldapwhoami -x -H ldap://127.0.0.1:389 \
  -D "cn=$ACCT,ou=ServiceAccounts,dc=example,dc=org" -w "$PASS" 2>&1 | head -1
# 应输出 ldap_bind: Invalid credentials (49)
```

```bash
vault read ldap/library/break-glass-team/status
```

`$ACCT` 应已恢复为 `available: true`。

## 4.5 第二次借出 —— 同一账号、不同密码

```bash
CO2=$(vault write -format=json -f ldap/library/break-glass-team/check-out)
ACCT2=$(echo "$CO2" | jq -r .data.service_account_name)
PASS2=$(echo "$CO2" | jq -r .data.password)

echo "再借一次, 拿到: $ACCT2 / $PASS2"
[ "$PASS" != "$PASS2" ] && echo "✅ 即便借到同一账号，密码也不同"

ldapwhoami -x -H ldap://127.0.0.1:389 \
  -D "cn=$ACCT2,ou=ServiceAccounts,dc=example,dc=org" -w "$PASS2"
```

## 4.6 把池子借空

```bash
vault write -f -format=json ldap/library/break-glass-team/check-out > /dev/null
vault write -f -format=json ldap/library/break-glass-team/check-out > /dev/null
# 此时 3 个账号都借出（含 4.5 那次），再借就失败
vault write -f ldap/library/break-glass-team/check-out 2>&1 | tail -3
# 应看到 "no service accounts available for check-out"
```

---

## ✅ 验收

- [ ] 借出后池子状态变为 `available: false`，旧密码立刻失效
- [ ] 归还后状态恢复 `available: true`，借出期间的密码也已失效
- [ ] 再次借同一账号，密码不同
- [ ] 池子借空时再 check-out 会被拒绝

> Library 的不变量：**借出瞬间换密 + 归还瞬间再次换密**——确保任何曾经持有过密码的人，
> 在不再持锁时都拿不到生效凭据。这是 Static Role 给不了的"借出期间排他"语义。
