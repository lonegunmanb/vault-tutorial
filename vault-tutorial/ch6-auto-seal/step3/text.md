# 第三步：初始化 Vault 并观察 recovery keys 的产生

[6.3 节 §13](/ch6-auto-seal) 的核心结论：在 auto-unseal 模式下执行 `vault operator init`，返回的**不是** unseal keys，而是一组 **recovery keys**——日常解封由 KMS 自动完成，这组 recovery keys 仅用于 `generate-root` / `rekey` 这类高度特权操作。本步亲眼验证这一行为差异。

## 3.1 执行 init

```bash
vault operator init \
    -recovery-shares=5 \
    -recovery-threshold=3 \
    -format=json > /root/init.json

jq '. | {recovery_keys_b64, root_token}' /root/init.json
```

注意命令行参数与 Shamir 模式下的差异：

| Shamir 模式 | Auto-Unseal 模式 |
| :--- | :--- |
| `-key-shares=N` | `-recovery-shares=N` |
| `-key-threshold=K` | `-recovery-threshold=K` |

> 字段命名差异本身就是一个强信号——CLI 提示符在告诉操作员："你现在分发出去的不是日常解封钥匙，而是仅用于灾难恢复的恢复钥匙。"

如果不慎按 Shamir 模式写成 `-key-shares=N`，CLI 会以 `Unable to parse flags` 形式拒绝。

## 3.2 验证 init 的返回数据形态

```bash
jq 'keys' /root/init.json
```

应看到顶层键集合中**包含** `recovery_keys`、`recovery_keys_b64`、`root_token`，**不包含** `unseal_keys` / `unseal_keys_b64`（或者它们的值为空数组）：

```bash
jq '.unseal_keys_b64, .recovery_keys_b64 | length' /root/init.json
```

第一行（`unseal_keys_b64` 长度）应当是 `0`，第二行（`recovery_keys_b64` 长度）应当是 `5`——印证 [6.3 节 §13](/ch6-auto-seal) 的论断。

## 3.3 持久化 root token，用 vault status 复查

```bash
export VAULT_TOKEN=$(jq -r '.root_token' /root/init.json)
echo "export VAULT_TOKEN=${VAULT_TOKEN}" >> /etc/profile.d/vault.sh

vault status
```

此时输出应当显示：

```
Key                      Value
---                      -----
Seal Type                awskms
Recovery Seal Type       shamir
Initialized              true
Sealed                   false
```

最关键的是 **`Sealed: false`**——init 完成后 Vault 已经**自动**完成了一次解封，无需操作员手动输入任何分片。这就是 auto-unseal 在工作：Vault 自己调用了 KMS 的 Decrypt API，把根密钥从 KMS 那里取了回来。

## 3.4 旁证：从 LocalStack 一侧观察 KMS 调用

LocalStack 默认会在容器日志中打印每一次受理的 API 调用。看一下 init 这一刻 KMS 上发生了什么：

```bash
docker logs localstack 2>&1 | grep -iE 'kms|encrypt|decrypt' | tail -10
```

应能看到若干条 `Encrypt` / `Decrypt` / `DescribeKey` 一类的调用记录——这就是 [6.3 节 §10](/ch6-auto-seal) 所列 Vault 在 KMS 上必需的三个最小权限动作的真实落地。

## 3.5 验证 root token 真的可用

```bash
vault token lookup | head -10
```

应看到 `policies` 是 `[root]`、`type` 是 `service`——一切正常。

## 3.6 这一步的核心闭环

`init` 在 auto-unseal 模式下返回的是 recovery keys 而非 unseal keys；init 完成的同一刻 Vault 已经自动解封。下一步通过强行 kill Vault 进程并再次启动，验证 auto-unseal 在**重启**场景下同样真正工作。
