# 第 3 步：Static Role —— 平滑接管 `legacy_app`，周期轮转

模型：[3.14 §5](/ch3-postgres)。本步演示一个常见的真实场景：**已经在 PG 里跑着的 `legacy_app`
用的是固定密码**，现在要把它纳入 Vault 管理但又**不能立刻打断**正在运行的应用。

我们将：

1. 用 `skip_import_rotation=true` onboarding（**保留** `legacy-pass` 不被立刻覆盖）
2. 验证旧密码 `legacy-pass` 此刻仍可登 PG
3. 手动触发一次 `vault write -f database/rotate-role/...`，旧密码立即作废、新密码可用
4. 等 ~130 秒看周期轮转再换一次

---

## 3.0 先确认 `legacy_app` 还在用初始密码

```bash
PGPASSWORD=legacy-pass psql -h 127.0.0.1 -U legacy_app -d postgres -tAc "SELECT current_user;"
# 应输出: legacy_app
```

## 3.1 onboarding：用 `skip_import_rotation=true` 平滑接管

```bash
vault write database/static-roles/legacy-app \
  db_name="postgres-main" \
  username="legacy_app" \
  rotation_period="120s" \
  skip_import_rotation=true

vault read database/static-roles/legacy-app
```

> `username` 必须是 PG 里**已存在**的账号名；Static Role 是 1:1 映射，不会替你建账号。
>
> `skip_import_rotation=true` 让 Vault 不在 onboarding 时立刻轮——这是 [3.14 §5.2](/ch3-postgres) 引官方所述的关键平滑切换技巧。

## 3.2 验证 onboarding 后旧密码仍可用

```bash
PGPASSWORD=legacy-pass psql -h 127.0.0.1 -U legacy_app -d postgres -tAc "SELECT current_user;"
# 仍应输出: legacy_app
```

`vault read database/static-creds/legacy-app` 此刻 **无法返回有效密码**——因为 Vault 还没轮过这个账号、
也没在 onboarding 时被告知 `password=legacy-pass`，所以它没有任何"当前密码"可以交给应用。
读出来的字段大致是这样：

```bash
vault read database/static-creds/legacy-app
# Key                    Value
# ---                    -----
# last_vault_rotation    n/a
# password               (empty / Vault not yet aware)
# rotation_period        120s
# ttl                    ...
# username               legacy_app
```

> 这就是为什么 [3.14 §5.2](/ch3-postgres) 同时给出第二条 bullet：
> onboarding 时显式传入 `password=<现有密码>` 把当前密码"借给" Vault，让应用能在第一次轮转之前就开始走 Vault 取密码。
> 本实验为简化只做"延后第一次轮转"；生产里两条建议常一起用。

## 3.3 手动轮一次：旧密码立刻失效，新密码生效

```bash
vault write -f database/rotate-role/legacy-app

PASS_NEW=$(vault read -format=json database/static-creds/legacy-app | jq -r .data.password)
echo "Vault 现在持有的密码: $PASS_NEW"

# 旧密码不能登
PGPASSWORD=legacy-pass psql -h 127.0.0.1 -U legacy_app -d postgres -tAc "SELECT 1;" 2>&1 | head -2
# 应输出: FATAL:  password authentication failed for user "legacy_app"

# 新密码可以登
PGPASSWORD="$PASS_NEW" psql -h 127.0.0.1 -U legacy_app -d postgres -tAc "SELECT current_user;"
# 应输出: legacy_app
```

## 3.4 等 ~130 秒，观察自动周期轮转

```bash
echo "现在时间: $(date)"
echo "等 130 秒..."
sleep 130

PASS_NEW2=$(vault read -format=json database/static-creds/legacy-app | jq -r .data.password)
echo "旧密码: $PASS_NEW"
echo "新密码: $PASS_NEW2"
[ "$PASS_NEW" != "$PASS_NEW2" ] && echo "✅ 密码已自动轮转"

# 旧密码已不可用
PGPASSWORD="$PASS_NEW" psql -h 127.0.0.1 -U legacy_app -d postgres -tAc "SELECT 1;" 2>&1 | head -1

# 新密码可用
PGPASSWORD="$PASS_NEW2" psql -h 127.0.0.1 -U legacy_app -d postgres -tAc "SELECT current_user;"
```

## 3.5 顺手验证：Static Role 不发 Lease

```bash
vault read database/static-creds/legacy-app
# 注意输出里没有 lease_id —— Static 不签发 Lease
```

> 这是 [3.14 §5](/ch3-postgres) 与 [3.10 LDAP §3](/ch3-ldap) 都提到的一致性：
> Static Role 的密码不"过期"，只会被下一次轮转覆盖。

---

## ✅ 验收

- [ ] `skip_import_rotation=true` 后旧密码 `legacy-pass` 仍可登 PG
- [ ] `vault write -f database/rotate-role/legacy-app` 之后 `legacy-pass` 立刻失效，
      `vault read database/static-creds/legacy-app` 拿到的新密码可登 PG
- [ ] 等 ~130 秒后再读，新密码又变了；上一轮密码已失效
- [ ] `vault read database/static-creds/...` 输出**没有** `lease_id`（与 Dynamic 形成对比）
