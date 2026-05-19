# 第二步：复现新用户登录死循环，再跑通 enrollment

按 9.9 §4，让我们**先亲眼看到死循环长什么样**，再用 admin-generate 把它解开。

## 2.1 复现死循环：alice 尝试登录，被 `mfa_requirement` 卡住

```bash
curl -s -X POST \
  -d '{"password":"LdapPass!2026"}' \
  http://127.0.0.1:8200/v1/auth/ldap/login/alice | jq
```{{exec}}

关键观察点：

- `auth.client_token` 是**空字符串** —— 这是 9.9 §5.1 描述的"还差一步"的信号；
- `auth.mfa_requirement.mfa_request_id` 有一个 UUID —— 这是第二阶段的入场券；
- `mfa_constraints.ldap-mfa-enforce.any[0].id` 就是你在 step 1 看到的 `TOTP_METHOD_ID`，`uses_passcode: true` 表示它要求一个 6 位数字。

**现在的死循环在哪？** 试着拿这个 `mfa_request_id` 配一个**瞎编的 OTP** 去 validate：

```bash
MRID=$(curl -s -X POST -d '{"password":"LdapPass!2026"}' \
  http://127.0.0.1:8200/v1/auth/ldap/login/alice \
  | jq -r '.auth.mfa_requirement.mfa_request_id')
TOTP_METHOD_ID="$(cat /root/totp-method-id)"

curl -s -X POST \
  -d "{\"mfa_request_id\":\"$MRID\",\"mfa_payload\":{\"$TOTP_METHOD_ID\":[\"000000\"]}}" \
  http://127.0.0.1:8200/v1/sys/mfa/validate | jq
```{{exec}}

返回里 `errors` 一栏会出现 *"entity is missing TOTP secret"* 或类似措辞——这正是 9.9 §4 里"alice 永远登不上"的根因：**没有 TOTP 密钥就过不了 `validate`，但要生成 TOTP 密钥又必须先有 Entity**。Entity 已经被 init 替你建好了，所以现在只差最后一步——给 alice 生成密钥。

## 2.2 跑 enrollment：调 admin-generate，把 secret 交给 Authenticator

生产里这一步通常是一个独立的 **enrollment service**：用户拿一次性邀请链接打开，后端用一份高权限 token 调 `admin-generate`，把返回的 `otpauth://` URL 渲染成二维码 PNG 推给用户。这里我们用一段 shell 脚本模拟它：

```bash
/usr/local/bin/enroll-alice.sh
```{{exec}}

脚本做的事就三件（你可以 `cat /usr/local/bin/enroll-alice.sh` 验证）：

1. 用 root token 调 `POST /v1/sys/mfa/method/totp/my-totp/admin-generate`，带上 alice 的 `entity_id`；
2. 从响应里把 `otpauth://...?secret=XXXX` 那一段 secret 抠出来；
3. 把 secret 写到 `/root/alice-totp-secret`（实验里用 `oathtool` 模拟 Authenticator App）。

> 真实生产里输出的 `barcode` 字段是 Base64 编码的 PNG，前端解码后就能直接显示成二维码图片。

## 2.3 用 `oathtool` 算出当前 6 位 OTP

`oathtool` 是 Linux 上的命令行 TOTP 生成器，给它同一份 secret，它每 30 秒能生成和 Authenticator App **完全一致**的 6 位数字：

```bash
oathtool --totp -b "$(cat /root/alice-totp-secret)"
```{{exec}}

记下这个数字（或者干脆下一节实时再算一次）——它就是 step 3 第二阶段要提交的 OTP。

> 用真实 Authenticator？把 `cat /root/alice-totp-secret` 出来的 Base32 字符串手动添加为一个 TOTP 条目（issuer 填 MyWebsite、account 填 alice），它跟 `oathtool` 算出来的数字会一模一样。

---

`/root/alice-totp-secret` 文件一旦存在，alice 的 enrollment 就算正式完成。下一步开始走完整的两阶段登录。
