# 第一步：确认实验环境的三件就绪条件

本节配套教程把 Vault Agent 缓存的边界讲得很窄——它只缓存『新建 Token』与『新建带租约的机密』。要让第 3 步真的看到缓存命中，必须在第 1 步先确认三件事都已经就绪：

1. LocalStack 上的 IAM / STS 接口可用；
2. Vault 的 `aws` 机密引擎已经指向 LocalStack，并且 `dev-iam` role 能签出真实带 lease 的凭据；
3. AppRole 的 `role-id` / `secret-id` 已经写到磁盘上，等会儿喂给 Agent 的 Auto-auth。

## 1.1 确认 LocalStack 就绪

```bash
curl -s http://127.0.0.1:4566/_localstack/health | jq '.services | {iam, sts}'
```

应当看到 `iam` 与 `sts` 都是 `"available"`。这两个服务正是 Vault `aws` 机密引擎在执行 `aws/creds/dev-iam` 时所需要调用的——`iam:CreateUser` / `iam:CreateAccessKey` 用来真创建 IAM User，`sts:GetCallerIdentity` 在内部用来确认身份。

## 1.2 确认 AWS 机密引擎已配置

```bash
vault read aws/config/root
vault read aws/roles/dev-iam
```

`aws/config/root` 中 `iam_endpoint` 与 `sts_endpoint` 都应当是 `http://127.0.0.1:4566`，`region` 为 `us-east-1`；`secret_key` 字段不会回显（Vault 把它当作敏感字段处理）。`aws/roles/dev-iam` 的 `credential_type` 应当是 `iam_user`，`policy_document` 内是一段允许 `s3:ListAllMyBuckets` 的最小 IAM 策略。

> 这一对 `dev-iam` role 是本实验观察『缓存命中』的关键——每一次 `vault read aws/creds/dev-iam` 都会让 LocalStack 上多出一个 IAM User，并返回一份带 `lease_id` 的响应；只要我们把这次调用通过 Agent 走，Agent 就会按教程第 2 节的第 2 条规则把它缓存下来。

## 1.3 确认 AppRole 凭据已落盘

```bash
ls -l /root/agent-role-id /root/agent-secret-id
cat /root/agent-role-id
```

两个文件都应当存在、权限 600；`agent-role-id` 内是一段 UUID 形式的字符串。Agent 启动后会读取这两个文件、用 AppRole 自动登录 Vault，并把签出的 Vault Token 同时（a）写入磁盘 sink 文件 `/root/agent-cache/auto-auth-token`，（b）作为 `use_auto_auth_token` 的来源，在客户端没带 `X-Vault-Token` 时替它带上。

## 1.4 顺手看一眼 Agent 配置文件

```bash
cat /root/agent-cache.hcl
```

请重点核对四个字段是否符合教程第 4 节的最小骨架：

- `cache { use_auto_auth_token = true }` —— 启用缓存且替无 token 的客户端贴上 Auto-auth token；
- `listener "tcp" { address = "127.0.0.1:8100" ... }` —— 暴露给客户端走的入口；
- `auto_auth.method "approle"` —— 自动登录方式；
- `auto_auth.sink "file"` —— Auto-auth 拿到的 token 同时落到这个文件，方便人类肉眼检查。

## 1.5 这一步的核心闭环

到这里：LocalStack 上 IAM/STS 服务可用 → Vault 的 `aws` 引擎已经能向 LocalStack 真创建 IAM User → AppRole 凭据落盘 → Agent 配置文件已经写好。下一步启动 Agent。
