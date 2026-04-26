# 第三步：Token 寿命即数据寿命——TTL 到期 / revoke 时同步销毁

3.4 文档反复强调的一句话：**当 Token 过期或被 revoke，cubbyhole 会被
原子清空**。这一步我们用两条独立的 token 把这条规律分别跑通：一条用
**TTL 到期**触发清空，另一条用**显式 revoke**触发。

## 3.1 路径 A：短 TTL token，等它自己过期

创建一个 30 秒就过期的 token：

```bash
SHORT=$(vault token create -ttl=30s -format=json | jq -r .auth.client_token)
echo "SHORT=$SHORT"
```

用它写一份 cubbyhole 数据并立即读：

```bash
VAULT_TOKEN=$SHORT vault write cubbyhole/timer msg="ticking..."
VAULT_TOKEN=$SHORT vault read  cubbyhole/timer
```

**关键提醒**：cubbyhole 的数据**没有自己的 TTL**——它的寿命就是
token 的寿命，到点一起死。所以下面这一行不是"等数据过期"，而是"等
token 过期"：

```bash
echo "等待 35 秒让 token 过期..."
sleep 35
```

期满后用同一个 token 再读：

```bash
VAULT_TOKEN=$SHORT vault read cubbyhole/timer 2>&1 | head -5
```

会拿到 `Code: 403`——`permission denied`。这不是因为"权限被收回了"，
而是 token 本身已经不存在了，所有它能做的事（包括读自己的 cubbyhole）
全部连根失效。

> 即使**别人**这一刻知道了路径名 `cubbyhole/timer`，也没有任何 token
> 能读到那份内容——它在 token 过期的同时被 Vault 物理清掉了。

## 3.2 路径 B：长 TTL token，但被显式 revoke

```bash
LONG=$(vault token create -ttl=24h -format=json | jq -r .auth.client_token)
echo "LONG=$LONG"

VAULT_TOKEN=$LONG vault write cubbyhole/notes a=1 b=2 c=3
VAULT_TOKEN=$LONG vault list  cubbyhole/
```

注意这里我们写了 3 个字段、列出来能看到 `notes` 这个 key。

现在**用 root** 主动 revoke 它：

```bash
vault token revoke "$LONG"
```

立刻再用这个 token 试读：

```bash
VAULT_TOKEN=$LONG vault read cubbyhole/notes 2>&1 | head -5
```

同样的 403。**revoke 的瞬间，cubbyhole 数据就被销毁了**——这是同步
操作，不需要等任何后台清理。

## 3.3 关键现象：父 token 被 revoke，子 token 的 cubbyhole 也跟着死

这是 Token 树形结构在 cubbyhole 上的字面体现。复现一遍：

```bash
PARENT=$(vault token create -ttl=24h -format=json | jq -r .auth.client_token)

# 用 PARENT 派生一个 CHILD
CHILD=$(VAULT_TOKEN=$PARENT vault token create -ttl=24h -format=json | jq -r .auth.client_token)

# 两个 token 各自往自己的 cubbyhole 写
VAULT_TOKEN=$PARENT vault write cubbyhole/k v=parent-data
VAULT_TOKEN=$CHILD  vault write cubbyhole/k v=child-data

# 确认两边都能读出自己的
echo "--- parent reads ---" && VAULT_TOKEN=$PARENT vault read cubbyhole/k
echo "--- child  reads ---" && VAULT_TOKEN=$CHILD  vault read cubbyhole/k
```

各自看到 `parent-data` / `child-data`——和 Step 2 一样，路径同名但
互不可见。

现在用 root **revoke 父 token**：

```bash
vault token revoke "$PARENT"
```

按 Token 体系的级联规则，这一刀会连**子 token** 一起 revoke。验证：

```bash
echo "--- parent ---" && VAULT_TOKEN=$PARENT vault read cubbyhole/k 2>&1 | head -3
echo "--- child  ---" && VAULT_TOKEN=$CHILD  vault read cubbyhole/k 2>&1 | head -3
```

**两个 token 都报 403**——子 token 的 cubbyhole 数据 (`child-data`)
也跟着没了，尽管它本来还有 24 小时 TTL。

## 3.4 为什么这条规律对 Response Wrapping 至关重要

记住这条规律：**只要持有 wrapping token 的环节失控（误传、被截胡），
revoke 它就立刻让那份被包起来的响应彻底销毁**。这是 wrap/unwrap 流
程能给"机密一次性传递"提供保证的根本机制——而不是某种神秘的加密黑
魔法。Step 4 我们把这一切串起来。

---

> 接下来 Step 4 拆开 Response Wrapping 黑箱：用 wrapping token 直接
> 读 `cubbyhole/response`。
