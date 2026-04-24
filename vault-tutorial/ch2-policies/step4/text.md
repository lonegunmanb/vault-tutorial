# 第四步：Templated Policy — 一份 policy 服务全员

step3 的 self-pwd 把 `alice` 写死了——alice 之外的用户用不了。这一
步用 templated policy 让同一份 policy 自动适配每个登录的用户。

要搭起来的鉴权图：

```
   ┌──── Policy: self-kv ────────────────────────────────────┐
   │ path "secret/data/{{identity.entity.id}}/*" {           │
   │   capabilities = [create,read,update,delete]            │
   │ }                                                       │
   └──────────────────────────────────────────────────────────┘
                       │
       请求时把 {{identity.entity.id}} 替换成持有 token 的 entity ID
                       │
       ┌───────────────┴───────────────┐
       ▼                               ▼
   alice 的 token              bob 的 token
   entity_id=ent-AAA           entity_id=ent-BBB
   解出 secret/data/ent-AAA/*  解出 secret/data/ent-BBB/*
   只能动自己子目录             只能动自己子目录
```

## 4.1 准备 alice / bob 两个用户

```bash
# step3 已经 enable 了 userpass，alice 也建了。这里建 bob。
vault write auth/userpass/users/bob password=bobpwd token_policies=default
```

让两人都登录一次，让 Vault 自动建 entity（参考 2.5 章节）：

```bash
ALICE=$(vault login -format=json -method=userpass username=alice password=newpwd \
  | jq -r .auth.client_token)
ALICE_ENT=$(VAULT_TOKEN=$ALICE vault token lookup -format=json | jq -r .data.entity_id)

BOB=$(vault login -format=json -method=userpass username=bob password=bobpwd \
  | jq -r .auth.client_token)
BOB_ENT=$(VAULT_TOKEN=$BOB vault token lookup -format=json | jq -r .data.entity_id)

echo "alice entity_id = $ALICE_ENT"
echo "bob   entity_id = $BOB_ENT"
```

## 4.2 写一份 templated policy

```bash
vault policy write self-kv - <<'EOF'
# 每个 entity 自己的子目录，能 CRUD
path "secret/data/{{identity.entity.id}}/*" {
  capabilities = ["create", "read", "update", "delete", "patch"]
}
# 能 list 自己子目录下有什么 key
path "secret/metadata/{{identity.entity.id}}/*" {
  capabilities = ["list"]
}
EOF
```

把这条 policy 挂给所有 userpass 用户：

```bash
vault write auth/userpass/users/alice token_policies=default,self-kv
vault write auth/userpass/users/bob   token_policies=default,self-kv
```

## 4.3 alice 重新登录，往自己子目录写数据

```bash
ALICE=$(vault login -format=json -method=userpass username=alice password=newpwd \
  | jq -r .auth.client_token)

VAULT_TOKEN=$ALICE vault kv put secret/$ALICE_ENT/note message="alice's diary"
echo ""
echo "alice 读自己子目录:"
VAULT_TOKEN=$ALICE vault kv get secret/$ALICE_ENT/note | grep message
```

## 4.4 alice 试图读 bob 的子目录

```bash
echo "alice 试图读 bob 的子目录（应失败 - templated path 解出来不匹配）:"
VAULT_TOKEN=$ALICE vault kv get secret/$BOB_ENT/note 2>&1 | tail -3
```

403 — `{{identity.entity.id}}` 在 alice 的请求里被替换成了
`$ALICE_ENT`，policy 解出来的实际允许路径是 `secret/data/$ALICE_ENT/*`，
完全不匹配 bob 的子目录。**一份 policy 替每个 entity 各自圈了一片地**。

## 4.5 bob 重复一遍——验证完全对称

```bash
BOB=$(vault login -format=json -method=userpass username=bob password=bobpwd \
  | jq -r .auth.client_token)

VAULT_TOKEN=$BOB vault kv put secret/$BOB_ENT/note message="bob's todo"

echo "bob 读自己（应成功）:"
VAULT_TOKEN=$BOB vault kv get secret/$BOB_ENT/note | grep message

echo ""
echo "bob 试图读 alice（应失败）:"
VAULT_TOKEN=$BOB vault kv get secret/$ALICE_ENT/note 2>&1 | tail -3
```

## 4.6 进阶——用 alias.name 把 username 拼进 path

文档 §4.1 还推荐了一种更直观的做法：用 alias name（这里就是 username）
拼到 path 里，让目录名可读。需要先拿到 userpass mount 的 accessor：

```bash
USERPASS_ACC=$(vault auth list -format=json | jq -r '."userpass/".accessor')
echo "userpass mount accessor = $USERPASS_ACC"
```

写一份按 username 划分子目录的 policy：

```bash
vault policy write self-kv-by-name - <<EOF
path "secret/data/users/{{identity.entity.aliases.${USERPASS_ACC}.name}}/*" {
  capabilities = ["create", "read", "update", "delete", "patch"]
}
path "secret/metadata/users/{{identity.entity.aliases.${USERPASS_ACC}.name}}/*" {
  capabilities = ["list"]
}
EOF

vault write auth/userpass/users/alice token_policies=default,self-kv,self-kv-by-name

ALICE=$(vault login -format=json -method=userpass username=alice password=newpwd \
  | jq -r .auth.client_token)

VAULT_TOKEN=$ALICE vault kv put secret/users/alice/preference theme=dark
VAULT_TOKEN=$ALICE vault kv get secret/users/alice/preference | grep theme

echo "alice 试图访问 secret/users/bob/* （应失败）:"
VAULT_TOKEN=$ALICE vault kv get secret/users/bob/preference 2>&1 | tail -3
```

> **重要权衡** — 文档自己强调："use IDs wherever possible. Each ID
> is unique to the user, whereas names can change over time and can be
> reused."
>
> 用 `entity.id` 安全但 path 难看；用 `alias.name` 直观但**用户改名/
> 重新创建后 path 不变更**——可能让新人继承到老数据。生产里**对
> 真实数据**优先用 ID，**对调试 / 临时目录**可以用 name。

**这一步的核心结论**：

| 模板变量 | 优势 | 风险 |
| --- | --- | --- |
| `{{identity.entity.id}}` | 永不变，绝对唯一 | path 难读，调试不直观 |
| `{{identity.entity.aliases.<acc>.name}}` | 路径可读 | username 改/复用会带来权限继承 |
| `{{identity.entity.metadata.<key>}}` | 灵活，可挂业务字段 | 依赖 entity metadata 同步机制 |
| `{{identity.groups.ids.<gid>.name}}` | 按组分目录 | 同 ID 优先原则 |

无论用哪个变量——**一份 policy 自动适配 N 个用户**，这就是 templated
policy 在大规模治理里取代"按人写 policy"的关键能力。
