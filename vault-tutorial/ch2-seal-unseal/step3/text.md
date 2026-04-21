# 第三步：Rekey —— 重新生成 Unseal Key 并重切分片

`vault operator rekey` 与上一步的 rotate **完全不在同一层**。它作用在三层密钥结构的**最外层**——Unseal Key 本身。这一步我们要：

1. 把 5/3 的 Shamir 配置改成 7/4（模拟"安全团队从 5 人扩张到 7 人"的场景）
2. 验证老分片在 rekey 完成后**彻底失效**
3. 用新分片完成下一次解封

## 3.1 启动 rekey 操作

```bash
vault operator rekey -init \
  -key-shares=7 \
  -key-threshold=4 \
  -format=json > /root/workspace/rekey-init.json

cat /root/workspace/rekey-init.json | jq .
```

输出：

```json
{
  "nonce": "<rekey 会话 UUID>",
  "started": true,
  "t": 4,
  "n": 7,
  "progress": 0,
  "required": 3,
  "verification_required": false,
  ...
}
```

逐字段读懂：

| 字段 | 含义 |
| :--- | :--- |
| `nonce` | rekey 会话标识（与 unseal 的 nonce 是独立的两套机制） |
| `t: 4`, `n: 7` | **将来**新的 Shamir 参数 |
| `required: 3` | 要完成 rekey，**必须用当前阈值的分片授权**——这是关键防护 |

**为什么 rekey 必须先用当前阈值授权？** 因为 rekey 会改变"未来谁能解封 Vault"，这本质是一次治理变更。Vault 强制要求"必须先证明你当前就有解封权限"——防止一个被泄漏的低权限管理员单方面把所有未来解封权交给攻击者。

## 3.2 用当前 3 份分片完成授权

```bash
NONCE=$(jq -r '.nonce' /root/workspace/rekey-init.json)

# 第 1 份当前分片
vault operator rekey -nonce="$NONCE" \
  "$(cat /root/workspace/shares/share-1.key)"
```

```
Operation nonce: <NONCE>
Key Shares:      7
Key Threshold:   4
Rekey Progress:  1/3
```

```bash
# 第 2 份
vault operator rekey -nonce="$NONCE" \
  "$(cat /root/workspace/shares/share-2.key)"
```

```
Rekey Progress:  2/3
```

```bash
# 第 3 份——临界点，会输出全新的 7 份分片
vault operator rekey -nonce="$NONCE" -format=json \
  "$(cat /root/workspace/shares/share-3.key)" > /root/workspace/rekey-result.json

cat /root/workspace/rekey-result.json | jq .
```

输出包含**全新的 7 份分片**：

```json
{
  "nonce": "<NONCE>",
  "complete": true,
  "keys": [ "<new-1>", "<new-2>", ..., "<new-7>" ],
  "keys_base64": [ "..." ],
  ...
}
```

## 3.3 提取新分片

```bash
mkdir -p /root/workspace/new-shares
for i in 0 1 2 3 4 5 6; do
  jq -r ".keys_base64[$i]" /root/workspace/rekey-result.json \
    > /root/workspace/new-shares/share-$((i+1)).key
done
chmod 600 /root/workspace/new-shares/*.key

ls -l /root/workspace/new-shares/
```

## 3.4 验证老分片彻底失效

```bash
# 主动封印
vault operator seal

# 尝试用老分片解封（保留输出，便于观察老分片失效的现场）
vault operator unseal "$(cat /root/workspace/shares/share-1.key)"
vault operator unseal "$(cat /root/workspace/shares/share-2.key)"
vault operator unseal "$(cat /root/workspace/shares/share-3.key)"

vault status | grep -E "Sealed|Unseal Progress"
```

仔细观察三次输出。前两次老分片**会被服务端接受**——因为 Vault 没法在收到分片时立刻判断它的有效性（Shamir 分片单独看只是一串字节，必须凑齐 threshold 才能尝试重组）。所以你会看到：

