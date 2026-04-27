# 第四步：force-identity-deduplication 激活与不可逆语义

[3.6 §5](/ch3-identity) 介绍了 1.19+ 的去重激活机制：

- 旧版 Vault 的 bug 可能在持久化存储里留下重复 entity / alias / group
- 1.19+ 在 unseal 阶段会**主动检测**并打日志
- 提供一个**一次性、永远不可逆**的开关
  `sys/activation-flags/force-identity-deduplication/activate` 来彻
  底强制去重

我们的 Dev 模式 Vault 是干净的（没有任何旧版本残留的重复），所以这
一步主要演示**流程与不可逆语义**——而不是真的去清理重复数据。

## 4.1 看 unseal 日志确认没有 `DUPLICATES DETECTED`

Dev 模式 Vault 的日志在 `/var/log/vault-dev.log`：

```bash
grep -E "post-unseal setup starting|post-unseal setup complete|DUPLICATES DETECTED" /var/log/vault-dev.log
```

你会看到 setup starting → setup complete 两行夹着一段日志，**没有**
`DUPLICATES DETECTED` 一行——这意味着当前集群干净，可以直接进 §5.1
第 5 步激活。

> 在生产里：如果这里看到了 `DUPLICATES DETECTED`，**绝对不要**直接激
> 活。先按 [official deduplication 文档](https://developer.hashicorp.com/vault/docs/secrets/identity/deduplication)
> 第 2-3 步把重复手工解决，再来第 5 步。激活前还存在的重复不会被自
> 动 merge。

## 4.2 看一眼当前 activation flags 状态

```bash
vault read sys/activation-flags
```

应该看到 `force-identity-deduplication` 在 **unactivated** 列表里。

## 4.3 激活——这一步**永远不能回退**

```bash
vault write -f sys/activation-flags/force-identity-deduplication/activate
```

激活成功。再看一次状态：

```bash
vault read sys/activation-flags
```

`force-identity-deduplication` 应该已经从 unactivated 移到 activated
列表。

观察日志里的两行（这两行之间的耗时就是"全集群身份缓存重载"的实际时
长，生产里要拿来评估容量）：

```bash
grep "force-identity-deduplication activated" /var/log/vault-dev.log
```

应该有：

```
INFO core: force-identity-deduplication activated, reloading identity store
INFO core: force-identity-deduplication activated, reloading identity store complete
```

## 4.4 验证"不可逆"语义

再激活一次：

```bash
vault write -f sys/activation-flags/force-identity-deduplication/activate
```

Vault 不会报错，但后台不再做任何事情——已经激活的 flag 不会"再激活
一次"，更不能"取消激活"。**这就是文档反复强调的 one-way 语义**：决
策一旦做出，该集群从此每次 unseal 都会强制去重检查。

## 4.5 副作用观察：unseal 时多了一道去重检查

模拟一次"重启 Vault 看 unseal 流程"。Dev 模式 Vault 不能优雅 seal，
我们直接 SIGINT 重启：

```bash
# 先记一下当前 PID
VAULT_PID=$(pgrep -f "vault server -dev")
echo "VAULT_PID=$VAULT_PID"

# 杀掉
kill -INT $VAULT_PID

# 等几秒后重启（用 init 时同样的命令）
sleep 3
nohup vault server -dev -dev-root-token-id=root \
  -dev-listen-address=0.0.0.0:8200 \
  > /var/log/vault-dev.log 2>&1 &

# 等就绪
for i in $(seq 1 20); do
  if vault status > /dev/null 2>&1; then echo "Vault is back."; break; fi
  sleep 1
done
```

看新的 unseal 日志：

```bash
grep -E "post-unseal setup starting|post-unseal setup complete|force-identity-deduplication|DUPLICATES" /var/log/vault-dev.log
```

你会看到 unseal 流程里**自动跑了一次 force-identity-deduplication
check**——这就是激活后**每次 unseal 都会做**的那一步。Dev 模式数据
干净，所以耗时几乎为 0。生产集群带百万级 Entity 时，这道检查也通常
比一次正常 unseal 还快（因为 1.19+ 把它做成了纯校验、不再扫描全表）。

## 4.6 总结：激活前 / 激活后

| 维度 | 激活前 | 激活后 |
| --- | --- | --- |
| 重复 entity / alias / group | 可能存在（来自旧版 bug） | 一次 reload 全部清掉 |
| 未来出现新重复 | 可能（取决于 client 行为 + 残留 bug） | Vault 在 unseal 时强制校验 + 记录 |
| 关闭这个特性 | — | **不行，永不可逆** |
| 每次 unseal 时间 | 含旧 dedup 检查（带 DUPLICATES 日志） | 含纯校验（无 DUPLICATES 日志，更快） |

---

> 进入 Finish 总结。
