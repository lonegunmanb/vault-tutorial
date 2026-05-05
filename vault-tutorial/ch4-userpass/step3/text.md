# 第三步：使用 CLI/API 登录并验证 token 权限

![Step 3 故事板：alice 和 bob 登录后拿到不同权限的 token](../assets/step3-userpass-login-story.png)

登录成功后，响应里的 `auth.client_token` 就是后续访问 Vault 的 token；`auth.policies` / `auth.token_policies` 展示这枚 token 带了哪些 policy。

## 3.1 alice 用 CLI 登录

```bash
ALICE_LOGIN=$(vault login \
  -method=userpass \
  username=alice \
  password=alice-pass \
  -format=json)

echo "$ALICE_LOGIN" | jq '.auth | {policies, token_policies, metadata, lease_duration}'
ALICE_TOKEN=$(echo "$ALICE_LOGIN" | jq -r '.auth.client_token')
```

## 3.2 alice 可以读，但不能写

```bash
VAULT_TOKEN="$ALICE_TOKEN" vault kv get secret/team/app

VAULT_TOKEN="$ALICE_TOKEN" vault kv put secret/team/app username=service password=alice-try
```

第二条写入命令应该失败，因为 `team-reader` 只有 `read` 能力。

## 3.3 bob 用 API 登录

```bash
BOB_LOGIN=$(curl --silent \
  --request POST \
  --data '{"password":"bob-pass"}' \
  "$VAULT_ADDR/v1/auth/userpass/login/bob")

echo "$BOB_LOGIN" | jq '.auth | {policies, token_policies, metadata, lease_duration}'
BOB_TOKEN=$(echo "$BOB_LOGIN" | jq -r '.auth.client_token')
```

API 登录路径是 `/auth/userpass/login/:username`，请求体中提交 `password`，响应里的 token 位于 `auth.client_token`。

## 3.4 bob 可以更新 secret

```bash
VAULT_TOKEN="$BOB_TOKEN" vault kv put secret/team/app username=service password=updated-by-bob
VAULT_TOKEN="$BOB_TOKEN" vault kv get secret/team/app
```

## 3.5 这一步的核心闭环

同一个 auth method 可以给不同用户签发不同 policy 的 token；身份验证回答“你是谁”，policy 继续回答“你能做什么”。