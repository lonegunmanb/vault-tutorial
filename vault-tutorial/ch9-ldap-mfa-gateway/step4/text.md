# 第四步：错误 OTP / 一次性 mfa_request_id / 审计日志

9.9 §7 列了几个"容易忽略的工程细节"——这一步把其中三条用真实命令验出来。

## 4.1 错误 OTP 直接被 Vault 当场拒掉

```bash
RESP1=$(curl -s -X POST -d '{"password":"LdapPass!2026"}' \
  http://127.0.0.1:8200/v1/auth/ldap/login/alice)
MRID=$(echo "$RESP1" | jq -r '.auth.mfa_requirement.mfa_request_id')

# 故意提交一个肯定不对的 OTP
curl -s -X POST \
  -d "{\"mfa_request_id\":\"$MRID\",\"mfa_payload\":{\"$TOTP_METHOD_ID\":[\"123456\"]}}" \
  http://127.0.0.1:8200/v1/sys/mfa/validate | jq
```{{exec}}

`errors` 里会说类似 *"failed to satisfy enforcement ..."* 或 *"code did not match"*。第二阶段失败 ≠ 第一阶段成功 —— `auth.client_token` 仍然不会出现。

## 4.2 `mfa_request_id` 是一次性的：用过一次再用一次直接报"找不到"

```bash
# 第一次走完整流程，正确 OTP，应该成功
RESP1=$(curl -s -X POST -d '{"password":"LdapPass!2026"}' \
  http://127.0.0.1:8200/v1/auth/ldap/login/alice)
MRID=$(echo "$RESP1" | jq -r '.auth.mfa_requirement.mfa_request_id')

curl -s -X POST \
  -d "{\"mfa_request_id\":\"$MRID\",\"mfa_payload\":{\"$TOTP_METHOD_ID\":[\"$(oathtool --totp -b "$(cat /root/alice-totp-secret)")\"]}}" \
  http://127.0.0.1:8200/v1/sys/mfa/validate | jq '{client_token: .auth.client_token}'

# 紧接着拿"同一个 MRID"再试一次（OTP 故意也算出来个对的）
sleep 1
curl -s -X POST \
  -d "{\"mfa_request_id\":\"$MRID\",\"mfa_payload\":{\"$TOTP_METHOD_ID\":[\"$(oathtool --totp -b "$(cat /root/alice-totp-secret)")\"]}}" \
  http://127.0.0.1:8200/v1/sys/mfa/validate | jq
```{{exec}}

第二次 validate 会回 *"MFA request ID is invalid"* 之类——这就是 9.9 §7 里强调的"OTP 页失败必须回 /login 重走第一阶段"的硬约束。

## 4.3 翻审计日志：整个流程的结构化 JSON

```bash
echo "=== 最近 10 条 ==="
tail -20 /var/log/vault-audit.log | jq -c '{type, path: .request.path, op: .request.operation, mount_type: .request.mount_type, err: .response.data.error // .error}' 2>/dev/null \
  | tail -10

echo ""
echo "=== 只看 ldap/login 和 mfa/validate ==="
grep -E 'auth/ldap/login|sys/mfa/validate' /var/log/vault-audit.log \
  | jq -c '{type, time, path: .request.path, error: .error // .response.data.error}' \
  | tail -10
```{{exec}}

可以看到每一次 `auth/ldap/login/alice` 和 `sys/mfa/validate` 都各对应**两条**记录：`type=request` 和 `type=response`。看 `error` 字段就能立刻分辨哪一次是 4.1 的错 OTP、哪一次是 4.2 的重用 MRID、哪一次是 3.2 的正常成功。

> 这一段就是 9.9 §7 第 4 点的实操样例——再叠加 9.1 那条 `auth/ldap/login` 上的 rate limit quota，"密码暴力破解 + OTP 暴力穷举"两条攻击路径都能在 Vault 这一层挡掉。

## 4.4 把 enforcement 临时撤掉，对比"裸 LDAP 登录"

最后一个对照实验：把 `ldap-mfa-enforce` 删掉再登一次，看看响应变什么样：

```bash
vault delete sys/mfa/login-enforcement/ldap-mfa-enforce

curl -s -X POST -d '{"password":"LdapPass!2026"}' \
  http://127.0.0.1:8200/v1/auth/ldap/login/alice \
  | jq '{client_token: .auth.client_token, mfa_requirement: .auth.mfa_requirement}'

# 立刻把 enforcement 加回来，避免后续误以为没启 MFA
vault write sys/mfa/login-enforcement/ldap-mfa-enforce \
  mfa_method_ids="$TOTP_METHOD_ID" \
  auth_method_types="ldap" \
  auth_method_accessors="$(cat /root/ldap-accessor)"
```{{exec}}

注意中间那一次响应里 `client_token` 直接是 `hvs.xxxx`、`mfa_requirement` 是 `null`——这就是"没强制 MFA"时第一阶段就出 token 的样子。两种响应放在一起，9.9 §5.1 那张协议图就立体起来了。

---

至此本实验完成。点击右下角 *Continue* 进入结尾。
