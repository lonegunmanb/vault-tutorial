# 第一步：检查 OSS 两阶段登录的基础配置

本实验不用 `sys/mfa`，因为它是 Vault Enterprise Login MFA 的控制面。OSS 版要跑通“网站 + Vault + LDAP + TOTP”，需要三块基础：LDAP auth、`totp` secrets engine、以及 alice 的最小 policy/entity。

## 1.1 LDAP 认证方法已经接上 OpenLDAP

```bash
vault read auth/ldap/config
```{{exec}}

应该看到 `url=ldap://127.0.0.1:389`、`userdn=ou=users,dc=learn,dc=example`。这意味着网站调用 `auth/ldap/login/alice` 时，Vault 会去 OpenLDAP 做 simple bind。

顺便确认 alice 在 LDAP 里确实存在：

```bash
ldapsearch -x -LLL -H ldap://127.0.0.1:389 \
  -D cn=admin,dc=learn,dc=example -w 2LearnVault \
  -b cn=alice,ou=users,dc=learn,dc=example -s base cn sn
```{{exec}}

## 1.2 TOTP secrets engine 已经启用，但 alice 还没有 key

```bash
vault secrets list | grep '^totp/'
cat /root/totp-key-name
vault list totp/keys 2>&1 || true
```{{exec}}

`/root/totp-key-name` 里是 `alice`。`vault list totp/keys` 现在没有 alice，因为 step 2 才会创建 `totp/keys/alice`。

再直接读一下 alice 的 key：

```bash
vault read totp/keys/alice 2>&1 || true
ls -la /root/alice-totp-secret 2>&1 || echo '(没有 secret 文件 -> 还没 enroll)'
```{{exec}}

## 1.3 alice 的 Entity + alias + policy 已经预建好

```bash
vault policy read alice-totp-login
cat /root/alice-entity-id
vault read identity/entity/name/alice | head -30
vault list identity/entity-alias/id | head -5
```{{exec}}

重点看 policy：它只允许 alice 的 LDAP token 调用 `totp/code/alice` 的 `update`，也就是“提交一个 OTP 给 Vault 验证”。它没有 `totp/keys/*` 权限，所以日常登录路径不能创建或覆盖 TOTP seed。

## 1.4 网站和审计设备都已经在跑

```bash
curl -s -o /dev/null -w 'web-app: HTTP %{http_code}\n' http://127.0.0.1:8080/
vault audit list
wc -l /var/log/vault-audit.log
```{{exec}}

`HTTP 200` 表示 Go 网站已经在 `:8080` 监听；`file` 审计设备指向 `/var/log/vault-audit.log`，step 4 会从这里翻历史。

---

到这里，基础状态是：LDAP 可用、`totp` 引擎可用、alice 有最小验证权限，但还没有 `totp/keys/alice`。下一步先亲眼看这个“还没绑定 TOTP”的状态会如何挡住完整登录。