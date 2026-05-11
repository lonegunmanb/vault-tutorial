# 实验说明

本实验将在单台 Killercoda 主机上启动以下组件：

- 一个 dev 模式的 Vault（`VAULT_ADDR=http://127.0.0.1:8200`，root token `root`）；
- 一个 LocalStack 容器（监听 `127.0.0.1:4566`），用于在本地模拟 AWS IAM / STS 接口，让 Vault 的 `aws` 机密引擎能真正完成『签发 IAM User → 返回带 lease 的凭据』这一动作；
- 一个稍后由你亲自启动的 Vault Agent，监听 `127.0.0.1:8100`，开启 `cache` 块、`use_auto_auth_token = true`，并使用 AppRole 完成 Auto-auth。

实验环境会预先为你准备好：

1. AppRole `agent-cache-lab`，绑定一份只允许『读 KV 路径 `secret/data/agent/static`』与『从 `aws/creds/dev-iam` 拿动态 IAM 凭据』的策略；
2. 一份预先写好的 KV v2 静态机密 `secret/agent/static`；
3. AWS 机密引擎（指向 LocalStack）与一个名为 `dev-iam` 的 `iam_user` 类型 role；
4. 一份现成的 Agent 配置文件 `/root/agent-cache.hcl`，覆盖第 4 节讲过的最小骨架。

你将依次完成以下四个步骤：

1. 检查 LocalStack 与 AWS 引擎是否已就绪、确认 AppRole 的 role-id / secret-id 已写入磁盘；
2. 启动 Vault Agent，确认 listener `127.0.0.1:8100` 上线、Auto-auth 已经把 token 写入 sink 文件；
3. 通过 Agent listener 连续两次申请 `aws/creds/dev-iam`，对比两次返回的 `lease_id` 与 `access_key`，并到 LocalStack 一侧确认 IAM User 的真实数量；
4. 调用 `/agent/v1/cache-clear` 驱逐该 lease，再次申请观察 LocalStack 上多出新的 IAM User；最后通过 Agent 连续两次读取 KV 静态机密，结合 Vault 审计日志确认两次都被转发到了 Vault Server——印证 Agent 缓存**不**覆盖静态 KV。

> 本实验不依赖任何真实 AWS 账号，所有 IAM / STS 调用均由 LocalStack 在 `127.0.0.1:4566` 上本地处理，可放心反复执行。
