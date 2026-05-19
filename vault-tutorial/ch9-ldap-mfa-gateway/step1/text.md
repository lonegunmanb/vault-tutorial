# 第一步：检查 Vault 里预置好的四块积木

按 9.9 §3 的清单，要让"网站 + Vault + LDAP + TOTP"这套登录跑起来，Vault 这一侧要装好**四块积木**。背景脚本已经把前三块系统级积木装好、还给 alice 预建了 Entity（破解了 §4 那个鸡生蛋的前半步），**但故意没给她生成 TOTP 密钥**——这一步留到 step 2。

下面用四条命令逐一确认。

## 1.1 LDAP 认证方法已经接上了 OpenLDAP

```bash
vault read auth/ldap/config
```{{exec}}

应该看到 `url=ldap://127.0.0.1:389`、`userdn=ou=users,dc=learn,dc=example`。这意味着任何 `vault login -method=ldap` 都会把用户名拼成 `cn=<user>,ou=users,dc=learn,dc=example` 去 OpenLDAP 那边做 simple bind。

顺便看一眼 alice 在 LDAP 里确实存在：

```bash
ldapsearch -x -LLL -H ldap://127.0.0.1:389 \
  -D "cn=admin,dc=learn,dc=example" -w 2LearnVault \
  -b "cn=alice,ou=users,dc=learn,dc=example" -s base cn sn
```{{exec}}

## 1.2 TOTP MFA method 已经创建

```bash
cat /root/totp-method-id
vault read sys/mfa/method/totp/my-totp
```{{exec}}

`vault read` 输出里的 `id` 是一个 UUID——这就是 9.9 §3.2 里强调的"真正的引用 key"，后续 `mfa_payload` 要用它而不是 `my-totp` 这个名字。它也已经写进 `/root/totp-method-id`，需要时可以刷新到当前 shell：

```bash
export TOTP_METHOD_ID="$(cat /root/totp-method-id)"
echo "$TOTP_METHOD_ID"
```{{exec}}

## 1.3 Login Enforcement 已经把 LDAP 与 TOTP 绑在一起

```bash
vault read sys/mfa/login-enforcement/ldap-mfa-enforce
```{{exec}}

重点看：

- `auth_method_types = [ldap]`：覆盖所有 LDAP 类型的认证挂载；
- `auth_method_accessors`：另一个收口，限定到 LDAP 这一个具体挂载实例（accessor 在 `/root/ldap-accessor`）；
- `mfa_method_ids` 里就是 1.2 那条 method ID。

只要这条 enforcement 在，**所有 `auth/ldap/login` 调用都会先回 `mfa_requirement` 而不是直接发 Token**——这是 step 3 那条 `curl` 流程的根本前提。

## 1.4 alice 的 Identity Entity + alias 已经预建好

```bash
cat /root/alice-entity-id
vault read identity/entity/name/alice | head -20
vault list identity/entity-alias/id | head -5
```{{exec}}

第一行就是 alice 的 entity_id；`vault read identity/entity/name/alice` 里能看到 `aliases` 数组中有一条 `mount_accessor` 指向 LDAP 挂载。

> **为什么要在 init 阶段就把 Entity 建好？** 因为 9.9 §4 那个"新用户登录死循环"的破解办法正是：管理员**先**把 Entity 建出来（一条 `vault write identity/entity name=alice`）+ 把 LDAP 这边的 alice 与它绑成同一个人（一条 `vault write identity/entity-alias`），**才能**对她做 `admin-generate`。这两条已经替你跑完了；step 2 你要跑的是这个流程的最后一步——`admin-generate`。

## 1.5 alice 还没有 TOTP 密钥

```bash
ENTITY_ID=$(cat /root/alice-entity-id)
echo "alice entity_id = $ENTITY_ID"
ls -la /root/alice-totp-secret 2>&1 || echo "(没有 secret 文件 → 还没 enroll)"
```{{exec}}

`/root/alice-totp-secret` 这个文件还不存在——step 2 跑完 enrollment 才会出现。

## 1.6 网站和审计设备都已经在跑

```bash
curl -s -o /dev/null -w "web-app: HTTP %{http_code}\n" http://127.0.0.1:8080/
vault audit list
wc -l /var/log/vault-audit.log
```{{exec}}

`HTTP 200` 表示 Go 网站已经在 `:8080` 监听；`file` 审计设备指向 `/var/log/vault-audit.log`，step 4 会从这里翻历史。

---

到此四块积木的状态盘点完毕：**系统级三块齐全 + alice 有 Entity 但没 TOTP**。这恰好就是 9.9 §4 描述的"鸡生蛋问题正发生的瞬间"，下一步我们就把它解开。
