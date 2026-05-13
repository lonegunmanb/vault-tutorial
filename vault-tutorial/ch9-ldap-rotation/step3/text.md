# 第 3 步：为 alice 创建 Static Role 并完整观察一次轮转

本步把『管 alice 的口令』这件事正式交给 Vault：创建一条名叫 `learn` 的 Static Role，让 Vault 在创建的瞬间就把 alice 的 `userPassword` 替换成一段**只有它自己知道**的随机串；之后再手动触发一次 `rotate-role`，看到上一份口令也立即失效。

---

## 3.1 创建 Static Role

```bash
vault write ldap/static-role/learn \
    dn='cn=alice,ou=users,dc=learn,dc=example' \
    username='alice' \
    rotation_period="24h"
```

预期输出：

```
Success! Data written to: ldap/static-role/learn
```

> **9.5 节正文第 3 节强调过的细节**：`vault write ldap/static-role/learn` 这一条命令本身就会触发**一次首次轮转**——alice 在 LDAP 里那份 `1LearnedVault` 已经在这一瞬间被改掉了。这就是为什么生产里要用 `skip_import_rotation=true` 给老业务留迁移窗口；在本实验里 alice 没有任何在跑的应用依赖她的旧口令，直接覆盖即可。

## 3.2 读出 Vault 当下持有的口令

```bash
vault read ldap/static-cred/learn
```

预期看到形如下面的输出（`password` 这一行的具体值会不一样）：

```
Key                    Value
---                    -----
dn                     cn=alice,ou=users,dc=learn,dc=example
last_password          n/a
last_vault_rotation    2026-05-13T06:00:16.078548538Z
password               J4JpDwHSj5HIJEGYSYAm9MyDlQEr09zUvYZQJlR6i9nca33SIVoX3jQ6EdAGrO4F
rotation_period        24h
ttl                    24h
username               alice
```

几个字段含义：

- `password`：Vault 当下持有的、alice 在 LDAP 里**真实生效的**口令；
- `last_password`：上一次轮转之前的那份口令。本节这是**第一次**轮转，所以是 `n/a`；下一节再轮一次后这一栏就有值了；
- `last_vault_rotation`：上一次轮转的时间戳；
- `rotation_period` / `ttl`：本 role 设的轮转周期，以及『距离下次轮转还有多久』。

## 3.3 用新口令 bind 成功、用旧口令 bind 失败

把口令拿出来存进一个 shell 变量，方便接下来调用：

```bash
LDAP_PASSWORD=$(vault read --format=json ldap/static-cred/learn | jq -r '.data.password')
echo "Vault 当下持有的口令: $LDAP_PASSWORD"
```

预期 `echo` 出的串就是上一步 `password` 列里那一长串。

用它 bind LDAP：

```bash
ldapsearch -x -H ldap://127.0.0.1:389 \
  -D "cn=alice,ou=users,dc=learn,dc=example" -w "$LDAP_PASSWORD" \
  -b "cn=alice,ou=users,dc=learn,dc=example" -s base cn 2>&1 | tail -8
```

预期输出末尾：

```
dn: cn=alice,ou=users,dc=learn,dc=example
cn: alice

# search result
search: 2
result: 0 Success
```

再用 alice 之前那份『人工管理时代』的初始口令 `1LearnedVault` 试一次：

```bash
ldapsearch -x -H ldap://127.0.0.1:389 \
  -D "cn=alice,ou=users,dc=learn,dc=example" -w 1LearnedVault \
  -b "cn=alice,ou=users,dc=learn,dc=example" -s base cn 2>&1 | tail -3
```

预期输出：

```
ldap_bind: Invalid credentials (49)
```

> 这就证明了 9.5 节正文第 3 节的第 1 点——**创建 Static Role 的那一瞬间 alice 在 LDAP 里的 `userPassword` 已经被覆盖**。从这一刻起，要以 alice 的身份动 LDAP，唯一的途径就是去问 Vault。

## 3.4 手动再轮一次，验证『前一份口令』也立即失效

实际生产里我们绝不会真的等 24 小时——只要 SOC 一旦怀疑某份口令外泄，要立刻 `vault write -f ldap/rotate-role/<role>` 切断它的生命周期。我们这就模拟一次：

```bash
PREV_PASSWORD="$LDAP_PASSWORD"
vault write -f ldap/rotate-role/learn
vault read ldap/static-cred/learn
```

预期 `vault read` 的输出里：

- `password` 是一串**新**的随机字符；
- `last_password` 这一栏从 `n/a` 变成了刚才 `$PREV_PASSWORD` 那一串。

把刚才存下来的 `$PREV_PASSWORD` 再 bind 一次，看它是不是真的失效了：

```bash
ldapsearch -x -H ldap://127.0.0.1:389 \
  -D "cn=alice,ou=users,dc=learn,dc=example" -w "$PREV_PASSWORD" \
  -b "cn=alice,ou=users,dc=learn,dc=example" -s base cn 2>&1 | tail -3
```

预期输出：

```
ldap_bind: Invalid credentials (49)
```

注意：虽然 `last_password` 在 Vault 内部仍有记录，但 LDAP 服务端并**不**接受它——`last_password` 只是 Vault 给『正在做灰度切换的应用』留的一个『万一脚本失败了我还能查一下上一次是什么』的字段，**不是一份生效中的备用凭据**。

> 9.5 节正文第 3 节的第 3 点：**轮转后，前一次拿到的口令在 LDAP 这一端立即失效**。第 4 步将会基于这一性质，用一段最小 bash 脚本演示『应用每次启动都从 Vault 取最新口令』的消费路径。

---

## ✅ 验收

- [ ] `vault write ldap/static-role/learn ...` 成功
- [ ] `vault read ldap/static-cred/learn` 返回了 `password` 与 `rotation_period=24h`
- [ ] 用 `$LDAP_PASSWORD` 以 alice 身份 bind 看到 `result: 0 Success`
- [ ] 用 `1LearnedVault` 以 alice 身份 bind 看到 `Invalid credentials (49)`
- [ ] 手动 `rotate-role` 之后，`$PREV_PASSWORD` 也变成 `Invalid credentials (49)`
