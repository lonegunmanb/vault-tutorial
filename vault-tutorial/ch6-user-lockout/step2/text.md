# 第二步：通过 `/sys/locked-users` 查询并解锁用户

承接上一步，alice 此时仍处在锁定状态（lockout_duration = 1 分钟）。本步在该窗口期内完成"查询 → 解锁 → 验证幂等性"。

## 2.1 拿到 userpass 挂载点的 mount accessor

`/sys/locked-users/:mount_accessor/unlock/:alias` 端点的第一个路径参数是挂载点访问器。从 `vault auth list -detailed` 的 `Accessor` 列读取：

```bash
USERPASS_ACCESSOR=$(vault auth list -format=json | jq -r '."userpass/".accessor')
echo "userpass accessor = ${USERPASS_ACCESSOR}"
```

形如 `auth_userpass_79e2fe02`。

## 2.2 列出当前所有被锁定用户

```bash
curl -sS \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  http://127.0.0.1:8200/v1/sys/locked-users | jq
```

预期响应中可看到 `data.total` 为 `1`，且 `by_namespace[0].mount_accessors[0]` 指向上一步拿到的 userpass accessor，其 `alias_identifiers` 列表里包含 `alice`。

## 2.3 主动解锁 alice

```bash
curl -sS -X POST \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "http://127.0.0.1:8200/v1/sys/locked-users/${USERPASS_ACCESSOR}/unlock/alice"
echo "unlock 完成"
```

立即用正确密码验证 alice 已恢复登录能力：

```bash
vault login -method=userpass username=alice password=correct-horse-battery-staple
```

预期：本次登录成功，返回一份新的 token。

## 2.4 验证解锁端点的幂等性

正文已经明确："unlock is idempotent. Calls to the endpoint succeed even if the user is not currently locked."——再次对**已经解锁**的 alice 调用解锁端点，应当成功返回而非报错：

```bash
curl -sS -o /dev/null -w "二次 unlock：HTTP %{http_code}\n" -X POST \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "http://127.0.0.1:8200/v1/sys/locked-users/${USERPASS_ACCESSOR}/unlock/alice"
```

预期返回 `HTTP 204`（或 `200`，皆为成功状态码）。再次列出锁定用户，应当显示 `total = 0`：

```bash
curl -sS \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  http://127.0.0.1:8200/v1/sys/locked-users | jq '.data.total'
```

## 2.5 这一步的核心闭环

`/sys/locked-users` 的两条 API 全部在终端中被复现：列举端点按 mount accessor + alias_identifier 列出锁定用户，解锁端点是幂等的、对未锁定用户也会成功返回。下一步把整套机制从环境变量层面全局关停。
