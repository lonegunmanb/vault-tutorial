# 第三步：策略权限不足 — 从审计日志反推 `list` capability 缺失

## 3.1 沿用第二步的 dev 服务器，启用 file 审计设备

第二步留下的 dev 服务器仍在运行（端口 8200，root token 是 `root`）。先确保环境变量正确：

```bash
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'
vault status > /dev/null && echo "dev 服务器在运行"
```

挂载 file 审计设备，把审计日志落到 `/var/log/vault_audit.log`：

```bash
vault audit enable file file_path=/var/log/vault_audit.log
```

## 3.2 挂载 KV 引擎并写入一份测试机密

```bash
vault secrets enable -path=project-newcup-secrets -version=2 kv
vault kv put project-newcup-secrets/newcup-aggregator \
  api-key=3DC9E750-B2D0-48B5-9234-53B0237961FE \
  project=newcup-api
```

## 3.3 故意写一条**漏掉 `list` capability** 的策略

完全照搬 9.5 节情景四的策略原文——只授予 `create / read / update`，**不授予 `list`**：

```bash
cat > /root/project-newcup-developers.hcl <<'EOF'
path "project-newcup-secrets/+/*" {
  capabilities = ["create", "read", "update"]
}
EOF

vault policy write project-newcup-developers /root/project-newcup-developers.hcl
```

## 3.4 用基于该策略的 token 试图 LIST，触发 `permission denied`

派生一个仅挂着这条策略的 token：

```bash
DEV_TOKEN=$(vault token create -policy=project-newcup-developers -format=json \
  | jq -r '.auth.client_token')
echo "派生 token: ${DEV_TOKEN}"
```

用这个 token（**不要用 root token**）发起 LIST 请求：

```bash
curl --silent --request LIST \
  --header "X-Vault-Token: ${DEV_TOKEN}" \
  ${VAULT_ADDR}/v1/project-newcup-secrets/metadata/ \
  | jq
```

预期输出：

```json
{
  "errors": [
    "1 error occurred:\n\t* permission denied\n\n"
  ]
}
```

注意：**Vault 给客户端的回复里没有任何关于"被哪条策略以什么理由拒绝"的细节**。要找根因必须回到运维侧的审计日志。

## 3.5 取证：从审计日志中 grep 出对应条目

审计日志已经把这次失败请求完整记下来了。先看最后一条 LIST 操作的审计记录：

```bash
grep '"operation":"list"' /var/log/vault_audit.log | tail -n 1 | jq
```

预期输出会是一个完整的 JSON 对象，里面包含**两个关键字段**：

- `"policy_results": { "allowed": false }` — Vault 内部 ACL 检查的最终判定结果；
- `"error": "1 error occurred:\n\t* permission denied\n\n"` — 与客户端拿到的错误一致。

把这两条单独提取出来确认：

```bash
grep '"operation":"list"' /var/log/vault_audit.log | tail -n 1 \
  | jq '{ allowed: .auth.policy_results.allowed, operation: .request.operation, path: .request.path, error: .error }'
```

预期：

```json
{
  "allowed": false,
  "operation": "list",
  "path": "project-newcup-secrets/metadata/",
  "error": "1 error occurred:\n\t* permission denied\n\n"
}
```

这就是 9.5 节情景四所讲的"**审计日志是唯一能看到 `allowed: false` 这一字段的地方**"——客户端永远拿不到。

## 3.6 用 `vault policy read` 对照策略原文确认根因

```bash
vault policy read project-newcup-developers
```

预期输出：

```hcl
path "project-newcup-secrets/+/*" {
  capabilities = ["create", "read", "update"]
}
```

到这一步根因清晰浮现——capabilities 只有 `create / read / update`，**漏掉了 `list`**，所以 `LIST` 请求被 ACL 引擎判为不允许。

## 3.7 修复策略并**重新登录**拿新 token

补上 `list` capability：

```bash
cat > /root/project-newcup-developers.hcl <<'EOF'
path "project-newcup-secrets/+/*" {
  capabilities = ["create", "read", "update", "list"]
}
EOF

vault policy write project-newcup-developers /root/project-newcup-developers.hcl
```

按 9.5 节情景四所讲，**策略修改不会自动应用到已经签发的 token**，必须重新派生一个新 token：

```bash
NEW_DEV_TOKEN=$(vault token create -policy=project-newcup-developers -format=json \
  | jq -r '.auth.client_token')
echo "新 token: ${NEW_DEV_TOKEN}"
```

> 验证一下"旧 token 即使在策略更新后依然被拒"：用 `${DEV_TOKEN}` 再 LIST 一次，预期仍然得到 `permission denied`。这一现象本身就是"策略更新非追溯"的直接证据。

```bash
curl --silent --request LIST \
  --header "X-Vault-Token: ${DEV_TOKEN}" \
  ${VAULT_ADDR}/v1/project-newcup-secrets/metadata/ \
  | jq
```

仍然 `permission denied` —— 完全符合 9.5 节"策略修改不会自动应用到已经签发的 token"的判断。

## 3.8 用新 token 再次 LIST，验证修复生效

```bash
curl --silent --request LIST \
  --header "X-Vault-Token: ${NEW_DEV_TOKEN}" \
  ${VAULT_ADDR}/v1/project-newcup-secrets/metadata/ \
  | jq
```

预期输出：

```json
{
  "request_id": "...",
  "lease_id": "",
  "renewable": false,
  "lease_duration": 0,
  "data": {
    "keys": [
      "newcup-aggregator"
    ]
  },
  ...
}
```

LIST 成功返回机密名列表 `["newcup-aggregator"]`——整套排障闭环就此完成。

## 3.9 这一步的核心闭环

学员把 9.5 节正文最难的情景四（"客户端拿到 permission denied、必须靠审计日志反推根因"）从头到尾走了一遍：

1. 用受限 token 触发 `permission denied`（客户端侧只看到不可解释的拒绝）；
2. 从审计日志中 grep 出 `policy_results.allowed: false` 与 `operation: list` 两个关键字段（运维侧才能拿到的信息）；
3. 用 `vault policy read` 对照策略原文，确认 capability 缺失；
4. 补上 capability 后，**亲眼验证旧 token 仍被拒、新 token 可用**——固化"策略修改非追溯"这一关键概念。
