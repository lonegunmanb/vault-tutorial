# 第三步：删除三态——软删 / undelete / destroy / metadata delete

KV v2 把"删除"切成三个独立的不可恢复性梯度。这一步把它们各跑一遍，
亲眼看每一态下数据 / 元数据的变化。

## 3.1 先准备一条干净的 key

```bash
vault kv put kv/app/secret-x password=p1 > /dev/null
vault kv put kv/app/secret-x password=p2 > /dev/null
vault kv put kv/app/secret-x password=p3 > /dev/null

echo "=== 当前版本元数据 ==="
vault kv metadata get kv/app/secret-x | head -10
```

应该看到 `current_version=3`、3 个 `Version N` 块都健康（`destroyed=false`、
`deletion_time=n/a`）。

## 3.2 软删除：`vault kv delete`

```bash
vault kv delete kv/app/secret-x
```

观察发生了什么：

```bash
echo "=== 直接 get（默认拿最新版）==="
vault kv get kv/app/secret-x 2>&1 | head -15

echo ""
echo "=== 元数据视图：v3 现在多了 deletion_time ==="
vault kv metadata get kv/app/secret-x | tail -25
```

`vault kv get` 报"v3 已被标记删除、deletion_time 已设置"，但**底层
数据并没被擦除**——这从 `vault kv metadata get` 输出里 v3 仍然
`destroyed=false` 可以看出来。

## 3.3 undelete：把软删撤销回来

```bash
vault kv undelete -versions=3 kv/app/secret-x

echo "=== v3 恢复了 ==="
vault kv get kv/app/secret-x | tail -5
```

`password=p3` 又能读出来了——软删除是**完全可逆**的，这就是它存在的
意义：误删保护。

## 3.4 也可以软删指定的一组旧版本

```bash
vault kv delete -versions=1,2 kv/app/secret-x
vault kv metadata get kv/app/secret-x | tail -25
```

v1 和 v2 各自被打上 `deletion_time`，v3 仍然干净。

把它们再 undelete 回来：

```bash
vault kv undelete -versions=1,2 kv/app/secret-x
```

## 3.5 硬删除：`vault kv destroy`（不可逆）

```bash
echo "=== destroy v1：物理擦除该版本数据 ==="
vault kv destroy -versions=1 kv/app/secret-x

echo ""
echo "=== 试图读 v1，应该拿不到数据 ==="
vault kv get -version=1 kv/app/secret-x 2>&1 | tail -5

echo ""
echo "=== 元数据：v1 现在 destroyed=true ==="
vault kv metadata get kv/app/secret-x | grep -A 5 "Version 1"
```

`destroyed=true` 表示该版本的**数据块已经被擦除**——任何方式都拿不
回 `p1` 了。但 metadata 中**仍记录"v1 曾经存在过、已被销毁"**，审计
和合规链条依然完整。

> 误删的代价：v1 的密码 `p1` 永远找不回来了。如果你需要它，唯一的办
> 法是事先有外部备份。

## 3.6 metadata delete：连元数据也清空

最彻底的一种——把整条 key 从 `metadata/` 中抹掉：

```bash
echo "=== 抹掉前：list 能看到 secret-x ==="
vault kv list kv/app/

vault kv metadata delete kv/app/secret-x

echo ""
echo "=== 抹掉后：list 中 secret-x 消失 ==="
vault kv list kv/app/

echo ""
echo "=== 任何版本都拿不到了 ==="
vault kv get kv/app/secret-x 2>&1 | tail -3
```

这一步同时做了两件事：

1. 销毁了所有版本的数据（包括之前还活着的 v2、v3）
2. 把 `metadata/app/secret-x` 也清空了

效果上等同于"这条 key 从未在这个引擎里存在过"——**只有 Vault 的审
计设备里还能查到这次操作的记录**。

## 3.7 三态对照速查

| 想做的事 | 命令 | 数据 | metadata | 可恢复性 |
| --- | --- | --- | --- | --- |
| 误删保护 | `vault kv delete` | 原地保留，标 deletion_time | 完整 | ✅ undelete |
| 撤销软删 | `vault kv undelete -versions=N` | 恢复可读 | 完整 | — |
| 物理销毁某版本 | `vault kv destroy -versions=N` | **擦除** | 标 destroyed=true | ❌ |
| 销毁整条 key | `vault kv metadata delete` | 全部擦除 | **清空** | ❌ |

记住一条原则：**`delete` / `undelete` 是 reversible 的，`destroy` /
`metadata delete` 是 irreversible 的**。设计 Policy 时把这两类授权
分开（比如运维只给 `delete/undelete`、安全管理员才能 `destroy`），
让"凭据物理销毁"始终是个有意识的高权限动作。

---

> 接下来最后一步：把上面所有动作映射回 Policy 路径段，演示最经典的
> "前缀对了但少了 `data/` → 403"踩坑。
