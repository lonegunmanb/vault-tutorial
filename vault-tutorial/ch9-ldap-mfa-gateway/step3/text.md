# 第三步：用 curl 与浏览器分别跑完整两阶段登录

现在 alice 既有 Entity、也有 TOTP 密钥了——按 9.9 §5 把两阶段登录跑通。

## 3.1 第一阶段：curl 把密码丢给 Vault，拿到 `mfa_request_id`

```bash
RESP1=$(curl -s -X POST \
  -d '{"password":"LdapPass!2026"}' \
  http://127.0.0.1:8200/v1/auth/ldap/login/alice)
echo "$RESP1" | jq '{client_token: .auth.client_token, mfa_request_id: .auth.mfa_requirement.mfa_request_id}'
MRID=$(echo "$RESP1" | jq -r '.auth.mfa_requirement.mfa_request_id')
echo "MFA_REQUEST_ID=$MRID"
```{{exec}}

`client_token` 是空、`mfa_request_id` 有值——和 9.9 §5.1 完全对得上。

## 3.2 第二阶段：算出当前 OTP，立刻 `validate`

`mfa_request_id` 默认 5 分钟过期，但更现实的麻烦是它**一次性**：算 OTP → 立刻提交是最稳妥的姿势。把两步串成一条管线：

```bash
OTP=$(oathtool --totp -b "$(cat /root/alice-totp-secret)")
TOTP_METHOD_ID="$(cat /root/totp-method-id)"
echo "current OTP = $OTP"

curl -s -X POST \
  -d "{\"mfa_request_id\":\"$MRID\",\"mfa_payload\":{\"$TOTP_METHOD_ID\":[\"$OTP\"]}}" \
  http://127.0.0.1:8200/v1/sys/mfa/validate \
  | jq '{client_token: .auth.client_token, entity_id: .auth.entity_id, policies: .auth.policies}'
```{{exec}}

`client_token` 现在是 `hvs.xxxx`——登录完成。可以拿它去 `lookup-self`：

```bash
TOTP_METHOD_ID="$(cat /root/totp-method-id)"
TOKEN=$(curl -s -X POST \
  -d "{\"mfa_request_id\":\"$MRID\",\"mfa_payload\":{\"$TOTP_METHOD_ID\":[\"$(oathtool --totp -b "$(cat /root/alice-totp-secret)")\"]}}" \
  http://127.0.0.1:8200/v1/sys/mfa/validate \
  | jq -r '.auth.client_token')
# 注意：上面这次 validate 会失败 —— 因为 MRID 已经被消耗掉了！
# 我们重新走一次完整流程：
RESP1=$(curl -s -X POST -d '{"password":"LdapPass!2026"}' \
  http://127.0.0.1:8200/v1/auth/ldap/login/alice)
MRID=$(echo "$RESP1" | jq -r '.auth.mfa_requirement.mfa_request_id')
TOKEN=$(curl -s -X POST \
  -d "{\"mfa_request_id\":\"$MRID\",\"mfa_payload\":{\"$TOTP_METHOD_ID\":[\"$(oathtool --totp -b "$(cat /root/alice-totp-secret)")\"]}}" \
  http://127.0.0.1:8200/v1/sys/mfa/validate \
  | jq -r '.auth.client_token')
echo "TOKEN=$TOKEN"

curl -s -H "X-Vault-Token: $TOKEN" \
  http://127.0.0.1:8200/v1/auth/token/lookup-self \
  | jq '{display_name: .data.display_name, policies: .data.policies, entity_id: .data.entity_id, ttl: .data.ttl}'
```{{exec}}

`display_name` 长这样 `ldap-alice`、`entity_id` 就是 step 1 看到的那一串——这条 token 就代表了"alice 用 LDAP 密码 + TOTP 完成了登录"。

## 3.3 浏览器视角：完整流程跑一遍

实验主机的 `:8080` 已经映射出来。在终端上方点击 **Traffic / Accessing Ports → 8080**，会在新标签里打开网站。

然后按这套节奏：

1. 用户名 `alice`、密码 `LdapPass!2026`，点登录；
2. 页面会跳到 `/mfa`——这一刻网站后端已经把 `mfa_request_id` 存在了服务端 session 里，浏览器只看到一个 `sid` Cookie；
3. 在终端里实时算一个 OTP：

```bash
oathtool --totp -b "$(cat /root/alice-totp-secret)"
```{{exec}}

把它填进网页，点"提交"——会跳到 `/protected`，能看到 `entity_id` / `policies` / `username`。

## 3.4 看网站后端的日志，对照两次 HTTP 调用

```bash
tail -20 /var/log/web-app.log
```{{exec}}

留意两条 access log：一条 `POST /login`、一条 `POST /mfa`——这就是 9.9 §6 里那两段处理器的真实输出。

## 3.5 主动撤销 token（登出）

在网页上点"登出（revoke-self）"按钮，或者用刚才的 `$TOKEN` 在终端模拟：

```bash
curl -s -o /dev/null -w "revoke-self: HTTP %{http_code}\n" \
  -X POST -H "X-Vault-Token: $TOKEN" \
  http://127.0.0.1:8200/v1/auth/token/revoke-self

curl -s -o /dev/null -w "after revoke, lookup-self: HTTP %{http_code}\n" \
  -H "X-Vault-Token: $TOKEN" \
  http://127.0.0.1:8200/v1/auth/token/lookup-self
```{{exec}}

第二次 `lookup-self` 应该 `403`——token 真的被撤了。

---

至此两阶段登录的"正常路径"被你完整跑了三遍（一次纯 curl、一次浏览器、一次显式 revoke）。下一步看反面情况。
