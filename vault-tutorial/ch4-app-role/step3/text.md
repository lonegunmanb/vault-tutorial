# 第三步：CIDR 约束——在 Vault 端把不合规来源拦掉

[4.2 章 §5.1](/ch4-app-role) 引用了官方的两个 CIDR 字段：

- `secret_id_bound_cidrs`：限制**哪些 IP 能执行登录操作**（更准确说：
  限制哪些 IP 能用某个 SecretID 来换 token）
- `token_bound_cidrs`：进一步限制**这枚 token 自身能被哪些 IP 使用**

这一步把它们都加到 role 上，并**故意用一个不在段内的来源** 触发
Vault 端的拒收，看清这条约束在哪一层执行。

## 3.1 看一下当前实例对外的本机 IP

Killercoda 这台容器对内一般是 `127.0.0.1`：

```bash
hostname -I | tr ' ' '\n' | head
ip route get 8.8.8.8 2>/dev/null | head -1 || true
```

我们等一下要做两个对照实验：

- A. CIDR 段写成 `127.0.0.1/32`——loopback 客户端**应该能登**
- B. CIDR 段改成 `10.99.99.0/24`（一个**故意不包含 127.0.0.1** 的网
  段）——同一个 loopback 客户端**应该被 Vault 直接拒**

## 3.2 配 role：先用允许 loopback 的 CIDR

```bash
vault write auth/approle/role/my-role \
    token_type=batch \
    bind_secret_id=true \
    secret_id_ttl=10m \
    secret_id_num_uses=5 \
    token_ttl=20m \
    token_max_ttl=30m \
    secret_id_bound_cidrs="127.0.0.1/32" \
    token_bound_cidrs="127.0.0.1/32"
```

> 注意：CIDR 列表里写 `0.0.0.0/0` 等同于"不限制"——
> [4.2 章 §5.1](/ch4-app-role) 引的官方示例就是 `"0.0.0.0/0","127.0.0.1/32"`
> 那种"既允许任意，又显式列出 loopback"的写法，主要为了文档示意。生
> 产环境永远不要写 `0.0.0.0/0`，它把 CIDR 这道防线整体废掉。

取新 SecretID：

```bash
ROLE_ID=$(vault read -field=role_id auth/approle/role/my-role/role-id)
SECRET_ID=$(vault write -f -field=secret_id auth/approle/role/my-role/secret-id)
```

> 注意：取 SecretID 时 `secret_id_bound_cidrs` 已经被烙进 SecretID
> 自己的 metadata 里。若你想看得更细，可以保留 `secret_id_accessor`
> 并用 `vault write auth/approle/role/my-role/secret-id-accessor/lookup secret_id_accessor=<accessor>`
> 查询。这意味着
> **改 role 的 CIDR 不会影响已经发出的 SecretID**——已发的 SecretID
> 还是按发出时的 CIDR 走。所以 §3.4 改 CIDR 之后必须**取个新的
> SecretID** 才能验证新 CIDR 生效。

## 3.3 loopback 登录 → 成功

```bash
vault write auth/approle/login \
    role_id=$ROLE_ID \
    secret_id=$SECRET_ID
```

正常拿到 token——`127.0.0.1` 在允许列表里。

`vault token lookup` 这枚 token，会看到 `bound_cidrs` 字段也被烙上了
`127.0.0.1/32`：

```bash
APP_TOKEN=$(vault write -field=token auth/approle/login \
    role_id=$ROLE_ID \
    secret_id=$(vault write -f -field=secret_id auth/approle/role/my-role/secret-id))

VAULT_TOKEN=$APP_TOKEN vault token lookup | grep -E "bound_cidrs|policies|ttl"
```

> `token_bound_cidrs` 里写了什么，登出来的 token 自己就被绑死在那
> 里——后续这枚 token 即便被偷走带到别的 IP 上，也用不了。

## 3.4 改 CIDR 到一个故意不包含 loopback 的段

```bash
vault write auth/approle/role/my-role \
    token_type=batch \
    bind_secret_id=true \
    secret_id_ttl=10m \
    secret_id_num_uses=5 \
    token_ttl=20m \
    token_max_ttl=30m \
    secret_id_bound_cidrs="10.99.99.0/24" \
    token_bound_cidrs="10.99.99.0/24"
```

**取一个新的 SecretID**（按 §3.2 的注意：旧 SecretID 还是按老 CIDR
走）：

```bash
SECRET_ID_NEW=$(vault write -f -field=secret_id auth/approle/role/my-role/secret-id)
```

## 3.5 loopback 用新 SecretID 登录 → 被 Vault 拒

```bash
vault write auth/approle/login \
    role_id=$ROLE_ID \
    secret_id=$SECRET_ID_NEW
```

会立刻报错：

```
Error writing data to auth/approle/login: Error making API request.

URL: PUT http://127.0.0.1:8200/v1/auth/approle/login
Code: 400. Errors:

* source address "127.0.0.1" unauthorized through CIDR restrictions on the secret ID
```

**注意错误信息这次具体到了 `source address`**——它说的是登录请求的
源 IP 不在 SecretID 自己烙着的 CIDR 段里。这一层拦截发生在 Vault
**收到登录请求后、走完 SecretID 校验流程之前**——压根不会触发"消耗
一次 num_uses"的副作用。

> 对比 step 2 的 `invalid secret id` 模糊错误：CIDR 拒绝是给的明确
> 错误，因为**源 IP 是个公开可见的事实**（Vault 收到请求时已经看见
> 了）——告诉你"你这个 IP 不在白名单里"不会泄漏任何机密信息。

## 3.6 改回 loopback 的 CIDR，为 step 4 准备

下一步要做 wrapping 演练，回到 loopback 允许：

```bash
vault write auth/approle/role/my-role \
    token_type=batch \
    bind_secret_id=true \
    secret_id_ttl=10m \
    secret_id_num_uses=5 \
    token_ttl=20m \
    token_max_ttl=30m
```

> 这次没写 `secret_id_bound_cidrs` 和 `token_bound_cidrs`——它们就
> 被清空了（默认是空数组 = 不限）。

## 3.7 这一步的核心收获

| 字段 | 拦截位置 | 错误信息 |
| :--- | :--- | :--- |
| `bind_secret_id=true` 时缺 `secret_id` | 登录端点参数校验 | `missing secret_id` |
| `secret_id` 已用完 (`num_uses` 耗尽) | SecretID 状态检查 | `invalid secret id`（模糊） |
| 源 IP 不在 `secret_id_bound_cidrs` | CIDR 校验（早于 SecretID 校验） | `source address "..." unauthorized through CIDR restrictions on the secret ID`（精确） |
| token 在错误 IP 上使用 | token 校验 | `invalid token` 或 `permission denied` |

下一步是本实验的重头戏：用 Response Wrapping 把 admin / broker 同时
握有 RoleID + SecretID 的反模式修复掉。
