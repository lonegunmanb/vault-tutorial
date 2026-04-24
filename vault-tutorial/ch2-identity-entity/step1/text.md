# 第一步：隐式 Entity 与 Alias

文档 §3 的核心论断：

> When a client authenticates via any credential backend (except the
> Token backend), Vault creates a new entity. It attaches a new alias
> to it if a corresponding entity does not already exist.

我们用 userpass 让 alice 登一次，看看 Vault 在背后默默建了什么。

## 1.1 启用 userpass、创建用户、登录

```bash
vault auth enable userpass

vault write auth/userpass/users/alice \
  password=s3cr3t \
  token_policies=default

vault login -format=json -method=userpass username=alice password=s3cr3t \
  > /root/alice-login.json
```

抓出 token 上的 `entity_id`：

```bash
ENT_ID=$(jq -r .auth.entity_id /root/alice-login.json)
echo "alice 这次登录拿到的 token 上 entity_id = $ENT_ID"
```

注意——alice 还**完全没碰过 identity 子系统**，但 `entity_id` 已经
有了。这就是文档说的"非 token auth method 一登录就隐式建 entity"。

## 1.2 看看 Vault 自动建出来的 Entity

```bash
vault read identity/entity/id/$ENT_ID
```

注意几个关键字段：

- `aliases` 数组里有一条，`name = alice`，`mount_type = userpass`
- `policies` 是空的——Vault 不会替你猜该挂什么 policy，需要管理员显式挂
- `metadata` 是 `<nil>`——同样需要管理员或外部 IdP 同步系统填

## 1.3 看看自动建出来的 Alias

把 alias_id 拿出来：

```bash
ALIAS_ID=$(vault read -format=json identity/entity/id/$ENT_ID \
  | jq -r '.data.aliases[0].id')

vault read identity/entity-alias/id/$ALIAS_ID
```

注意 `mount_accessor` 字段——这就是文档 §2.1 说的"alias 唯一键的另一半"：

```bash
USERPASS_ACC=$(vault auth list -format=json | jq -r '."userpass/".accessor')
echo "userpass mount 的 accessor = $USERPASS_ACC"
echo "alias 上记录的 mount_accessor   = $(vault read -format=json identity/entity-alias/id/$ALIAS_ID | jq -r .data.mount_accessor)"
```

两者必须一致——这正是 Vault 内部把"哪个 mount 上的 alice"区分开的方式。

## 1.4 列出整个 Identity Store

```bash
echo "所有 entity:"
vault list identity/entity/id

echo ""
echo "所有 alias:"
vault list identity/entity-alias/id
```

各 1 条——alice 的隐式 entity 和它的 userpass alias。

**这一步的核心结论**：你不需要主动管理 Entity，只要有人登录过 Vault
就**自动**有了它的"持久身份记录"。Entity 只是一个 ID + 一组 alias 的
集合，**它本身完全不能鉴权**——鉴权依旧靠 2.4 章节里的 token。Identity
做的是"在 token 之外另开一条持久身份的副线"。
