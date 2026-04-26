# 第一步：默认挂载与"三不允许"——亲手把禁令撞一遍

文档里写得很硬：

> The `cubbyhole` secrets engine is enabled by default. It cannot be
> disabled, moved, or enabled multiple times.

这一步我们就把这三条禁令**主动触发**一次，让你看到它们不是文字游戏，
而是 Vault 真的在 API 层硬拒。

## 1.1 它已经在那儿了

```bash
vault secrets list | grep -E "Path|cubbyhole"
```

你会看到一行 `cubbyhole/`，类型也叫 `cubbyhole`（不是 KV）。这是
Vault 启动时就挂好的——你没有任何手动操作。

把它的详情拉出来看看：

```bash
vault read sys/mounts/cubbyhole
```

注意 `local true`、`seal_wrap false`、`uuid` 是一个固定生成的
ID——这些字段我们等下要做对比。

## 1.2 写一份数据，确认基本读写

```bash
vault write cubbyhole/hello msg="root token wrote this"
vault read  cubbyhole/hello
```

**注意命令是 `vault write` / `vault read`，不是 `vault kv put`**——
Cubbyhole 是 KV v1 风格的"裸路径"引擎，`vault kv` 那一套命令是 KV 引
擎专用的，对它无效。

## 1.3 禁令一：不能 `disable`

```bash
vault secrets disable cubbyhole/
```

会立刻返回错误，类似：

```
Error disabling secrets engine at cubbyhole/: ... cannot unmount "cubbyhole/"
```

（具体 message 看版本，但一定是 4xx 失败。）原因在 3.4 文档 §2 已经
讲过：禁用它等于把所有 Token 当前的暂存数据 + 所有未拆封的 wrapping
token **全部打爆**——属于会击穿 Token 体系的破坏性操作，所以 Vault
直接在 API 层堵掉。

确认它依然健在：

```bash
vault read cubbyhole/hello
```

数据还在，没掉。

## 1.4 禁令二：不能 `move`

```bash
vault secrets move cubbyhole/ other/
```

同样立刻报错：

```
Error: ... cannot remount "cubbyhole/"
```

原因同样在 §2：Vault 内部硬编码了 `cubbyhole/response` 等系统路径，
搬走会让 Response Wrapping 等机制找不到家。

## 1.5 禁令三：不能再次 `enable`

```bash
vault secrets enable -path=cb cubbyhole
```

报错：

```
* mount type of "cubbyhole" is not mountable
```

**Cubbyhole 是 Vault 里唯一的"单例引擎"**——它的"按 Token 隔离"
语义在内部是单实现，多挂一份既无意义也会与现有路径冲突，所以 Vault
直接把这个类型从"可被用户挂载"的清单里去掉了。

## 1.6 顺手验证：连 `tune` 也被堵

常见的认知误区是"生命周期被锁，但 `tune` 这种调参应该没事"。试一下：

```bash
vault secrets tune -default-lease-ttl=10m cubbyhole/
```

会拿到：

```
* cannot tune "cubbyhole/"
```

也就是说 Cubbyhole 的所有挂载点级别操作（disable / move / 二次 enable
/ tune）**全部被禁**——它在 Vault 里就是"出厂即定型"的特殊存在。
你能对它做的只有：读它的元数据（`vault read sys/mounts/cubbyhole`）
和**通过自己的 Token 读写它的数据**，仅此而已。

---

> 接下来 Step 2 验证最反直觉的一条：**root 也看不见别人的 cubbyhole**。
