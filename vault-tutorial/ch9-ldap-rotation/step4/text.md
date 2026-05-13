# 第 4 步：用最小 bash 应用脚本消费 Vault 当下持有的口令

本步只想证明一件事：**应用不用关心口令什么时候被换，每次启动现去 Vault 拿一份就行。**

打个比方——alice 是一间公寓，它的 LDAP 口令就是开门的钥匙。Vault 就是『前台保管处』：钥匙永远只放在前台，每次进门前你去前台领一把当下能开门的钥匙。物业（运维）会偷偷换锁，新钥匙也只交给前台。

这一步的剧本就是：

1. 写一段最小的『应用』，每次启动都『去前台领钥匙 → 开门 → 报告进门了』；
2. 跑第一遍，记下这一次拿到的钥匙串；
3. **运维偷偷换一次锁**——`vault write -f ldap/rotate-role/learn`；
4. **同一段脚本一字未改、配置一字未动，再跑一遍**——它依旧『领钥匙 → 开门 → 进门了』，只是这一次的钥匙串和第一次**不一样**了。

最后再补一刀：把第一次那把老钥匙拿去开门，会被 LDAP 拒之门外（`Invalid credentials (49)`）——证明老钥匙是**真的**作废了。

> **关键对照**：如果是『把口令写死在配置文件里』的老式应用，第 3 步运维一换锁，它就死了——下次它去 bind LDAP 必然被拒，必须有人去改配置、重启服务、通知所有持有者。本步要演的就是这一刻的反面：换锁这件事**对应用零冲击**。

---

## 4.1 把消费逻辑写成一段最小 bash 脚本

把以下脚本保存为 `/root/app.sh`：

```bash
cat > /root/app.sh <<'EOF'
#!/bin/bash
# 一个最小的『应用』——只做三件事：
#   1) 从 Vault 取出 alice 当下的口令；
#   2) 用这份口令 bind LDAP，搜出 alice 的 cn；
#   3) 把这次拿到的口令打印出来，便于学员对比『两次跑出来的口令是否相同』。
set -euo pipefail

: "${VAULT_ADDR:=http://127.0.0.1:8200}"
: "${VAULT_TOKEN:=root}"
export VAULT_ADDR VAULT_TOKEN

PASSWORD=$(vault read -format=json ldap/static-cred/learn | jq -r '.data.password')

echo "[$(date +%H:%M:%S)] 本次从 Vault 读到的口令: ${PASSWORD}"

ldapsearch -x -LLL -H ldap://127.0.0.1:389 \
  -D "cn=alice,ou=users,dc=learn,dc=example" -w "${PASSWORD}" \
  -b "cn=alice,ou=users,dc=learn,dc=example" -s base cn

echo "[$(date +%H:%M:%S)] bind 成功——这次启动，应用具备 alice 的身份。"
EOF
chmod +x /root/app.sh
```

> **三个细节请留意**：
> - 脚本里**没有任何硬编码的口令**——alice 的口令在脚本任何位置都没出现；
> - 脚本依赖的环境变量只有 `VAULT_ADDR` 与 `VAULT_TOKEN`。在生产里 Token 应当由 [7.2 节](/ch7-agent) 的 Vault Agent 通过 [4.x 章](/ch4-app-role) 的某种 Auth Method 自动获取，而不是像本实验这样写一个 root token；
> - 脚本运行时**只**读 `ldap/static-cred/learn` 这一条路径——这与 9.5 节正文第 5 节给出的 `consumer-policy.hcl` 完全对应，意味着这段代码上线时只需要绑那一条最小策略。

## 4.2 第一次运行

```bash
/root/app.sh
```

预期输出形如（具体口令一定不一样）：

```
[06:01:00] 本次从 Vault 读到的口令: MsGgqHVvVMeeMWIwZnC0gFZNTEllQLvgR9yLK1kHbWlNfTw6VVhfcCFMmKmWDFWg
dn: cn=alice,ou=users,dc=learn,dc=example
cn: alice

[06:01:00] bind 成功——这次启动，应用具备 alice 的身份。
```

把这次的口令记下来，方便和下一次对照：

```bash
FIRST_RUN_PASSWORD=$(vault read -format=json ldap/static-cred/learn | jq -r '.data.password')
echo "FIRST_RUN_PASSWORD=$FIRST_RUN_PASSWORD"
```

## 4.3 在两次运行之间『运维偷偷换一次锁』

```bash
vault write -f ldap/rotate-role/learn
```

预期输出：`Success! Data written to: ldap/rotate-role/learn`。

这一瞬间发生了三件事：

- Vault 内部存的口令换成了一串新随机值；
- LDAP 那一端 alice 的 `userPassword` 也被改成同一份新值；
- **`FIRST_RUN_PASSWORD` 这把老钥匙在 LDAP 端立即作废**。

> 这就是『写死口令』方案在零接触轮转下的死亡场景：任何还把上一次口令写死在配置文件里的应用，**此刻**就已经认证不了 LDAP 了——除非有人去改配置、重启服务。我们这就来看『不写死口令』的应用对这一刻是什么反应。

## 4.4 第二次运行——脚本一字未改、配置一字未动

```bash
/root/app.sh
```

预期输出**末尾依然是** `bind 成功——这次启动，应用具备 alice 的身份。`，但**第一行打印出来的口令字符串与第一次不同**。

最后做一次显式对照：

```bash
SECOND_RUN_PASSWORD=$(vault read -format=json ldap/static-cred/learn | jq -r '.data.password')
echo "FIRST_RUN_PASSWORD =$FIRST_RUN_PASSWORD"
echo "SECOND_RUN_PASSWORD=$SECOND_RUN_PASSWORD"
[ "$FIRST_RUN_PASSWORD" != "$SECOND_RUN_PASSWORD" ] && echo "两次口令不同 ✓" || echo "两次口令相同 ✗（不应该出现）"
```

预期看到 `两次口令不同 ✓`。

> **这就是本节剧本的全部价值**：同一段消费代码、配置一字未改、中间被运维强制换过一次锁——它依然正常工作。它不需要重启、不需要改配置、不需要重新读环境变量；它只是按部就班地『要进门就去前台领钥匙』，剩下的『换锁/收旧钥匙/把新钥匙交给前台』全部由 Vault 与 LDAP 之间的轮转协议悄无声息地完成。这就是 9.5 节正文一开始那句承诺的兑现：**alice 的口令的所有权从『写在文件里的人手里』整段搬到了 Vault 手里**。

## 4.5 顺手验收：第一次那把老钥匙现在该开不了门了

```bash
ldapsearch -x -H ldap://127.0.0.1:389 \
  -D "cn=alice,ou=users,dc=learn,dc=example" -w "$FIRST_RUN_PASSWORD" \
  -b "cn=alice,ou=users,dc=learn,dc=example" -s base cn 2>&1 | tail -3
```

预期输出：`ldap_bind: Invalid credentials (49)`。

这一步是为了把 4.3 与 4.4 的结论钉死：**老钥匙是真的作废了**，应用之所以第二次仍能进门，唯一的原因是它去前台领了一把新钥匙——而不是因为 LDAP 还认旧钥匙。

---

## ✅ 验收

- [ ] `/root/app.sh` 第一次运行，最后一行输出 `bind 成功——...`
- [ ] `vault write -f ldap/rotate-role/learn` 成功
- [ ] `/root/app.sh` 第二次运行，最后一行依然 `bind 成功——...`，**但第一行打印的口令字符串与上一次不同**
- [ ] `FIRST_RUN_PASSWORD` 在轮转之后再去 bind LDAP，得到 `Invalid credentials (49)`
