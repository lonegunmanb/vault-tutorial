# 第一步：启动 MiniStack 并把 AWS 引擎指向本地端点

3.3 章节的关键认知：**Vault 与 AWS 之间是普通 HTTP API 调用**——
任何能讲 AWS API 的 endpoint 都可以替代真 AWS。MiniStack 就是这样一个
本地 endpoint，跑在 `127.0.0.1:4566`。

## 1.1 启动 MiniStack 容器

```bash
docker run -d --name ministack -p 4566:4566 ministackorg/ministack
```

镜像在准备阶段已经预拉过，启动只要 1-2 秒。等容器健康：

```bash
sleep 3
curl -s http://127.0.0.1:4566/_localstack/health | jq '.services | {iam, sts, s3}'
```

应看到 `iam` / `sts` / `s3` 三个服务都是 `"available"`——这是
MiniStack 兼容 LocalStack 留下的健康检查端点。

## 1.2 用 AWS CLI 直连 MiniStack 确认它真在工作

`AWS_ACCESS_KEY_ID=test` / `AWS_SECRET_ACCESS_KEY=test` 已经在
`/etc/profile.d/aws.sh` 里持久化了，直接：

```bash
aws --endpoint-url=http://127.0.0.1:4566 sts get-caller-identity
```

返回的是 MiniStack 给 root 凭据虚构的身份：
`arn:aws:iam::000000000000:root`。**这一对 `test` / `test` 就是 §3.3
里说的"管理员的 root key"——一会儿要写进 Vault 的 `aws/config/root`**。

## 1.3 启用 AWS 机密引擎

```bash
vault secrets enable aws
vault secrets list | grep -E "Path|^aws/"
```

`Type` 列写的是 `aws`，挂载路径默认就是 `aws/`。

## 1.4 配置 root key——把 Vault 指向 MiniStack

关键参数是两个 endpoint，让 Vault 的所有 IAM/STS 调用都打到本地 4566：

```bash
vault write aws/config/root \
  access_key=test \
  secret_key=test \
  region=us-east-1 \
  iam_endpoint=http://127.0.0.1:4566 \
  sts_endpoint=http://127.0.0.1:4566
```

> **生产场景**：连真 AWS 时**不要**写 `iam_endpoint` / `sts_endpoint`，
> Vault 会自动用 AWS 公网端点。这两个字段就是为"自托管 AWS 兼容服务"
> 准备的，比如本实验的 MiniStack、企业内网代理、或专有云。

回读一下确认：

```bash
vault read aws/config/root
```

注意输出里 `secret_key` 不会显示——Vault 对所有 `config/root` 类敏感
字段都是"只能写、读不出"。

> **"读不出我怎么用？"**——这正是设计意图。`secret_key` **从来不
> 应该被你或任何应用读出来**：它的唯一用途是让 Vault**在内部**用它
> 去调 AWS API 铸临时凭据（接下来 step2 / step3 会反复用到）。你和你
> 的应用**只需要**用 `vault read aws/creds/<role>` / `aws/sts/<role>`
> 拿那份**临时**凭据，而不是 root key 本身。这样 root key 只活在
> Vault 进程内存里，一旦泄露就只能从 Vault 渗出，而不会从应用日志、
> CI 历史、镜像层这些地方泄露——这就是"只写不读"对运维的价值。
>
> 如果将来真要换 root key（比如轮转/紧急吊销），就用
> `vault write aws/config/root ...` 直接覆盖，或用专门的
> `vault write -force aws/config/rotate-root` 让 Vault 自己去 AWS
> 创建一对新 AK/SK 替换。

`iam_endpoint` 和 `sts_endpoint` 都应该是 `http://127.0.0.1:4566`。

## 1.5 设置默认 lease：让本实验的凭据"短寿命"

```bash
vault write aws/config/lease lease=10m lease_max=1h
```

把 `iam_user` 类型的默认 lease 从 768h 缩到 10 分钟、最长 1 小时——
本实验里我们一会儿手动 revoke，但调短能让你万一忘了 revoke 时也不会
留太久脏数据。

---

> 接下来一步开始"亲手见证"：每次 `vault read aws/creds/<role>` 都真
> 的会让 MiniStack 上多一个 IAM User。
