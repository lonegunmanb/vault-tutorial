# 第三步：用 curl 与浏览器分别跑完整两阶段登录

现在 alice 已有 TOTP key。接下来手写一遍网站后端的状态机：先拿 LDAP token，但把它当作 pending token；再用它调用 `totp/code/alice`；`valid=true` 后才认为登录完成。

## 3.1 第一阶段：LDAP 密码 -> pending token

```bash
RESP1=$(curl -s -X POST \
  -d '{"password":"LdapPass!2026"}' \
  http://127.0.0.1:8200/v1/auth/ldap/login/alice)
TOKEN=$(echo "$RESP1" | jq -r '.auth.client_token')
echo "$RESP1" | jq '{token_issued: (.auth.client_token != null), entity_id: .auth.entity_id, policies: .auth.policies}'
echo "pending token prefix: ${TOKEN:0:12}..."
```{{exec}}

这时如果是网站后端，应该把 `$TOKEN` 放进服务端 pending session，而不是发给浏览器。

## 3.2 第二阶段：OTP -> `valid=true`

```bash
OTP=$(oathtool --totp -b "$(cat /root/alice-totp-secret)")
echo "current OTP = $OTP"

curl -s -X POST \
  -H "X-Vault-Token: $TOKEN" \
  -d "{\"code\":\"$OTP\"}" \
  http://127.0.0.1:8200/v1/totp/code/alice | jq
```{{exec}}

看到 `valid=true` 后，这枚 token 才能从 pending session 升级成正式登录态。拿它查一下自己：

```bash
curl -s -H "X-Vault-Token: $TOKEN" \
  http://127.0.0.1:8200/v1/auth/token/lookup-self \
  | jq '{display_name: .data.display_name, policies: .data.policies, entity_id: .data.entity_id, ttl: .data.ttl}'
```{{exec}}

## 3.3 浏览器视角：完整流程跑一遍

实验主机的 `:8080` 已经映射出来。在终端上方点击 **Traffic / Accessing Ports -> 8080**，会在新标签里打开网站。

然后按这套节奏：

1. 用户名 `alice`、密码 `LdapPass!2026`，点登录；
2. 页面会跳到 `/mfa`，这时网站后端已经把 Vault LDAP token 存在服务端 pending session；
3. 在终端里等到 OTP 数字变化后再算一个新值，避免重用刚才 curl 已经提交过的 code：

```bash
oathtool --totp -b "$(cat /root/alice-totp-secret)"
```{{exec}}

把它填进网页，点提交。成功后会跳到 `/protected`，能看到 `entity_id` / `policies` / `username`。

## 3.4 看网站后端日志

```bash
tail -30 /var/log/web-app.log
```{{exec}}

留意 `first factor accepted` 与 `second factor accepted` 两条日志：前者说明 pending token 已建立，后者说明 TOTP 通过后 token 被升级为正式 session。

## 3.5 主动撤销 token（登出）

在网页上点“登出（revoke-self）”，或者用刚才的 `$TOKEN` 在终端模拟：

```bash
curl -s -o /dev/null -w 'revoke-self: HTTP %{http_code}\n' \
  -X POST -H "X-Vault-Token: $TOKEN" \
  http://127.0.0.1:8200/v1/auth/token/revoke-self

curl -s -o /dev/null -w 'after revoke, lookup-self: HTTP %{http_code}\n' \
  -H "X-Vault-Token: $TOKEN" \
  http://127.0.0.1:8200/v1/auth/token/lookup-self
```{{exec}}

第二次 `lookup-self` 应该是 `403`，说明 token 真的被撤了。

---

至此两阶段登录的正常路径已经跑通。下一步看反面情况。