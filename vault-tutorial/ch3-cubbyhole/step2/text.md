# 第二步：Token 隔离——root 也看不见子 token 的 cubbyhole

3.4 文档 §5 的核心断言是：**Cubbyhole 的可见性绝对绑定到 Token，root
也不例外**。这一步我们用一对父子 token 把这条规则打实——同一个路径
`cubbyhole/hello`，root 和子 token 各写一份，最后两边读出来的是**两
份完全不同的数据**。

## 2.1 Root 先写一份

```bash
vault write cubbyhole/hello msg="from root"
vault read  cubbyhole/hello
```

输出 `msg=from root`。这是 root token 自己的 cubbyhole 命名空间。

## 2.2 创建一个子 token

```bash
CHILD=$(vault token create -ttl=10m -format=json | jq -r .auth.client_token)
echo "CHILD=$CHILD"
```

`vault token create` 默认从当前 token（root）派生一个子 token。注意
我们**没有**给它任何自定义 policy，它只继承了 default policy——而
default policy 已经放开了 `cubbyhole/*` 的全套权限（见 3.4 文档 §6）。

## 2.3 子 token 写**同名路径** `cubbyhole/hello`

```bash
VAULT_TOKEN=$CHILD vault write cubbyhole/hello msg="from child"
VAULT_TOKEN=$CHILD vault read  cubbyhole/hello
```

子 token 读出来 `msg=from child`——**和 root 写的不冲突，因为这是
两个完全独立的命名空间**。

## 2.4 关键：root 再读一次，依然是 `from root`

```bash
VAULT_TOKEN=root vault read cubbyhole/hello
```

输出仍然是 `msg=from root`。子 token 写的那份**对 root 完全不可见**。

如果换成 KV 引擎，相同路径的两次写入会互相覆盖；但 cubbyhole 的同一
路径在不同 token 下是不同的物理位置，**不存在覆盖关系**。

## 2.5 双向 list 进一步确认

```bash
echo "--- root 看到的 keys ---"
VAULT_TOKEN=root  vault list cubbyhole/

echo "--- child 看到的 keys ---"
VAULT_TOKEN=$CHILD vault list cubbyhole/
```

两边都返回一行 `hello`——但同名 key 的内容是 §2.4 已经验证过的两份
不同数据。

## 2.6 root 能不能"用某种姿势"读到子 token 的数据？

不能。Vault 没有提供任何 API 让你"切换 cubbyhole 视图"——可见性是
当前请求所带 token 决定的。验证一下：

```bash
echo "--- root 用最底层的 sys API 试试 ---"
VAULT_TOKEN=root vault read sys/raw/sys/token/ 2>&1 | head -3

echo ""
echo "--- root 试试看子 token 的元数据（这一项倒是可以） ---"
vault token lookup "$CHILD" | head -10
```

`sys/raw` 在 dev 模式下需要专门 enable，并不是日常运维路径，**也读
不到 cubbyhole 内容**——cubbyhole 数据在 Vault barrier 之内，
被 token UUID 命名空间分片，没有任何受支持的 API 能"绕过"这一层。

`vault token lookup` 能看到子 token 的元数据（display_name、policies、
TTL），但**看不到它的 cubbyhole 数据**——这两件事在 Vault 内部是分
开存的。

## 2.7 想真的看到子 token 写的内容？只能用子 token 自己

```bash
VAULT_TOKEN=$CHILD vault read cubbyhole/hello
```

只有持有那个 token 的人能看。**没有"管理员视图"，root 也不行**。这
正是 Response Wrapping 能保证机密性的根本原因——下一步 Step 4 会把
这条结论用在 wrap/unwrap 流程上。

---

> 接下来 Step 3 看：当 token 死了（过期或被 revoke），它的 cubbyhole
> 会怎样。
