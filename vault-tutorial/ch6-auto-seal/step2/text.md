# 第二步：架设 KMS 流量代理，再在 vault.hcl 中追加 seal "awskms" 块

先看一下预置的基线配置文件：

```bash
cat /root/vault.hcl
```

请重点关注：当前文件**只有** `storage` / `listener` / 几个全局开关，**没有** `seal` 块。按 [6.3 节 §1](/ch6-auto-seal) 的总述，缺省状态下 Vault 会在初始化时使用 Shamir 算法保护根密钥；本步要把它切换为 AWS KMS auto-unseal。

## 2.1 架设一个可以被随时杀掉的 KMS 流量代理

在让 Vault 直连 LocalStack `:4566` 之前，先在两者之间架设一个轻量级 TCP 转发代理 `socat`，监听 `:14566`，把进来的连接原样转给 `127.0.0.1:4566`。**Vault 只看到代理，不直接看到 LocalStack**。

这样做的目的只有一个：让我们在 [Step 5](#) 通过**杀掉代理进程**来精准模拟"KMS 网络不可达"的故障，而不必真的去 `docker stop` LocalStack 容器——后者会同时清掉 LocalStack 内存里的 KMS 密钥和别名，把恢复路径搞得复杂得多。代理被杀时，LocalStack 自身完好无损，Vault 端会立刻看到 `connection refused`，与"真实 AWS KMS 在 VPC 端点出故障"这种事故的网络观感一致。

```bash
mkdir -p /var/run
nohup socat -d \
    TCP-LISTEN:14566,bind=127.0.0.1,fork,reuseaddr \
    TCP:127.0.0.1:4566 \
    > /var/log/kms-proxy.log 2>&1 &
echo $! > /var/run/kms-proxy.pid

sleep 1
echo "kms-proxy pid=$(cat /var/run/kms-proxy.pid)"
ss -lntp | grep ':14566' || true
```

应当看到 `:14566` 处于 LISTEN 状态。冒烟一下，确认代理能把 KMS 调用透传过去：

```bash
curl -s http://127.0.0.1:14566/_localstack/health | jq '.services.kms'

awslocal --endpoint-url=http://127.0.0.1:14566 kms list-aliases \
    | jq '.Aliases[] | select(.AliasName=="alias/vault-classroom-unseal")'
```

第一行应当回显 `"available"` 或 `"running"`；第二行应当回显 [Step 1.4](#) 创建的别名条目——证明 KMS 流量经由代理打到了 LocalStack。

> **`socat` 选项说明**：`fork` 让代理对每个 TCP 入站连接都派生一个子进程独立处理，避免单连接生命周期阻塞下一个连接；`reuseaddr` 允许代理被 `kill` 后立刻重启而不必等 `TIME_WAIT` 自然消失。把代理 PID 写到 `/var/run/kms-proxy.pid` 便于 [Step 5](#) 精准 `kill`。

## 2.2 追加 seal "awskms" 块

把 `seal` 块写到 `vault.hcl` 文件末尾。注意几个关键字段：

- `region` 显式写出 `us-east-1`，与实验环境的 `AWS_DEFAULT_REGION` 一致；
- `kms_key_id` 使用 [Step 1.4](#) 创建的 alias 而非具体 key ID；
- `endpoint` 指向**代理端口** `:14566`，**不是** LocalStack 的 `:4566`。这是教学环境特有的设置，正式 AWS 部署时**不要**给出此字段；
- `access_key` / `secret_key` 使用 [6.3 节 §3](/ch6-auto-seal) 介绍的**间接值引用**语法 `env://...`，让最终值在加载配置时从环境变量取得，而不是把字面量明文写进配置文件。

```bash
cat >> /root/vault.hcl <<'EOF'

seal "awskms" {
  region     = "us-east-1"
  kms_key_id = "alias/vault-classroom-unseal"
  endpoint   = "http://127.0.0.1:14566"
  access_key = "env://AWS_ACCESS_KEY_ID"
  secret_key = "env://AWS_SECRET_ACCESS_KEY"
}
EOF
```

回看完整文件：

```bash
cat /root/vault.hcl
```

应能看到末尾出现一个完整的 `seal "awskms"` 块，且 `endpoint` 是 `:14566`。

## 2.3 启动 Vault

> 与 [6.2 节实验](/ch6-listener-tls) 不同，本实验不再覆盖 listener TLS——`vault.hcl` 中 `tls_disable = true` 已显式声明明文 HTTP；这是为了把注意力集中在 seal 行为上。

启动 Vault 之前，**必须先确保当前 shell 已加载本实验所需的环境变量**（`VAULT_ADDR`、`AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY`、`AWS_DEFAULT_REGION`）。这些变量已被实验环境写入 `/etc/profile.d/`，但 Killercoda 的 editor terminal 在某些情况下会在这些文件被写入之前就已启动，导致当前 shell 看不到它们。显式 source 一次以保证可用：

```bash
source /etc/profile.d/vault.sh
source /etc/profile.d/aws.sh
echo "VAULT_ADDR=$VAULT_ADDR"
echo "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID  AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION"
```

四个值都应当回显出非空内容。如果 `AWS_ACCESS_KEY_ID` 仍为空，请检查 `/etc/profile.d/aws.sh` 是否存在；不存在时回到实验初始化阶段重新触发准备脚本。

> **为什么这一步关键**：`vault.hcl` 中 `seal "awskms"` 块里的 `access_key = "env://AWS_ACCESS_KEY_ID"` 是 [6.3 节 §3](/ch6-auto-seal) 介绍的间接值引用——Vault 进程在启动时会去**自身进程的环境**里查找这个变量；shell 中没有该变量，`nohup` 启动的子进程同样没有，Vault 解析 seal 配置时就会立即报 `environment variable AWS_ACCESS_KEY_ID unset` 并退出。

确认环境变量就绪后，再启动 Vault：

```bash
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
sleep 2
cat /tmp/vault.pid
```

确认监听端口已处于 LISTEN 状态：

```bash
ss -lntp | grep ':8200' || true
```

## 2.4 观察启动日志中的 seal 类型识别

```bash
grep -iE 'seal|kms' /var/log/vault.log | head -20
```

日志中应出现与 `awskms` 相关的初始化条目（例如 `Seal Type: awskms` 一类的字样）；若日志里看到 KMS 相关的连接错误，请先回到 [Step 1.5](#) 与本步 2.1 确认代理→LocalStack 这条链路仍然可用。

## 2.5 用 vault status 观察当前状态

```bash
vault status || true
```

预期输出（节选）：

```
Key                      Value
---                      -----
Seal Type                awskms
Recovery Seal Type       shamir
Initialized              false
Sealed                   true
```

> 几个关键点：
>
> - `Seal Type` 已经是 `awskms`——配置文件被识别成功；
> - `Recovery Seal Type` 是 `shamir`——这正对应 [6.3 节 §13](/ch6-auto-seal) 所述 "auto-unseal 模式下 init 仍会生成一组 Shamir 形式的 recovery keys"；
> - `Initialized: false` —— 一个全新的、还没初始化的集群；
> - `Sealed: true` —— 由于尚未初始化，自然也尚未解封；
> - 命令结尾 `vault status` 在 `Initialized=false` 或 `Sealed=true` 时会以**非零退出码**返回，这是正常行为，所以加 `|| true` 防止脚本判定失败。

## 2.6 这一步的核心闭环

LocalStack ↔ socat 代理 ↔ Vault 三段链路已经搭好，Vault 已识别配置文件中的 `seal "awskms"` 块并以 `awskms` 模式启动；尚未初始化、尚未解封；下一步执行 `init` 触发 Vault 调 KMS 生成根密钥，并观察输出与 Shamir 模式的差异。