```
Unseal Progress    1/3
...
Unseal Progress    2/3
```

**真正的失败发生在第 3 份提交时**——服务端凑齐 3 份后调用 Shamir 重组算法，得到一个"Unseal Key 候选"，再用它去解密磁盘上保存的 Root Key 密文。这一步会因为 HMAC 校验失败而报错：

```
Error unsealing: Error making API request.
URL: PUT http://127.0.0.1:8200/v1/sys/unseal
Code: 400. Errors:
* failed to decrypt encrypted stored keys: cipher: message authentication failed
```

注意细节：**老分片不是"格式错误被拒"**，而是"格式正确但解密结果不对"。这正是 Shamir + HMAC 组合的设计——服务端不会泄漏"哪份分片是错的"这种信息（任何 K 份的组合都能算出**某个**值，只是不对），攻击者无法借此做分片穷举。

服务端看到解密失败后会**自动清空 unseal 进度**，不需要你手动 reset。看一下：

```bash
vault status | grep -E "Sealed|Unseal Progress"
```

```
Sealed             true
Unseal Progress    0/3
```

## 3.5 用新分片完成解封

`Threshold` 已经从 3 变成 4，需要 4 份才能解封：

```bash
vault operator unseal "$(cat /root/workspace/new-shares/share-1.key)" > /dev/null
vault operator unseal "$(cat /root/workspace/new-shares/share-2.key)" > /dev/null
vault operator unseal "$(cat /root/workspace/new-shares/share-3.key)" > /dev/null
vault operator unseal "$(cat /root/workspace/new-shares/share-4.key)" > /dev/null

vault status | grep -E "Sealed|Total Shares|Threshold"
```

```
Sealed             false
Total Shares       7              ← 从 5 变 7
Threshold          4              ← 从 3 变 4
```

## 3.6 验证所有数据完整保留

```bash
vault kv get secret/seal-demo
vault kv get secret/before-rotate
vault kv get secret/after-rotate
```

三条机密**全部完好**——rekey 只换了最外层的 Unseal Key，对 Root Key 和 DEK 完全没有影响。

## 3.7 关键差异对照（Rotate vs Rekey）

| 维度 | `vault operator rotate` | `vault operator rekey` |
| :--- | :--- | :--- |
| **作用层级** | DEK | Unseal Key + 其分片 |
| **是否需分片授权** | ❌ 否 | ✅ 是（当前 threshold） |
| **老分片是否仍可用** | 不涉及 | ❌ 立即失效 |
| **历史数据是否需要重新加密** | 不需要（keyring 兼容） | 不需要（DEK / Root Key 不变） |
| **典型触发条件** | 定期合规、单一密钥使用过久 | 持有分片的人离职、团队结构变化、分片可能泄漏 |
| **命令背后的 API** | `POST /sys/rotate` | `POST /sys/rekey/init` + `POST /sys/rekey/update` |

## 3.8 收尾：吊销初始 Root Token

[Tokens 文档](https://developer.hashicorp.com/vault/docs/concepts/tokens#root-tokens)明确建议："初始 Root Token 应在初始化任务完成后立即吊销。"

我们已经完成了所有需要 root 权限的工作（init / rotate / rekey），现在是时候把它销毁：

```bash
# 验证当前 Token 确实是 root
vault token lookup | grep -E "policies|ttl"
```

```
policies            [root]
ttl                 0s
```

吊销：

```bash
vault token revoke "$(cat /root/workspace/root.token)"
```

验证已失效：

```bash
vault token lookup 2>&1 | head -5
```

```
Error looking up token: ... permission denied
```

✅ 初始 Root Token 已不可用。后续如果再需要 root 权限，正确做法是用 `vault operator generate-root` 临时重建——而该命令本身需要分片授权，确保"重建管理员权限"也是一次多人协作事件。

完成后点击 **Continue** 进入总结。
