# 第五步：Identity Group 与子组继承

文档 §6 的核心论断：

> Policies set on the group are granted to all members of the group.
> ... if a GroupA has GroupB as subgroup, then members of GroupB are
> indirect members of GroupA.

也就是说——把 entity 加到 group 里、把 group 设为另一个 group 的子
组，policy 都会沿这条链路自动传递。我们建一棵两层组结构来验证。

## 5.1 准备两条 policy

```bash
vault policy write eng-policy - <<'EOF'
path "secret/data/eng-only" {
  capabilities = ["read"]
}
EOF

vault policy write company-policy - <<'EOF'
path "secret/data/company-info" {
  capabilities = ["read"]
}
EOF

vault kv put secret/eng-only message="hello-from-eng"
vault kv put secret/company-info message="hello-from-company"
```

## 5.2 创建 engineering 组并把 alice 加进去

```bash
ENT_REAL=$(vault read -format=json identity/entity/name/alice-real | jq -r .data.id)
echo "alice-real entity_id = $ENT_REAL"

vault write identity/group \
  name=engineering \
  policies=eng-policy \
  member_entity_ids=$ENT_REAL

ENG_GROUP=$(vault read -format=json identity/group/name/engineering | jq -r .data.id)
echo "engineering group_id = $ENG_GROUP"
```

alice 重新登录拿一个新 token，**不需要在 entity 上挂任何 policy**：

```bash
ALICE_TOKEN=$(vault login -format=json -method=userpass \
  username=alice password=s3cr3t | jq -r .auth.client_token)

echo "alice 试图读 secret/eng-only（应该成功）:"
VAULT_TOKEN=$ALICE_TOKEN vault kv get secret/eng-only | grep message

echo "alice 试图读 secret/company-info（应该 403）:"
VAULT_TOKEN=$ALICE_TOKEN vault kv get secret/company-info 2>&1 | tail -3
```

eng-only 通了——alice 的 entity 自身没挂 policy，但**因为是
engineering 组的成员，自动继承 eng-policy**。company-info 还没法读，
因为 company-policy 还没挂到任何能链接到 alice 的地方。

## 5.3 建父组 company，把 engineering 设为子组

```bash
vault write identity/group \
  name=company \
  policies=company-policy \
  member_group_ids=$ENG_GROUP
```

注意——**alice 既没有被显式加到 company 组，也没碰任何 token / entity**，
但因为她是 engineering 的成员，而 engineering 是 company 的子组，所以
她自动成为 company 的"间接成员"。

不重登就立刻再试 company-info：

```bash
echo "alice 不重登就再读 secret/company-info:"
VAULT_TOKEN=$ALICE_TOKEN vault kv get secret/company-info | grep message
```

成功——这就是文档 §6.2 说的"indirect membership 沿子组继承"。和
step4 一样，这次也不需要重登：group policy 同样是请求时动态求值。

## 5.4 用 capabilities API 看清最终生效的策略集合

```bash
echo "alice token 在 secret/data/eng-only 上的 capabilities:"
VAULT_TOKEN=$ALICE_TOKEN vault token capabilities secret/data/eng-only

echo "alice token 在 secret/data/company-info 上的 capabilities:"
VAULT_TOKEN=$ALICE_TOKEN vault token capabilities secret/data/company-info

echo "alice token 自己的 policies 字段（永远只是登录时冻结的那一份）:"
VAULT_TOKEN=$ALICE_TOKEN vault token lookup -format=json \
  | jq -r '.data.policies | join(",")'
```

注意 token 自己的 policies 字段一直是 `default` ——但实际权限远超
default，因为 entity / group policy 都在请求时叠加进来。这就是文档
§5.1 那个范式转移的最终效果。

## 5.5 演示外部组的"半自动"特性（概念性）

外部组需要 LDAP / OIDC / GitHub 等真实外部 IdP 才能完整验证。这里
只解释关键差异——查文档 §6.3：

| | 内部组 | 外部组 |
| --- | --- | --- |
| 创建参数 | `type=internal`（默认） | `type=external` |
| 成员变更方式 | 手动改 `member_entity_ids` | 必须挂一条 group-alias 指向外部 IdP 的某个组；用户 login/renew 时**自动同步** |
| 关键陷阱 | 无 | **外部 IdP 把用户踢出组之后，用户在 Vault 这边仍然是组成员，直到他下次 login/renew** |

实操路径（仅看命令，不真的执行——我们这里没有 LDAP）：

```bash
# 假装下面这条命令在真实 LDAP 接入环境里：
# vault write identity/group \
#   name=ldap-eng \
#   type=external \
#   policies=eng-policy
#
# vault write identity/group-alias \
#   name="cn=engineering,ou=groups,dc=corp,dc=com" \
#   mount_accessor=$LDAP_MOUNT_ACCESSOR \
#   canonical_id=$EXTERNAL_GROUP_ID
echo "这里只是示例命令，dev 环境没有 LDAP，跳过执行"
```

**这一步的核心结论**：

```
最终 capabilities = policies(token)
                  ∪ policies(entity[entity_id])
                  ∪ policies(directly-member groups)
                  ∪ policies(transitively-member groups via subgroup chain)
```

实际企业大规模治理时，按层次划组（公司 → 部门 → 团队），策略只在
对应层级挂一份，所有员工通过 entity 自动沿组链路继承——这就避免了
"按个人挂策略"的爆炸式维护成本。
