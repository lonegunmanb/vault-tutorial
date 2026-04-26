# 第二步：版本历史、`patch` 局部更新与 CAS 写并发控制

KV v2 相对 v1 最大的卖点就是**每次写入都留一个带版本号的快照**。这
一步我们手动堆出几个版本，再演示 `patch` 局部更新和 CAS 写在并发
冲突时的拒绝行为。

## 2.1 多次写入产生版本历史

为了让版本号能和 value 对得上号，这里不复用 step1 的 `kv/app/db`（那
里已经有 v1=`s3cret`），另起一条干净的 key `kv/app/web`：

```bash
vault kv put kv/app/web username=root password=v1 > /dev/null
vault kv put kv/app/web username=root password=v2 > /dev/null
vault kv put kv/app/web username=root password=v3 > /dev/null

echo "=== 当前最新版本 ==="
vault kv get kv/app/web | tail -8
```

输出里 `version 3`、`password v3`——这条新 key 还没被写过，所以三次
put 干干净净映射到 v1 / v2 / v3。`vault kv get` 显示的 **`version`**
字段表示"你这次读到的是第几版"。

无论怎么 destroy / delete，**版本号永不回退**——`put` 永远在最大值
基础上 +1。

## 2.2 列出全部版本

```bash
vault kv metadata get kv/app/web
```

输出顶部是引擎级别的元数据（`max_versions`、`cas_required`、
`oldest_version`、`current_version`），底部是每个版本的 `Version N`
块——`created_time`、`deletion_time`、`destroyed` 三个字段告诉你
每一个历史版本的状态。

这里第一次出现的 **`current_version`** 表示这条 key 的最新版本号——
是引擎层面的"最大值"。和 §2.1 里 `vault kv get` 显示的 `version`
字段（"这次读到的是第几版"）数值上通常相等，但字段名和含义不同：
前者是"当前的最大版本号"，后者是"本次响应附带的版本号"。`vault kv
get -version=1` 时返回的 `version=1`，但 `current_version` 仍是 3。

## 2.3 定向读取历史版本

```bash
echo "=== 当前版本（最新一次写入）==="
vault kv get kv/app/web | grep password

echo ""
echo "=== 第 1 版 ==="
vault kv get -version=1 kv/app/web | grep password

echo ""
echo "=== 第 2 版 ==="
vault kv get -version=2 kv/app/web | grep password
```

依次是 `v3` / `v1` / `v2`——版本号和 value 字面值一一对应。**版本号
永远只反映"第几次写入"，和你随手起的 value 字面值本来无关**——这里
刚好对得上是因为我们故意起了一条新 key 并按顺序命名 value。

任意未被 `destroy` 的历史版本都能定向回读——这是 KV v2 相对 v1 最
关键的能力。

## 2.4 `patch`：字段级合并 vs `put` 全量覆盖

`put` 是**全量覆盖**——你必须把所有字段都写一遍，否则没列出的会丢：

```bash
echo "=== 用 put 只写 password，username 会消失 ==="
vault kv put kv/app/web password=will-lose-username
vault kv get kv/app/web | tail -8
```

注意 Data 块里**只剩 `password` 一个字段了**——`username` 没了。这
是 v2 设计上的一致性：每个 version 都是一份独立的快照，`put` 写的就
是新快照的全部内容。

把它先恢复回来：

```bash
vault kv put kv/app/web username=root password=v5
```

现在用 `patch` 只改一个字段，其他保留：

```bash
vault kv patch kv/app/web password=v6
vault kv get kv/app/web | tail -8
```

这次 `username` 还在，`password` 被改成了 `v6`，版本号 +1——`patch`
在服务端用一次 CAS 完成"读老版 → 合并 → 写新版"，并发安全。

## 2.5 开启全局 CAS 要求

**CAS（Check-And-Set，检查并设置）** 是并发控制里的经典套路：写入时
带上"我看到的当前版本号是 N"这个声明，由服务端原子比较——只有当真
实的最新版本仍是 N 时才允许写入并产出 N+1，否则拒绝。这样可以防止
"两个客户端同时拿到 v=N、各自做了不同修改、后写的覆盖先写的" 这种
**丢失更新（lost update）** 问题。

KV v2 的 `cas_required` 开关把这个要求强制到引擎级别——开启后所有
`put` 都必须带 `-cas=N`：

```bash
vault write kv/config cas_required=true
vault read kv/config
```

`cas_required=true` 之后，**所有的 `put` 都必须带 `-cas=N`**，否则
拒绝写入：

```bash
echo "=== 不带 cas，应该被拒绝 ==="
vault kv put kv/app/web password=should-fail 2>&1 | tail -3
```

输出里能看到 `check-and-set parameter required for this call`。

## 2.6 正确的 CAS 写

先看一眼当前版本号：

```bash
CUR=$(vault kv get -format=json kv/app/web | jq -r .data.metadata.version)
echo "当前 version = $CUR"

vault kv put -cas=$CUR kv/app/web password=v-cas-ok username=root
```

成功，版本号 `+1`。

## 2.7 CAS 冲突演示

如果用一个**过时的版本号**去写，模拟"两个客户端同时拿到了 v=N、然后
B 已经写完成 v=N+1、A 才迟到"的场景：

```bash
echo "=== 拿一个过时的版本号去写，应该被拒绝 ==="
vault kv put -cas=1 kv/app/web password=stale 2>&1 | tail -3
```

输出 `check-and-set parameter did not match the current version`——
Vault 拒绝写入，不会产生新版本，也不会覆盖任何东西。客户端拿到这个
错误后，自己决定是重读再合并、还是放弃。

清理一下，把 cas_required 关掉，方便后续步骤：

```bash
vault write kv/config cas_required=false
```

## 2.8 自动版本回收：`max_versions`

```bash
vault write kv/metadata/app/web max_versions=3
```

之后每次 `put` 都会**自动 destroy 最早的版本**，永远只保留最近 3 份。
我们写一条新版本验证：

```bash
vault kv put kv/app/web password=after-cap username=root > /dev/null
vault kv metadata get kv/app/web | grep -E "current_version|oldest_version|max_versions"
```

`oldest_version` 会随着 `current_version` 上涨而前移——超过 3 个的
旧版本被自动 destroy（`destroyed=true`），**底层数据被擦除，但
metadata 里仍标记"曾经存在过"**。这种行为对凭据轮转场景非常有用：
保留最近几次轮转结果以便回滚，旧的自动清理。

---

> 接下来一步演示 KV v2 的"删除三态"。
