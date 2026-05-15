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

## 3.7 修复策略：补上 `list` capability

```bash
cat > /root/project-newcup-developers.hcl <<'EOF'
path "project-newcup-secrets/+/*" {
  capabilities = ["create", "read", "update", "list"]
}
EOF

vault policy write project-newcup-developers /root/project-newcup-developers.hcl
```

## 3.8 验证：旧 token **立即生效**，再 LIST 即成功

Vault 的 ACL 评估是 **请求时按策略名实时查表**——也就是说，**修改一条已存在策略的内容会立即对所有挂着该策略的旧 token 生效**，不需要重新登录。直接拿原来那个 `${DEV_TOKEN}` 再发一次 LIST：

```bash
curl --silent --request LIST \
  --header "X-Vault-Token: ${DEV_TOKEN}" \
  ${VAULT_ADDR}/v1/project-newcup-secrets/metadata/ \
  | jq
```

预期输出（与刚才被拒的是**同一个 token**！）：

```json
{
  "request_id": "...",
  "data": {
    "keys": [
      "newcup-aggregator"
    ]
  },
  "mount_type": "kv"
}
```

LIST 成功返回 `["newcup-aggregator"]`——LIST 这条排障闭环就此完成。

> 这条性质对应 ch2-policies §6 的第三条不对称："policy 内容本身修改也是即时生效"。**生产里发现某条 policy 给多了的话，第一反应不应该是去找哪些 token 持有它然后 revoke，而是直接改那条 policy 的内容**——下一次请求就用新规则。

## 3.9 对照实验：什么时候**必须**重新签发 token

为了让"什么时候改策略立即生效、什么时候必须重新签发"这条边界刻在脑子里，下面用同一个 `${DEV_TOKEN}` 再做一次对照——这次给业务**新增一种能力**：允许 `delete`。按 ch2-policies §6 第一条不对称——*token 上挂载的策略列表是签发时冻结的*——所以**新建一条策略再附加给身份，旧 token 拿不到**，必须重新派一个 token 才行。

先单独写一条只授予 `delete` 的新策略（**有意不去改原来那条 `project-newcup-developers`，让差异完全落在"附加策略"这一动作上**）：

```bash
cat > /root/project-newcup-deleter.hcl <<'EOF'
path "project-newcup-secrets/+/*" {
  capabilities = ["delete"]
}
EOF

vault policy write project-newcup-deleter /root/project-newcup-deleter.hcl
```

先用旧 `${DEV_TOKEN}` 试一次 DELETE（它身上**只挂着** `project-newcup-developers`，没有 `project-newcup-deleter`）：

```bash
curl --silent --request DELETE \
  --header "X-Vault-Token: ${DEV_TOKEN}" \
  ${VAULT_ADDR}/v1/project-newcup-secrets/metadata/newcup-aggregator \
  -o /tmp/del-old.json -w "HTTP %{http_code}\n"
cat /tmp/del-old.json
```

预期：`HTTP 403` + `permission denied`。这就是关键证据——**即使 `project-newcup-deleter` 这条策略此刻在 Vault 里已经存在并写明了 delete 权限，旧 token 也拿不到它**，因为旧 token 上冻结的策略列表里**根本没有这个名字**。

现在派一个**同时挂两条策略**的新 token，再试一次 DELETE：

```bash
NEW_DEV_TOKEN=$(vault token create \
  -policy=project-newcup-developers \
  -policy=project-newcup-deleter \
  -format=json | jq -r '.auth.client_token')

curl --silent --request DELETE \
  --header "X-Vault-Token: ${NEW_DEV_TOKEN}" \
  ${VAULT_ADDR}/v1/project-newcup-secrets/metadata/newcup-aggregator \
  -w "HTTP %{http_code}\n"
```

预期：`HTTP 204`，机密被成功删除。新旧两个 token 行为差异的**唯一变量**就是"签发时挂的 policies 列表"——这就是 ch2-policies §6 第一条不对称的实证。

> **生产里规避"必须重派 token"的办法**：把策略**挂在 entity / group 上**而不是直接挂在 token 上。ch2-identity-entity §5.1 明确指出 entity / group 上的策略**也是请求时实时求值的**——给 entity 加一条新策略，旧 token 下次请求就直接获得新权限，不必重派。直接 `-policy=` 写到 token 上的做法只在"短命 service token、不依赖身份层"的场景才合适。

## 3.10 这一步的核心闭环

学员把 9.5 节正文最难的情景四（"客户端拿到 permission denied、必须靠审计日志反推根因"）从头到尾走了一遍，并把"什么时候改策略立即生效、什么时候必须重新签发"这条 ACL 边界亲手验证了一次：

1. 用受限 token 触发 `permission denied`（客户端侧只看到不可解释的拒绝）；
2. 从审计日志中 grep 出 `policy_results.allowed: false` 与 `operation: list` 两个关键字段（运维侧才能拿到的信息）；
3. 用 `vault policy read` 对照策略原文，确认 capability 缺失；
4. 补上 `list` capability 后，**用同一个旧 token 直接 LIST 成功**——印证 ch2-policies §6 "policy 内容修改即时生效"；
5. 再写一条全新的 `project-newcup-deleter` 策略——**旧 token DELETE 仍 403、新派的 token DELETE 成功**——印证 ch2-policies §6 "token 上挂载的策略列表在签发时冻结"。两个对照实验合起来把"修改 vs 附加"这条边界彻底钉死。
