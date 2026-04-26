# 第一步：启用 KV v2 并看穿 `data/` + `metadata/` 双层路径

文档里反复出现的一句话：

> The `kv put` and `kv get` commands automatically prepend `data/` to
> the path. The `kv list` command prepends `metadata/`.

这一步我们就用最朴素的办法**亲手把这层"自动"撕掉**——同一条数据用
`vault kv get` 和 `vault read` 两种姿势各读一次，看路径上的差别。

## 1.1 启用一个属于本实验的 KV v2 引擎

Dev 模式下 `secret/` 已经是一个 v2 实例，但为了观察"全新挂载点"的
行为，挂一个我们自己的：

```bash
vault secrets enable -path=kv -version=2 kv
vault secrets list | grep -E "Path|^kv/"
```

注意 `Type` 列写的是 `kv`、不是 `kv-v2`——版本是引擎的 **Options**：

```bash
vault read sys/mounts/kv | grep -E "type|version"
```

会看到 `type kv` 和 `options map[version:2]`——这两个加在一起才是
"KV v2"。

## 1.2 写入第一条数据

```bash
vault kv put kv/app/db username=root password=s3cret
```

留意输出里的 `Secret Path`：

```
====== Secret Path ======
kv/data/app/db
```

`vault` CLI 已经把 `data/` 段加上去了——但它只是**告诉你**它做了什
么，并不要求你在 `kv put` 的命令行上自己写 `data/`。

## 1.3 用 `vault kv get` 读：CLI 替你拼好的路径

```bash
vault kv get kv/app/db | tail -10
```

输出末尾有 Data 块，`password=s3cret` 在其中。CLI 隐藏了 `data/` 段，
看起来跟 KV v1 没什么区别。

## 1.4 用 `vault read` 读：必须显式写 `data/`

`vault read` 是底层通用读命令，它**不会**帮你拼 `data/`：

```bash
echo "=== 错误姿势：忘了写 data/ ==="
vault read kv/app/db 2>&1 | head -3

echo ""
echo "=== 正确姿势：显式 data/app/db ==="
vault read kv/data/app/db
```

第一条会报 `No value found at kv/app/db`——这就是没有 `data/` 段时
v2 的真实行为。第二条返回的 JSON-like 输出里嵌了两层 `data`：

- 外层 `data.metadata`：版本号、创建时间、destroyed 标记
- 外层 `data.data`：你写进去的 username / password

## 1.5 再看 `metadata/` 这条平行命名空间

```bash
echo "=== vault kv list 实际访问的是 metadata/ ==="
vault kv list kv/app/

echo ""
echo "=== 等价的 vault list 写法 ==="
vault list kv/metadata/app/

echo ""
echo "=== 同一条 key 的元数据视图 ==="
vault read kv/metadata/app/db
```

`metadata/app/db` 的输出里没有 `username` / `password`——只有
`current_version=1`、`max_versions=0`、各版本的 `created_time` 和
`destroyed` 标记。**数据归 `data/`，元信息归 `metadata/`，从挂载那一刻
就分好了。**

## 1.6 用 JSON 输出确认 envelope 结构

```bash
vault kv get -format=json kv/app/db | jq '{data: .data.data, meta: .data.metadata}'
```

把外层 envelope 拆开，`data.data` 是真实业务字段、`data.metadata` 是
本次读取拿到的版本元数据。**应用代码用 HTTP API 读 KV v2 时，对这两
层嵌套必须有心理准备**——很多业务 bug 是把 envelope 当业务字段一起
存进了下游系统。

---

> 接下来一步开始堆版本号，并演示 `patch` 与 CAS 写。
