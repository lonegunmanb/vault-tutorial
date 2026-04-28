# 第四步：force-identity-deduplication 激活与不可逆语义

[3.6 §5](/ch3-identity) 介绍了 1.19+ 的去重激活机制：

- 旧版 Vault 的 bug 可能在持久化存储里留下重复 entity / alias / group
- 1.19+ 在 unseal 阶段会**主动检测**并打日志
- 提供一个**一次性、永远不可逆**的开关
  `sys/activation-flags/force-identity-deduplication/activate` 来彻
  底强制去重

我们的 Dev 模式 Vault 是干净的（没有任何旧版本残留的重复），所以这
一步主要演示**流程与不可逆语义**——而不是真的去清理重复数据。

## 4.0 这个开关到底解决了什么问题？

先用两张图张图把"问题 → 解决方案 → 新保障"全讲清楚——后面 §4.1 ~ §4.5
就是亲手跑第二张图里的每一格：

![dedup-problem](../assets/dedup-problem.png)
![dedup-upgrade](../assets/dedup-upgrade.png)

> **两层不可逆一句话总结**：启用新打印机 = "最终出售、不退不换"
> （**开关不可逆**）；新打印机开机那一刻把两张证合并成一张，碎掉
> 的那张再也拼不回来（**合并不可逆**）。所以文档反复强调：推开关
> 之前先确认每一组重复确实该合并——合错了也没有"撤销 merge"。

下面 §4.1 ~ §4.5 就是亲手把图里每一格跑一遍。

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

应该看到 `activated` 列表为空：

```
Key          Value
---          -----
activated    []
```

## 4.3 激活——启用新打印机（最终出售、不退不换）

```bash
vault write -f sys/activation-flags/force-identity-deduplication/activate
```

激活成功——相当于把旧打印机退役、换上了新的。再看一次状态：

```bash
vault read sys/activation-flags
```

`force-identity-deduplication` 应该已经出现在 `activated` 列表里：

```
Key          Value
---          -----
activated    [force-identity-deduplication]
```

## 4.4 验证"不退不换"

再激活一次：

```bash
vault write -f sys/activation-flags/force-identity-deduplication/activate
```

Vault 不会报错，但后台不再做任何事情——新打印机已经在位，再按一
次按钮只是 no-op。更重要的是**不存在 `deactivate` 接口**——吊牌
上写的"最终出售、不退不换"名副其实。

这就是**两层不可逆**：
1. **开关不可逆**——新打印机回不去老的，该集群从此 unseal 都跑查重
2. **合并不可逆**——激活那一刻碎掉的重复 entity 再也拼不回来，想拆
   只能手动新建 entity + 重绑 alias（新 ID 和历史审计/token 全对不
   上号）

## 4.5 副作用观察：每次开机（unseal）新打印机都自动查重

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

## 4.6 总结：老打印机 vs 新打印机

| 维度 | 老打印机（激活前） | 新打印机（激活后） |
| --- | --- | --- |
| 重复 entity / alias / group | 可能存在（旧版 bug 造成） | 第一次开机就合并清掉 |
| 未来出现新重复 | 可能（并发竞态 + 残留 bug） | 每次开机自动查重，发现即拒绝 |
| 退回老打印机 | — | **不行，最终出售、不退不换** |
| 拆开已合并的 entity | — | **不行，碎纸篓里的 UUID 拼不回来** |

---

> 进入 Finish 总结。
