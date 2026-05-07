# 第一步：filesystem 后端 — 单节点持久化的最小可行写法

[6.5 节 §6](/ch6-other-storage) 已经说明：filesystem 后端**不支持高可用**、由 HashiCorp 官方支持，唯一参数是 `path`。本步把它跑通，并验证"重启进程后数据仍在"。

## 1.1 查看预置配置文件

```bash
cat /root/vault-file.hcl
```

关注其中的：

```hcl
storage "file" {
  path = "/opt/vault/file-data"
}
```

`/opt/vault/file-data` 已经预创建并把权限设为 700。

## 1.2 启动 Vault 并初始化

```bash
./start-vault.sh file
sleep 3
vault status || true
```

`vault status` 此时输出 `Initialized: false`、退出码非零，属于预期行为。

执行初始化（为简化实验使用 1/1 分片）：

```bash
vault operator init -key-shares=1 -key-threshold=1 \
  -format=json > /root/init-file.json

UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' /root/init-file.json)
ROOT_TOKEN=$(jq -r '.root_token' /root/init-file.json)

vault operator unseal "$UNSEAL_KEY"
export VAULT_TOKEN="$ROOT_TOKEN"
```

`vault status` 现在应输出 `Sealed: false`。

## 1.3 启用 KV 引擎并写入一条机密

```bash
vault secrets enable -path=secret kv-v2
vault kv put secret/demo storage=file note="written-via-filesystem-backend"
vault kv get secret/demo
```

## 1.4 直接观察 Vault 在文件系统上的物化形态

```bash
ls -la /opt/vault/file-data
find /opt/vault/file-data -maxdepth 3 -type f | head
```

可以看到 Vault 把数据切分成大量小文件，目录结构按内部前缀分层。**所有内容都是密文** —— 6.5 节正文已强调："Vault 数据本身在静态状态下是加密的（encrypted at rest），但仍应采取适当措施保护对底层文件系统的访问权限"。

可以挑一个文件用 `xxd` 看几个字节确认它不是明文：

```bash
SAMPLE=$(find /opt/vault/file-data -type f | head -1)
xxd "$SAMPLE" | head -5
```

输出全是不可读的密文字节。

## 1.5 重启 Vault 进程，验证数据仍在

```bash
pkill -f 'vault server'
sleep 2
./start-vault.sh file
sleep 3

vault operator unseal "$(jq -r '.unseal_keys_b64[0]' /root/init-file.json)"
export VAULT_TOKEN=$(jq -r '.root_token' /root/init-file.json)

vault kv get secret/demo
```

数据仍然能读出来——这就是"持久化后端"的最小验收。
