# 第一步：默认挂载 + 三不允许 + Entity / Alias / Group CRUD

文档对 `identity/` 引擎的定位是：

> This secrets engine will be mounted by default. This secrets engine
> cannot be disabled or moved.

我们先把这条"内置且锁死"亲手撞一遍——和 [3.4 Cubbyhole](/ch3-cubbyhole)
那一节是同一个套路（不过 identity 比 cubbyhole 略松一点：tune 是
允许的）。然后立刻进入它的真正用途：**身份对象 CRUD**。

## 1.1 它已经在那儿了

```bash
vault secrets list | grep -E "Path|identity"
```

你会看到一行 `identity/`，类型也叫 `identity`。这是 Vault 启动时就
挂好的。

详情：

```bash
vault read sys/mounts/identity
```

留意 `local` / `seal_wrap` / `uuid`——和 cubbyhole 一样是内置单例。

## 1.2 撞一遍"三不允许"

**禁令一：不能 disable**

```bash
vault secrets disable identity/
```

会拿到类似 `cannot unmount "identity/"` 的硬拒。原因和 cubbyhole 一样
——禁掉它会击穿整个 Vault 的身份层（所有 Entity / Group / OIDC key
全爆掉）。

**禁令二：不能 move**

```bash
vault secrets move identity/ id/
```

`cannot remount "identity/"`——很多内部代码硬编码了 `identity/oidc/...`
等系统路径，搬走立刻全断。

**禁令三：不能再次 enable**

```bash
vault secrets enable -path=id identity
```

`mount type of "identity" is not mountable`——和 cubbyhole 一样，
identity 是单例引擎，多挂一份既无意义也会冲突。

> 顺带一提：`vault secrets tune identity/` 是**允许**的（这一点和
> cubbyhole 不同）。比如 `vault secrets tune -default-lease-ttl=10m identity/`
> 会成功——只是 identity 自己几乎不签发带 TTL 的 lease，所以调它的
> 默认 lease TTL 实际意义不大。真正不能动的是 disable / move /
> 再挂一份这三件事。

## 1.3 Entity CRUD

最简洁的 Entity 创建：

```bash
ALICE_EID=$(vault write -format=json identity/entity \
  name="alice" \
  metadata=department="platform" \
  metadata=cost_center="eng-001" \
  | jq -r .data.id)

echo "ALICE_EID=$ALICE_EID"
```

按 ID 查回来：

```bash
vault read identity/entity/id/$ALICE_EID
```

按 name 查（同样有效）：

```bash
vault read identity/entity/name/alice
```

## 1.4 Alias：把 Entity 绑到一个具体的 auth mount

先开两个 auth method（演示"跨 mount 归并"）：

```bash
vault auth enable userpass
vault auth enable -path=userpass2 userpass
```

拿出两个 mount 的 **accessor**（不是 path！alias 必须用 accessor）：

```bash
USERPASS_ACCESSOR=$(vault auth list -format=json | jq -r '."userpass/".accessor')
USERPASS2_ACCESSOR=$(vault auth list -format=json | jq -r '."userpass2/".accessor')
echo "USERPASS_ACCESSOR=$USERPASS_ACCESSOR"
echo "USERPASS2_ACCESSOR=$USERPASS2_ACCESSOR"
```

把同一个 alice 在两个 mount 上的"分身"都挂到 `$ALICE_EID` 这一个
Entity 上：

```bash
vault write identity/entity-alias \
  name="alice" \
  canonical_id="$ALICE_EID" \
  mount_accessor="$USERPASS_ACCESSOR"

vault write identity/entity-alias \
  name="alice" \
  canonical_id="$ALICE_EID" \
  mount_accessor="$USERPASS2_ACCESSOR"
```

现在再读一次 Entity，能看到它有 **两个 alias**：

```bash
vault read -format=json identity/entity/id/$ALICE_EID | jq '.data.aliases | map({mount_path, name})'
```

输出大致：

```json
[
  {"mount_path": "auth/userpass/",  "name": "alice"},
  {"mount_path": "auth/userpass2/", "name": "alice"}
]
```

**这就是身份归并**：将来 alice 用 userpass 或 userpass2 任一登录，
Vault 都把她解析到同一个 Entity（同一个 ID、同一份 metadata、同一组
策略），而不是两个孤立的"alice"。

> 反过来想验证"忘记 mount_accessor 会失败"，可以试试：
> ```bash
> vault write identity/entity-alias name="alice" canonical_id="$ALICE_EID"
> ```
> Vault 会拒绝——alias 必须能定位到一个具体的 auth mount。

## 1.5 Group：把多个 Entity 集合在一起

```bash
# 再建一个 entity 当组员
BOB_EID=$(vault write -format=json identity/entity name="bob" | jq -r .data.id)

# 创建 internal group，把 alice 和 bob 都塞进去
vault write identity/group \
  name="platform-team" \
  type="internal" \
  member_entity_ids="$ALICE_EID,$BOB_EID"

vault read identity/group/name/platform-team
```

查询 alice 当前的所属组：

```bash
vault read -format=json identity/entity/id/$ALICE_EID | jq '.data.group_ids'
```

> External group（`type=external`）不能直接塞 `member_entity_ids`，
> 它的成员关系完全由外部 IdP 在登录时由 alias 自动写入——常见用法
> 是把 LDAP `memberOf` 或 OIDC `groups` claim 映射进来。本实验为简
> 化只演示 internal group。

## 1.6 顺手验证 lookup

调试归并时最常用的两条 API：

```bash
# 用 alias 反查 Entity
vault write identity/lookup/entity \
  alias_name="alice" \
  alias_mount_accessor="$USERPASS_ACCESSOR" \
  | grep -E "id|name "

# 同屏打印 ALICE_EID 方便肉眼比对
echo "ALICE_EID=$ALICE_EID"
```

返回的 `id` 和 `$ALICE_EID` 一致——证明 §1.4 的归并真的生效了。

---

> Step 2 把 §3 的 Identity Tokens 链路从 0 搭起来：建 key、建 role、
> 签 JWT、双重验证。
