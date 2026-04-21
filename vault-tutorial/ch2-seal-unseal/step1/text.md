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
vault operator unseal "$(cat /root/workspace/shares/share-1.key)"
```

输出尾部：

```
Sealed             true
Total Shares       5
Threshold          3
Unseal Progress    1/3
Unseal Nonce       <一串 UUID>      ← 出现了！
```

**Nonce 是什么？** 它是这一次解封会话的唯一标识符。要理解它的必要性，我们先想象**没有 Nonce** 的 Vault 会发生什么。

按 Shamir 协议，要重组出 Unseal Key 需要 K 份分片。如果服务端只是傻傻地维护一个计数器和一个"已收到的分片缓冲区"，那么会出现这种情况：

> **场景**：合法持有人 A、B、C 正在协作解封 Vault（threshold=3）。
>
> 1. A 调用 `vault operator unseal <share-A>` —— 服务端缓冲区：`[share-A]`，进度 1/3
> 2. B 调用 `vault operator unseal <share-B>` —— 服务端缓冲区：`[share-A, share-B]`，进度 2/3
> 3. 此时攻击者 X 抢在 C 之前，调用 `vault operator unseal <随便一串伪造的字节>`
>    —— 服务端无法区分这是"另一个人的合法分片"还是"乱来"，进度直接变成 3/3
> 4. 服务端尝试把 `[share-A, share-B, 伪造串]` 喂给 Shamir 重组算法
>    —— 算出来的 Unseal Key 当然是垃圾，**解封失败**
> 5. 服务端把缓冲区清空，回到 0/3。**A 和 B 之前提交的两份合法分片就此被作废**
> 6. C 现在到场，提交自己的分片 —— 进度 1/3，又得从头协调 A、B 重新提交一遍

这是一种**拒绝服务（DoS）攻击**：X 没法解封 Vault（他只有 1 份分片，从信息论上推不出 Unseal Key），但他可以**反复污染解封会话**，让真正的持有人永远凑不齐三份分片完成解封。在生产事故响应场景下，这个攻击足以让 Vault 处于"事实上不可用"的状态。

**Nonce 是怎么堵死这个攻击的？**

引入 Nonce 后，协议变成：

1. 第一份分片到达时（`unseal -reset` 或上次解封完成后的第一次 unseal），服务端**生成一个随机 UUID**作为本次会话的 Nonce，并把它返回给客户端
2. 后续每一次 `vault operator unseal` 请求，**客户端必须随请求带上这个 Nonce**（CLI 默认会自动从 `vault status` 取，但 API 调用必须显式传 `nonce` 字段）
3. 服务端只把"携带匹配 Nonce"的分片累加到缓冲区。Nonce 不匹配的请求被直接拒绝，**不计入进度、不污染缓冲区**

回到上面的攻击场景：A、B 提交时拿到了 Nonce `n1`。X 不知道 `n1`（或者 X 故意用空 Nonce 想"启动新会话"），他的请求会被服务端识别为"另一次解封尝试"——而**已经存在一个进行中的会话时**，新会话不能启动，X 的请求直接报错，A 和 B 的进度安然无恙。

CLI 帮我们自动处理了 Nonce 的传递，所以平时感觉不到它存在。但只要你直接调 HTTP API（比如 `curl /v1/sys/unseal`），就必须自己管理 Nonce。下面这条命令可以确认 CLI 当前正在用的 Nonce：

```bash
NONCE=$(vault status -format=json | jq -r '.nonce')
echo "当前 Nonce: $NONCE"
```

## 1.4 提交第 2 份，验证 Nonce 不变

```bash
vault operator unseal "$(cat /root/workspace/shares/share-2.key)"

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
vault operator unseal "$(cat /root/workspace/shares/share-4.key)"
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
vault operator unseal "$(cat /root/workspace/shares/share-1.key)" > /dev/null
vault operator unseal "$(cat /root/workspace/shares/share-2.key)" > /dev/null
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
vault operator unseal "$(cat /root/workspace/shares/share-1.key)" > /dev/null
vault operator unseal "$(cat /root/workspace/shares/share-2.key)" > /dev/null
vault operator unseal "$(cat /root/workspace/shares/share-3.key)" > /dev/null

vault status | grep "Sealed"
vault kv get secret/seal-demo
```

完成后点击 **Continue** 进入第二步。
