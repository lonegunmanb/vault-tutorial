# 第一步：启动 Dev 模式并解读启动警告

在本步骤中，你将亲手启动 Vault Dev 服务器，并仔细解读它输出的每一行安全警告——这些警告大多数人都会自动忽略，但每一条都对应一个真实风险。

## 1.1 启动 Dev 服务器

在终端中运行以下命令，将 Dev 服务器的日志保存到文件，同时在后台运行：

```bash
vault server -dev -dev-root-token-id=root \
  > /tmp/vault-dev.log 2>&1 &
DEV_PID=$!
echo "Vault Dev PID: $DEV_PID"
sleep 2
```

## 1.2 检查启动日志——逐条解读安全警告

启动日志包含七条非常重要的声明，让我们仔细读一遍：

```bash
cat /tmp/vault-dev.log
```

你会看到类似这样的输出：

```
WARNING! dev mode is enabled! In this mode, Vault runs entirely in-memory
and starts unsealed with a single unseal key. The root token is already
authenticated to the CLI, so you can immediately begin using Vault.

You may need to set the following environment variable:

    $ export VAULT_ADDR='http://127.0.0.1:8200'

The unseal key and root token are displayed below in case you want to
seal/unseal the Vault or re-authenticate.

Unseal Key: <某个 Base64 字符串>
Root Token: root

Development mode should NOT be used in production installations!
```

> **逐行解读**：
> - `runs entirely in-memory`：所有数据在内存中，**重启 = 数据消失**
> - `starts unsealed`：**Shamir 机制被完全绕过**，无需多人参与解封
> - `with a single unseal key`：解封密钥只有 1 份，而非生产的 5 份（需 3 份重组）
> - `root token is already authenticated`：**Root Token 已经明文打印在终端**
> - `http://127.0.0.1:8200`：**HTTP，无 TLS**，网络流量明文传输
> - `Development mode should NOT be used in production`：官方明文禁令

## 1.3 配置环境变量并验证 Vault 状态

```bash
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'
echo "export VAULT_ADDR='http://127.0.0.1:8200'" >> ~/.bashrc
echo "export VAULT_TOKEN='root'" >> ~/.bashrc

vault status
```

重点关注 `vault status` 的输出：

```
Key             Value
---             -----
Seal Type       shamir
Initialized     true
Sealed          false          ← 自动解封，无需任何人工操作
Total Shares    1              ← 只有 1 个分片！
Threshold       1              ← 只需 1 个分片就能解封
Version         1.19.x
Storage Type    inmem          ← 内存存储
Cluster Name    vault-cluster-...
Cluster ID      ...
HA Enabled      false
```

| 字段 | 生产值 | Dev 值 | 差距说明 |
| :--- | :--- | :--- | :--- |
| `Sealed` | `true`（重启后需解封） | `false` | Shamir 机制被完全bypass |
| `Total Shares` | 5（或更多） | **1** | 无多人控制保障 |
| `Threshold` | 3 | **1** | 任意拿到该分片即可解封 |
| `Storage Type` | `raft` | **`inmem`** | 数据随进程消失 |

## 1.4 查看预挂载的引擎

```bash
vault secrets list
vault auth list
```

你会看到如下输出：

```
Path          Type         Accessor              Description
----          ----         --------              -----------
cubbyhole/    cubbyhole    cubbyhole_xxxxxxxx    per-token private secret storage
identity/     identity     identity_xxxxxxxx     identity store
secret/       kv           kv_xxxxxxxx           key/value secret storage
sys/          system       system_xxxxxxxx       system endpoints used for control, policy and debugging

Path      Type     Accessor               Description                Version
----      ----     --------               -----------                -------
token/    token    auth_token_xxxxxxxx    token based credentials    n/a
```

Dev 模式自动挂载了以下内容：

- **`secret/`（KV）**：可直接用于读写机密，无需手动 `vault secrets enable`
- **`cubbyhole/`**：每个 Token 的私有存储空间，不可被其他 Token 访问
- **`identity/`**：身份实体存储，Dev 模式下同样可用
- **Token 认证**：唯一预挂载的认证方法，无 AppRole、GitHub、LDAP 等

`vault secrets list` 的 `Type` 列对 KV v1 和 v2 都显示 `kv`，无法从这里区分版本。用 `-detailed` 可以看到实际版本：

```bash
vault secrets list -detailed | grep secret
```

你会在 `Options` 列看到 `map[version:2]`，确认 Dev 模式挂载的是 KV v2。如果需要 v1，可以在启动时加 `-dev-kv-v1` 标志。

在生产环境中，需要显式执行 `vault secrets enable -version=2 -path=secret kv` 才能得到同等效果，挂载路径也由你自己决定。

完成后点击 **Continue** 进入第二步。
