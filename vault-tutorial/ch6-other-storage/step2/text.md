# 第二步：in-memory 后端 — 重启即丢失的演示

[6.5 节 §7](/ch6-other-storage) 已经说明：in-memory 后端**不支持高可用、不推荐用于生产**，所有数据在 Vault 进程或宿主机重启时全部丢失；`vault server -dev` 背后正是这种后端。本步用一份显式的 `storage "inmem" {}` 配置文件再现该行为，让学员对"为什么生产配置里出现 `inmem` 块就要立刻拦回"有直观印象。

## 2.1 查看预置配置文件

```bash
cat /root/vault-inmem.hcl
```

关注其中只有一行：

```hcl
storage "inmem" {}
```

按官方文档，in-memory 后端**没有任何配置参数**，能写出来的就这一行。

## 2.2 切换到 in-memory 后端启动 Vault

```bash
./start-vault.sh inmem
sleep 3
vault status || true
```

之前 filesystem 后端持有的 init 状态与数据**完全不会被这个新进程感知**——`vault status` 输出中应该看到 `Initialized   false`。

> 如果这里显示 `Initialized   true`，说明上一节的 vault 进程没被 `start-vault.sh` 真正杀掉、:8200 仍在被旧进程占用、新 inmem 进程绑定端口失败已经退出。重跑 `./start-vault.sh inmem` 一次即可（脚本现在会等到端口释放再拉新进程）；仍异常时 `pkill -9 -f 'vault server' && sleep 2 && ./start-vault.sh inmem`。

确认 `Initialized   false` 之后再初始化：

```bash
vault operator init -key-shares=1 -key-threshold=1 \
  -format=json > /root/init-inmem.json

vault operator unseal "$(jq -r '.unseal_keys_b64[0]' /root/init-inmem.json)"
export VAULT_TOKEN=$(jq -r '.root_token' /root/init-inmem.json)
```

写入一条与 step1 完全同名但内容不同的机密：

```bash
vault secrets enable -path=secret kv-v2
vault kv put secret/demo storage=inmem note="written-via-inmem-backend"
vault kv get secret/demo
```

输出中的 `storage` 字段显示 `inmem`，证明这是新写入的副本，并不是 step1 留下的数据——内存中根本没有它的位置。

## 2.3 重启进程，验证数据全部丢失

```bash
pkill -f 'vault server'
sleep 2
./start-vault.sh inmem
sleep 3
vault status || true
```

`vault status` 再次输出 `Initialized: false`：**进程一旦重启，连"已初始化"这个状态都丢了**。如果尝试用旧的 unseal key 解封，会得到 "Vault is not initialized" 之类的错误：

```bash
vault operator unseal "$(jq -r '.unseal_keys_b64[0]' /root/init-inmem.json)" || true
```

这正是 6.5 节正文里的判断依据：**生产配置里出现 `storage "inmem" {}` 必须立刻拦回**——它意味着 Vault 重启后所有 token、所有机密、所有 policy 全部消失，相当于一个"看起来在跑但本质上无状态"的服务。
