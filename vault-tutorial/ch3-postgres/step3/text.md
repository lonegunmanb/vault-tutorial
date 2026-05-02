# 第 3 步：Static Role —— 接管 `legacy_app`，立即轮转 + 周期轮转

模型：[3.14 §5](/ch3-postgres)。本步演示一个常见的真实场景：**已经在 PG 里存在的 `legacy_app`
用的是固定密码**，现在把它纳入 Vault 管理，让 Vault 负责生成、保存并周期轮转它的新密码。

我们将：

1. onboarding `legacy_app` 为 Static Role，观察 Vault **立即轮转**旧密码
2. 验证 `legacy-pass` 已不可用，`static-creds` 返回的新密码可登 PG
3. 手动触发一次 `vault write -f database/rotate-role/...`，上一轮密码立即作废、新密码可用
4. 等 ~130 秒看周期轮转再换一次

---

## 3.0 先确认 `legacy_app` 还在用初始密码

```bash
PGPASSWORD=legacy-pass psql -h 127.0.0.1 -U legacy_app -d postgres -tAc "SELECT current_user;"
# 应输出: legacy_app
```

## 3.1 onboarding：接管后立即轮转

```bash
vault write database/static-roles/legacy-app \
  db_name="postgres-main" \
  username="legacy_app" \
  rotation_period="120s"

vault read database/static-roles/legacy-app
```

> Static Role 名 `legacy-app` 也必须被 `database/config/postgres-main` 的 `allowed_roles` 允许；step 1 已把它列入白名单。

> `username` 必须是 PG 里**已存在**的账号名；Static Role 是 1:1 映射，不会替你建账号。
> 在本实验环境里，PG 端已把 `legacy_app` 授给 `vaultadmin` 并带 `WITH ADMIN OPTION`，所以 Vault 能替它改密码。

## 3.2 验证 onboarding 已立即轮转

```bash
PGPASSWORD=legacy-pass psql -h 127.0.0.1 -U legacy_app -d postgres -tAc "SELECT 1;" 2>&1 | head -2
# 应输出: FATAL:  password authentication failed for user "legacy_app"

PASS_1=$(vault read -format=json database/static-creds/legacy-app | jq -r .data.password)
echo "Vault onboarding 后持有的密码: $PASS_1"

PGPASSWORD="$PASS_1" psql -h 127.0.0.1 -U legacy_app -d postgres -tAc "SELECT current_user;"
# 应输出: legacy_app
```

> 这就是 Static Role onboarding 的关键行为：Vault 接管已有账号时，会先把数据库里的密码改成它自己生成并保存的新值。
> 应用侧要改为从 `database/static-creds/legacy-app` 读取当前密码。

## 3.3 手动轮一次：上一轮密码立刻失效

```bash
vault write -f database/rotate-role/legacy-app

PASS_2=$(vault read -format=json database/static-creds/legacy-app | jq -r .data.password)
echo "上一轮密码: $PASS_1"
echo "当前密码  : $PASS_2"
[ "$PASS_1" != "$PASS_2" ] && echo "✅ 手动轮转后密码已变化"

# 上一轮密码不能登
PGPASSWORD="$PASS_1" psql -h 127.0.0.1 -U legacy_app -d postgres -tAc "SELECT 1;" 2>&1 | head -2
# 应输出: FATAL:  password authentication failed for user "legacy_app"

# 当前密码可以登
PGPASSWORD="$PASS_2" psql -h 127.0.0.1 -U legacy_app -d postgres -tAc "SELECT current_user;"
# 应输出: legacy_app
```

## 3.4 等 ~130 秒，观察自动周期轮转

```bash
echo "现在时间: $(date)"
echo "等 130 秒..."
sleep 130

PASS_3=$(vault read -format=json database/static-creds/legacy-app | jq -r .data.password)
echo "上一轮密码: $PASS_2"
echo "当前密码  : $PASS_3"
[ "$PASS_2" != "$PASS_3" ] && echo "✅ 密码已自动轮转"

# 上一轮密码已不可用
PGPASSWORD="$PASS_2" psql -h 127.0.0.1 -U legacy_app -d postgres -tAc "SELECT 1;" 2>&1 | head -1

# 当前密码可用
PGPASSWORD="$PASS_3" psql -h 127.0.0.1 -U legacy_app -d postgres -tAc "SELECT current_user;"
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

- [ ] onboarding 后旧密码 `legacy-pass` 立刻失效
- [ ] `vault read database/static-creds/legacy-app` 拿到的当前密码可登 PG
- [ ] `vault write -f database/rotate-role/legacy-app` 后上一轮密码失效，新密码可用
- [ ] 等 ~130 秒后再读，新密码又变了；上一轮密码已失效
- [ ] `vault read database/static-creds/...` 输出**没有** `lease_id`（与 Dynamic 形成对比）
