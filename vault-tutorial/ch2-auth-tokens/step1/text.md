# 第一步：auth method 是 Token 工厂

文档 §2 那句话：

> Upon authentication, a token is generated.

我们启用 userpass，建一个用户，登录，然后看清"登录到底产生了什么"。

启用 userpass auth method（挂在默认路径 `auth/userpass/`）：

```bash
vault auth enable userpass
```

创建一个用户 `alice`，密码 `s3cr3t`，给她默认 policy `default`：

```bash
vault write auth/userpass/users/alice \
  password=s3cr3t \
  token_policies=default
```

现在以 alice 身份登录，把整个响应抓成 JSON 看清楚字段：

```bash
vault login -format=json -method=userpass username=alice password=s3cr3t > /root/alice-login.json
cat /root/alice-login.json | jq .auth
```

注意输出里几个关键字段：

- `client_token`：形如 `hvs.CAESI...` —— **service token 的 `hvs.` 前缀**
- `accessor`：例如 `XzLnJq...` —— Token 的"门牌号"，第 3 步会用
- `policies` / `token_policies`：实际生效的策略
- `metadata.username`：`alice`，由 userpass auth method 注入
- `orphan: true` —— 文档 §3.3 说过：**任何非 token 的 auth method 登录
  默认都是 orphan**

提取一下 alice 的 token，留着后续用：

```bash
ALICE_TOKEN=$(jq -r .auth.client_token /root/alice-login.json)
ALICE_ACCESSOR=$(jq -r .auth.accessor /root/alice-login.json)
echo "ALICE_TOKEN=$ALICE_TOKEN"
echo "ALICE_ACCESSOR=$ALICE_ACCESSOR"
```

用 admin 身份查这个 token 的 metadata，验证 `display_name` 字段：

```bash
vault token lookup "$ALICE_TOKEN" | grep -E "display_name|policies|orphan|ttl"
```

`display_name` = `userpass-alice` ——这就是文档里说的"户籍信息"，
即使将来日志里只看到 `hvs.xxxxx`，也能从 token lookup 反查出当初是
谁通过哪种 auth method 登的。

**这一步的核心结论**：`vault login` 命令最终的产物就是一条新的 service
token 记录，**之后所有的鉴权动作都是这个 token 自己说了算，跟 userpass
后台那边的 alice 用户已经无关了**。即便此时把 alice 用户删掉：

```bash
vault delete auth/userpass/users/alice
```

这个 `$ALICE_TOKEN` 仍然有效（直到 TTL 到期或被显式 revoke）：

```bash
VAULT_TOKEN=$ALICE_TOKEN vault token lookup-self | grep -E "display_name|policies"
```

——证实了文档里"Token 自身的元数据决定一切"的论断。
