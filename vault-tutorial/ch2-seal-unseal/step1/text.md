# 第一步：Shamir 阈值的深入观察

`what-is-vault` 实验里你已经做过一次"提交 3 份分片 → 解封成功"。这一步我们不再走完整流程，而是把放大镜对准三个**容易被忽略但极其重要**的细节：

1. `Unseal Nonce` 字段在协议中扮演什么角色
2. **少于 K 份**分片提交时，Vault 处于什么状态？业务请求会怎样？
3. **任意 K 份**分片是否真的等价？

## 1.1 先确认起点状态

```bash
vault status | grep -E "Sealed|Total Shares|Threshold"
```

应当看到：

```
Sealed             false
Total Shares       5
Threshold          3
```

## 1.2 主动封印，准备做"半解封"实验

```bash
vault operator seal
vault status | grep -E "Sealed|Unseal Progress|Unseal Nonce"
```

输出：

```
Sealed             true
Unseal Progress    0/3
Unseal Nonce       n/a
```

注意 `Unseal Nonce: n/a`——还没有任何解封会话开始。

## 1.3 提交第 1 份分片，观察 Nonce 出现

```bash
vault operator unseal "$(cat shares/share-1.key)"
```

输出尾部：

```
Sealed             true
Total Shares       5
Threshold          3
Unseal Progress    1/3
Unseal Nonce       <一串 UUID>      ← 出现了！
```

**Nonce 是什么？** 它是这一次解封会话的唯一标识符。Vault 用它来防止下面这种攻击：

> 持有人 A、B、C 正在协作解封。在 A 和 B 提交完后，攻击者 X 偷偷开始另一次"解封"，并提交了一份伪造分片。如果没有 Nonce，X 提交的分片可能会被错误地累加到 A、B 的进度里。

```bash
NONCE=$(vault status -format=json | jq -r '.nonce')
echo "当前 Nonce: $NONCE"
```

## 1.4 提交第 2 份，验证 Nonce 不变

```bash
vault operator unseal "$(cat shares/share-2.key)"

echo "提交后 Nonce: $(vault status -format=json | jq -r '.nonce')"
```

Nonce 与上一步**完全一样**——这是"同一次解封会话"的延续。

## 1.5 关键实验：故意只提交 2 份，观察"卡住"状态

我们不提交第 3 份，看看 Vault 是什么样：

```bash
vault status | grep -E "Sealed|Unseal Progress"
```

```
Sealed             true               ← 仍然封印
Unseal Progress    2/3                ← 卡在 2/3
```

业务请求会被直接拒绝：

```bash
vault kv get secret/seal-demo || true
```

```
Error reading secret/data/seal-demo: Error making API request.
Code: 503. Errors:
* Vault is sealed
```

**关键认知**：Vault 不会"半解封"——只要还差一份分片，所有业务功能就完全不可用。这是 Shamir 数学性质的体现：少于 K 份分片在信息论上对 Unseal Key **零信息泄漏**，Vault 内部连"试试用部分信息解密"的概念都没有。

## 1.6 验证"任意 K 份"——用第 4 份完成解封

我们故意不用第 3 份，跳过它，直接用第 4 份：

```bash
vault operator unseal "$(cat shares/share-4.key)"
vault status | grep "Sealed"
```

```
Sealed             false              ← 解封成功
```

第 1+2+4 份和第 1+2+3 份**完全等价**。这就是为什么生产环境敢于把 5 份分片交给 5 个不同的人——只要任意 3 个人能到场，集群就能恢复服务，对单点缺勤有天然容错。

业务恢复：

```bash
vault kv get secret/seal-demo
```

## 1.7 取消进行中的解封：`vault operator unseal -reset`

实际运维中，如果发现"我提交的分片是错的"或"想中止本次解封"，Vault 提供了一键重置：

```bash
# 先封印
vault operator seal

# 提交 2 份后突然反悔
vault operator unseal "$(cat shares/share-1.key)" > /dev/null
vault operator unseal "$(cat shares/share-2.key)" > /dev/null
vault status | grep -E "Unseal Progress|Nonce"

# 一键重置
vault operator unseal -reset
vault status | grep -E "Unseal Progress|Nonce"
```

输出：

```
Unseal Progress    0/3
Unseal Nonce       n/a
```

进度归零，Nonce 失效。后续任何用旧 Nonce 提交的分片都会失败——这是另一个抗劫持的细节。

## 1.8 重新解封，准备进入第二步

```bash
vault operator unseal "$(cat shares/share-1.key)" > /dev/null
vault operator unseal "$(cat shares/share-2.key)" > /dev/null
vault operator unseal "$(cat shares/share-3.key)" > /dev/null

vault status | grep "Sealed"
vault kv get secret/seal-demo
```

完成后点击 **Continue** 进入第二步。
