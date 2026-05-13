# 第 4 步：用最小 bash 应用脚本消费 Vault 当下持有的口令

到这里 Vault 这一侧的事情已经全部就绪：alice 的口令是一段只有 Vault 知道的随机串，要用 alice 的身份做事，就必须在使用前向 Vault 取一次。本步的目的不是再写新的 Vault 命令，而是把『应用应当怎么消费 Vault 当下持有的口令』这件事用最朴素的代码示范一遍——并通过『前后两次运行之间手动轮一次』看到这套消费方式**对轮转完全透明**。

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
> - 脚本运行时**只**读 `ldap/static-cred/learn` 这一条路径——这与 9.4 节正文第 5 节给出的 `consumer-policy.hcl` 完全对应，意味着这段代码上线时只需要绑那一条最小策略。

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

## 4.3 在两次运行之间手动轮一次口令

```bash
vault write -f ldap/rotate-role/learn
```

预期输出：`Success! Data written to: ldap/rotate-role/learn`。

此时 Vault 里 `password` 已经换成新值；同时 LDAP 那一端 alice 的 `userPassword` 也已被覆盖。**任何还把上一次口令写在配置文件里的应用此刻都已经认证不了 LDAP 了**——这正是『写死口令』方案在零接触轮转下的死亡场景。

## 4.4 第二次运行

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

> **这就是本节剧本的全部价值**：同一段消费代码，在『被运维强制轮转一次』的中间动作面前**完全没有感知**——它既不需要重启、也不需要改配置、更不需要重新读环境变量；它只是按部就班地『要用 alice 的身份就向 Vault 取一次口令』，剩下的全部由 Vault 与 LDAP 之间的轮转协议悄无声息地完成。这就是 9.4 节正文一开始给出的那一句承诺：**alice 的口令的所有权从『写在文件里的人手里』整段搬到了 Vault 手里**。

## 4.5 顺手验收：上一次运行那份口令现在该失效了

```bash
ldapsearch -x -H ldap://127.0.0.1:389 \
  -D "cn=alice,ou=users,dc=learn,dc=example" -w "$FIRST_RUN_PASSWORD" \
  -b "cn=alice,ou=users,dc=learn,dc=example" -s base cn 2>&1 | tail -3
```

预期输出：`ldap_bind: Invalid credentials (49)`。

---

## ✅ 验收

- [ ] `/root/app.sh` 第一次运行，最后一行输出 `bind 成功——...`
- [ ] `vault write -f ldap/rotate-role/learn` 成功
- [ ] `/root/app.sh` 第二次运行，最后一行依然 `bind 成功——...`，**但第一行打印的口令字符串与上一次不同**
- [ ] `FIRST_RUN_PASSWORD` 在轮转之后再去 bind LDAP，得到 `Invalid credentials (49)`
