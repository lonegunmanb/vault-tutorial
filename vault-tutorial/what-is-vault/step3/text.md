# 第三步：初始化 + Shamir 解封

现在亲手完成 Vault 集群的"开机仪式"——这是每个 Vault 运维人员一辈子至多操作几次但**必须百分之百正确**的关键流程。

## 3.1 初始化集群

`vault operator init` 做了什么？

1. 在底层生成一个 **Encryption Key**（用来加密所有用户数据）
2. 生成一个 **Root Key** 包裹 Encryption Key
3. 用 Shamir's Secret Sharing 算法把 **Unseal Key** 切分成 N 份（默认 5 份）
4. 用其中任意 K 份（默认 3 份）就能重组出 Unseal Key
5. 颁发一个初始 **Root Token**

```bash
# 把输出保存到文件，方便后续步骤读取
vault operator init -format=json > /root/vault-init.json
cat /root/vault-init.json | jq
```

> **如果你看到 `Error: Vault is already initialized`**：说明之前已经初始化过——Vault 集群在其生命周期内**只能初始化一次**。需要从零再来一遍时，先彻底清理状态再回到第二步重新启动 Vault：
>
> ```bash
> pkill vault 2>/dev/null; sleep 2
> rm -rf /opt/vault/data/* /root/vault-init.json
> ```

> **为什么要把密钥切成多份？——Shamir 算法的安全意义**
>
> 如果只有一份"主密钥"，那么这份密钥就是单点：持有者一旦被收买、被胁迫或离职带走，整个 Vault 集群的所有秘密都会瞬间泄露；反过来，万一这份密钥丢失（人去世、硬盘损坏、保险柜钥匙丢失），加密数据就再也解不开了——这是任何严肃的密钥托管系统都无法接受的两个极端。
>
> Shamir's Secret Sharing 用一条数学性质完美地解决了这个困境：把一个秘密 S 拆成 N 份分片（Share），任意 K 份（K ≤ N）就能还原出 S，而**少于 K 份**则在数学上**得不到 S 的任何信息**（不是"难以破解"，是信息论意义上的零信息）。在 Vault 里默认是 N=5、K=3：
>
> - **抗腐败**：任何 1~2 个 Key Holder 联手也解不开 Vault——必须串通至少 3 人，作恶门槛极高。
> - **抗丢失**：可以丢掉/损毁最多 2 份分片而不影响解封，避免单点故障。
> - **可问责**：每次解封必须 ≥3 名 Key Holder 到场操作并留下审计日志，谁在场、何时解封一目了然。
>
> 这就是为什么生产部署**绝不能**把 5 份 Unseal Key 写到同一台机器的同一个文件里——那等于把 Shamir 退化成了"一份密钥"，前面所有数学努力归零。正确做法是用 5 名 Key Holder 各自的 PGP 公钥分别加密分发（`vault operator init -pgp-keys=alice.asc,bob.asc,...`），任意 3 人到场解密自己那份后逐个 `vault operator unseal` 提交，Vault 在内存中重组出 Root Key 完成解封。

## 3.2 提取解封密钥与 Root Token

```bash
export UNSEAL_KEY_1=$(jq -r '.unseal_keys_b64[0]' /root/vault-init.json)
export UNSEAL_KEY_2=$(jq -r '.unseal_keys_b64[1]' /root/vault-init.json)
export UNSEAL_KEY_3=$(jq -r '.unseal_keys_b64[2]' /root/vault-init.json)
export ROOT_TOKEN=$(jq -r '.root_token' /root/vault-init.json)

echo "Unseal Key 1: ${UNSEAL_KEY_1:0:10}..."
echo "Root Token  : ${ROOT_TOKEN}"
```

## 3.3 执行三轮解封

每提交一份 Unseal Key 就提交一个分片；当达到阈值（3 份）时，Vault 在内存中重组出 Root Key 并解密 keyring，进入 Unsealed 状态。

```bash
vault operator unseal "$UNSEAL_KEY_1"
vault operator unseal "$UNSEAL_KEY_2"
vault operator unseal "$UNSEAL_KEY_3"
```

注意观察每一次的输出：

- 第 1 次：`Sealed: true, Unseal Progress: 1/3`
- 第 2 次：`Sealed: true, Unseal Progress: 2/3`
- 第 3 次：`Sealed: false, Unseal Progress: 0/3` ✅

每次解封是 **无状态** 的——你可以在不同终端、不同时间分别提交分片，Vault 在服务端汇总。这正是支持"多人到场解封"的物理基础。

## 3.4 用 Root Token 登录

```bash
vault login "$ROOT_TOKEN"
```

成功后，再次查看状态：

```bash
vault status
```

现在应该看到 `Sealed: false`、`HA Enabled: true`（Raft 内建 HA）、`Cluster ID: ...` 等信息。

## 3.5 写入第一个测试数据

与上一章的 dev 模式不同，**生产模式下 `secret/` 路径默认没有挂载任何 Secrets Engine**——这正体现了"零信任"的设计：所有功能都必须显式启用。先挂载一个 kv-v2 引擎：

```bash
vault secrets enable -path=secret kv-v2
```

然后写入并读取一条测试数据：

```bash
vault kv put secret/hello world="from raft storage"
vault kv get secret/hello
```

数据现在已经被 **Encryption Key 加密** 后写入 `/opt/vault/data/` 这个 Raft 存储目录。下一步我们就去亲眼看看那里到底存了什么。

完成后点击 **Continue** 进入最后一步。
