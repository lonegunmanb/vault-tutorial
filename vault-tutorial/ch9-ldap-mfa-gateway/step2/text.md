# 第二步：复现未绑定状态，再跑通 enrollment

OSS 编排方案里，Vault LDAP auth 会在密码正确时直接发 token。网站的职责是先把这枚 token 扣在服务端 pending session 中，直到 TOTP 也通过才算登录完成。

## 2.1 第一阶段会成功，但第二阶段没有 key 可用

先直接调用 Vault LDAP auth：

```bash
RESP=$(curl -s -X POST \
  -d '{"password":"LdapPass!2026"}' \
  http://127.0.0.1:8200/v1/auth/ldap/login/alice)
echo "$RESP" | jq '{token_issued: (.auth.client_token != null), policies: .auth.policies, entity_id: .auth.entity_id}'
TOKEN=$(echo "$RESP" | jq -r '.auth.client_token')
```{{exec}}

这枚 `$TOKEN` 只说明 alice 的 LDAP 密码正确。网站在这个时刻不能把用户放进 `/protected`，而是要进入 pending session。

现在模拟第二阶段：用这枚 pending token 去验证一个 OTP。由于还没有 `totp/keys/alice`，Vault 没有 seed 可算：

```bash
curl -s -X POST \
  -H "X-Vault-Token: $TOKEN" \
  -d '{"code":"000000"}' \
  http://127.0.0.1:8200/v1/totp/code/alice | jq

curl -s -o /dev/null -w 'revoke pending token: HTTP %{http_code}\n' \
  -X POST -H "X-Vault-Token: $TOKEN" \
  http://127.0.0.1:8200/v1/auth/token/revoke-self
```{{exec}}

这就是“首次绑定前”的卡点：密码阶段能过，但 OTP 阶段没有 key，网站必须拒绝并撤销 pending token。

## 2.2 跑 enrollment：创建 `totp/keys/alice`

生产里这一步通常是独立 enrollment service：用户拿一次性邀请链接打开，后端用高权限 token 创建 `totp/keys/alice`，把 `otpauth://` URL 或二维码给用户绑定 Authenticator。这里用一段 shell 脚本模拟：

```bash
/usr/local/bin/enroll-alice.sh
```{{exec}}

脚本做三件事：

1. 调 `vault write -format=json totp/keys/alice generate=true exported=true ...`；
2. 从响应的 `otpauth://...?secret=...` URL 中解析 Base32 secret；
3. 把 secret 写入 `/root/alice-totp-secret`，实验里用 `oathtool` 模拟 Authenticator App。

## 2.3 确认 key 已存在，并算出当前 OTP

```bash
vault read totp/keys/alice
oathtool --totp -b "$(cat /root/alice-totp-secret)"
```{{exec}}

记住这个数字只在当前时间窗口有效；如果之后要在网页里输入，重新运行一遍命令拿最新值。

---

现在 alice 已经完成 enrollment。下一步用 curl 和浏览器跑完整两阶段登录。