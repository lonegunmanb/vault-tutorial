# 第二步：在 vault.hcl 中追加 seal "awskms" 块

先看一下预置的基线配置文件：

```bash
cat /root/vault.hcl
```

请重点关注：当前文件**只有** `storage` / `listener` / 几个全局开关，**没有** `seal` 块。按 [6.3 节 §1](/ch6-auto-seal) 的总述，缺省状态下 Vault 会在初始化时使用 Shamir 算法保护根密钥；本步要把它切换为 AWS KMS auto-unseal。

## 2.1 追加 seal "awskms" 块

把 `seal` 块写到文件末尾。注意几个关键字段：

- `region` 显式写出 `us-east-1`，与实验环境的 `AWS_DEFAULT_REGION` 一致；
- `kms_key_id` 使用 [Step 1.4](#) 创建的 alias 而非具体 key ID；
- `endpoint` 把 KMS API 调用全部重定向到本地 LocalStack `:4566`——这是教学环境特有的设置，正式 AWS 部署时**不要**给出此字段；
- `access_key` / `secret_key` 使用 [6.3 节 §3](/ch6-auto-seal) 介绍的**间接值引用**语法 `env://...`，让最终值在加载配置时从环境变量取得，而不是把字面量明文写进配置文件。

```bash
cat >> /root/vault.hcl <<'EOF'

seal "awskms" {
  region     = "us-east-1"
  kms_key_id = "alias/vault-classroom-unseal"
  endpoint   = "http://127.0.0.1:4566"
  access_key = "env://AWS_ACCESS_KEY_ID"
  secret_key = "env://AWS_SECRET_ACCESS_KEY"
}
EOF
```

回看完整文件：

```bash
cat /root/vault.hcl
```

应能看到末尾出现一个完整的 `seal "awskms"` 块。

## 2.2 启动 Vault

> 与 [6.2 节实验](/ch6-listener-tls) 不同，本实验不再覆盖 listener TLS——`vault.hcl` 中 `tls_disable = true` 已显式声明明文 HTTP；这是为了把注意力集中在 seal 行为上。

```bash
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
sleep 2
cat /tmp/vault.pid
```

确认监听端口已处于 LISTEN 状态：

```bash
ss -lntp | grep ':8200' || true
```

## 2.3 观察启动日志中的 seal 类型识别

```bash
grep -iE 'seal|kms' /var/log/vault.log | head -20
```

日志中应出现与 `awskms` 相关的初始化条目（例如 `Seal Type: awskms` 一类的字样）；若日志里看到 KMS 相关的连接错误，请先回到 [Step 1.5](#) 确认 LocalStack 上的 alias Encrypt / Decrypt 仍然可用。

## 2.4 用 vault status 观察当前状态

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

## 2.5 这一步的核心闭环

Vault 已经识别出配置文件中的 `seal "awskms"` 块并以 `awskms` 模式启动；尚未初始化、尚未解封；下一步执行 `init` 触发 Vault 调 KMS 生成根密钥，并观察输出与 Shamir 模式的差异。
