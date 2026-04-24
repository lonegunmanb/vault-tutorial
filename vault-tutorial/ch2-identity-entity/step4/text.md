# 第四步：Entity policy 在请求时动态求值

文档 §5.1 的核心论断：

> The evaluation of policies applicable to the token through its
> identity will happen at request time.

这意味着——给 entity 挂 policy 立即生效、摘掉立即失能，**不需要让
用户重新登录**。这是 Identity 系统最有威力的设计。我们来验证。

## 4.1 准备一个"只有 entity policy 才能读"的 KV

本步要搭出来的初始格局：

```
  +-------------------+        +----------------------+
  | Entity alice-real |        | Policy: eng-policy   |
  | policies: []      |        | secret/data/eng-only |
  +-------------------+        |   capabilities=read  |
                               +----------------------+
           ↑                              ↑
  (4.2 alice token 上)          (4.3 才会挂上去)
  policies = [default]
```

```bash
# dev 模式默认在 secret/ 路径下挂了 KV v2
vault kv put secret/eng-only message="hello-from-eng"
```

写一条 policy 允许读这条 KV：

```bash
vault policy write eng-policy - <<'EOF'
path "secret/data/eng-only" {
  capabilities = ["read"]
}
EOF
```

## 4.2 alice 用普通登录拿一个 token，**先证明它读不到**

现在的状态——alice 拿到 token，但通往 eng-policy 的路径还没接通：

```
  Token hvs.xxx ──→ entity_id=ent-alice-real ──→ Entity alice-real
  policies=[default]                              policies=[]   ← 还是空
         │                                              │
         │                                              ✗ 没挂 eng-policy
         ↓                                              ↓
  capabilities = [default]  ∪  []  =  [default] (没有 eng-only 的 read)
                                                          ↓
                                                  4.2 读 eng-only → 403
```

```bash
# step3 已经把 alice 的两个 alias 都归到 alice-real 下了
ALICE_TOKEN=$(vault login -format=json -method=userpass \
  username=alice password=s3cr3t | jq -r .auth.client_token)

echo "alice 这个 token 上的 policies:"
VAULT_TOKEN=$ALICE_TOKEN vault token lookup -format=json \
  | jq -r '.data.policies | join(",")'

echo "alice 试图读 secret/eng-only:"
VAULT_TOKEN=$ALICE_TOKEN vault kv get secret/eng-only 2>&1 | tail -3
```

应该是 403——token 上只有 `default`，没有 `eng-policy`。

## 4.3 给 alice-real 这个 entity 挂上 eng-policy

这一步要触发的状态变化（注意 token 完全不变）：

```
  Token hvs.xxx ──→ entity_id=ent-alice-real ──→ Entity alice-real
  policies=[default]   (token 字段未动)         policies=[eng-policy]  ← 新挂
         │                                              │
         ↓                                              ↓
  capabilities = [default]  ∪  [eng-policy]
                              ↓
           secret/data/eng-only 上 read 命中 eng-policy → 200
```

```bash
ENT_REAL=$(vault read -format=json identity/entity/name/alice-real | jq -r .data.id)

vault write identity/entity/id/$ENT_REAL \
  name=alice-real \
  policies=eng-policy
```

注意——**alice 没有重新登录**，她手里的 `$ALICE_TOKEN` 还是同一条。
立刻再读一次：

```bash
echo "alice 不重登就立刻再试:"
VAULT_TOKEN=$ALICE_TOKEN vault kv get secret/eng-only
```

成功！这就是文档说的"at request time"——Vault 在每次 API 请求时实时
查 entity policy 并叠加进去。

可以再用 `vault token lookup`（不带参数 = 查自身）看看，token 上
`policies` 字段**仍然只显示 `default`**——这非常重要：

```bash
VAULT_TOKEN=$ALICE_TOKEN vault token lookup -format=json \
  | jq -r '.data.policies | join(",")'
```

> **token 上写死的 policies 永远不变**，但实际生效的是
> token policies ∪ entity policies ∪ group policies——只能通过
> `vault token capabilities` 或实际请求才能观测到。

## 4.4 摘掉 entity policy，立刻失能

反向操作。此时 4.2 的"断开"格局又回来了：

```
  Token hvs.xxx ──→ Entity alice-real
  policies=[default]   policies=[]    ← 又被清空
         │                   │
         ↓                   ↓
  capabilities = [default]  → 再读 eng-only 就回到 403
         ↑
   token 自身没动过；entity 一改，下一次请求就生效
```

```bash
vault write identity/entity/id/$ENT_REAL \
  name=alice-real \
  policies=

echo "alice 不重登就立刻再试:"
VAULT_TOKEN=$ALICE_TOKEN vault kv get secret/eng-only 2>&1 | tail -3
```

回到 403——撤权也是即时生效。

## 4.5 验证 §5.2："entity policy 只能加，不能减"

这一步要展示的反直觉点——entity policy 是**并集**，不是交集，所以
往 entity 上挂 deny 完全压不住 token 自身的权限：

```
  Token  policies=[X]  ──┐
                          ├──→  capabilities = X ∪ Y
  Entity policies=[Y]  ──┘

          想用 entity 的 "deny" 压住 token 的 "read"？
          不可能 ── 并集里只要有一个 allow 就 allow
          唯一减权方式：让 token 重新签发，把 X 自己缩小
```

写一条**拒绝**读 secret/* 的 policy：

```bash
vault policy write deny-secret - <<'EOF'
path "secret/data/*" {
  capabilities = ["deny"]
}
EOF
```

试图通过 entity policy 把 alice 上 token 自带的 default policy "降权"：

```bash
vault write identity/entity/id/$ENT_REAL \
  name=alice-real \
  policies=deny-secret
```

但 alice 的 token 本来就不能读 eng-only（default 没这个权限），看
不出"加 vs 减"的差别。换个例子——**用 root token 验证 entity policy
完全无法限制 root**：

```bash
echo "root token 自身能读:"
vault kv get secret/eng-only | grep message
```

document 强调的"只加不减"含义是：**给 token 上原本有的权限加 deny
policy 到 entity 上，token 仍然能用原权限**——因为 entity policy 是
并集（union），不是交集（intersection）。要降 alice 的权，**必须 revoke
她的 token 让她重登**，让新 token 上的 policies 字段本身缩小。

收尾——把 entity policy 清空：

```bash
vault write identity/entity/id/$ENT_REAL name=alice-real policies=
```

**这一步的核心结论**：

| 操作 | 实时生效？ | 原因 |
| --- | --- | --- |
| 给 entity **加** policy | ✅ 立即 | 请求时实时求并集 |
| 从 entity **摘** policy | ✅ 立即 | 请求时实时求并集 |
| 用 entity policy **降低** token 自带的权限 | ❌ 不行 | 并集不是交集，必须 revoke token |
| 让用户彻底失去某个权限 | revoke token + 改 entity policy | token 上写死的 policies 撤不了 |

记住这条非对称：**加权用 entity（即时），减权必须 token revoke
（撞 TTL 或显式 revoke）**。
