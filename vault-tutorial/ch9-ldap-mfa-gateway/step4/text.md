# 第四步：错误 OTP / code 重放 / 审计日志

这一步验证 OSS 编排方案里的几个关键边界：OTP 错了要拒绝并 revoke pending token；同一个 TOTP code 不能在当前窗口里重复使用；审计日志能看到 LDAP 登录、TOTP 校验和 revoke。

## 4.1 错误 OTP 返回 `valid=false`

```bash
RESP1=$(curl -s -X POST -d '{"password":"LdapPass!2026"}' \
  http://127.0.0.1:8200/v1/auth/ldap/login/alice)
TOKEN=$(echo "$RESP1" | jq -r '.auth.client_token')

GOOD=$(oathtool --totp -b "$(cat /root/alice-totp-secret)")
BAD=$(printf '%06d' $(( (10#$GOOD + 1) % 1000000 )))
echo "good=$GOOD bad=$BAD"

curl -s -X POST \
  -H "X-Vault-Token: $TOKEN" \
  -d "{\"code\":\"$BAD\"}" \
  http://127.0.0.1:8200/v1/totp/code/alice | jq

curl -s -o /dev/null -w 'revoke pending token: HTTP %{http_code}\n' \
  -X POST -H "X-Vault-Token: $TOKEN" \
  http://127.0.0.1:8200/v1/auth/token/revoke-self
```{{exec}}

`valid=false` 是正常业务结果，不是 403。网站要根据这个字段拒绝登录，并撤销 pending token。

## 4.2 同一个 TOTP code 不能重放

```bash
RESP1=$(curl -s -X POST -d '{"password":"LdapPass!2026"}' \
  http://127.0.0.1:8200/v1/auth/ldap/login/alice)
TOKEN=$(echo "$RESP1" | jq -r '.auth.client_token')
OTP=$(oathtool --totp -b "$(cat /root/alice-totp-secret)")
echo "OTP=$OTP"

echo '=== first submit ==='
curl -s -X POST \
  -H "X-Vault-Token: $TOKEN" \
  -d "{\"code\":\"$OTP\"}" \
  http://127.0.0.1:8200/v1/totp/code/alice | jq

echo '=== replay same code ==='
curl -s -X POST \
  -H "X-Vault-Token: $TOKEN" \
  -d "{\"code\":\"$OTP\"}" \
  http://127.0.0.1:8200/v1/totp/code/alice | jq
```{{exec}}

第二次通常会返回 `code already used; wait until the next time period`。这说明 Vault provider 模式自己维护了当前窗口内的 code 防重放状态。

## 4.3 翻审计日志：看完整链路

```bash
echo '=== 最近 12 条关键记录 ==='
grep -E 'auth/ldap/login|totp/code/alice|auth/token/revoke-self' /var/log/vault-audit.log \
  | jq -c '{type, time, path: .request.path, op: .request.operation, err: .error // .response.data.error}' \
  | tail -12
```{{exec}}

你会看到 `auth/ldap/login/alice`、`totp/code/alice` 与 `auth/token/revoke-self` 的 request/response 记录。排查“密码过了但 OTP 为什么没过”时，audit log 是第一现场。

## 4.4 对照：直接拿 LDAP token 的风险

```bash
RESP1=$(curl -s -X POST -d '{"password":"LdapPass!2026"}' \
  http://127.0.0.1:8200/v1/auth/ldap/login/alice)
TOKEN=$(echo "$RESP1" | jq -r '.auth.client_token')

curl -s -H "X-Vault-Token: $TOKEN" \
  http://127.0.0.1:8200/v1/auth/token/lookup-self \
  | jq '{display_name: .data.display_name, policies: .data.policies}'

curl -s -o /dev/null -w 'cleanup token: HTTP %{http_code}\n' \
  -X POST -H "X-Vault-Token: $TOKEN" \
  http://127.0.0.1:8200/v1/auth/token/revoke-self
```{{exec}}

这就是为什么网站必须把第一阶段 token 留在 pending session，而不是把它暴露给浏览器：Vault OSS 本身不会自动替你强制第二阶段，编排责任在网站后端。

---

至此本实验完成。点击右下角 *Continue* 进入结尾。