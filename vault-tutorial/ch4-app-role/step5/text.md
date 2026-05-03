# 第五步：反模式对照与清理

[4.2 章 §8](/ch4-app-role) 列了三种 trusted broker 模式下常见的反模
式。这一步把它们和 step 4 的正确范式并排敲一次——目的是让你**手指
记住**两边的差别。

## 5.1 反模式 A：worker 自己取机密、把机密本身传给 runner

参考 [4.2 章 §8.1](/ch4-app-role)。

如果给 worker 配的策略是这种"能直接取所有应用机密"的大 policy：

```bash
vault policy write bad-broker-A - <<EOF
path "kv/data/my-role_secrets/*" {
  capabilities = [ "read" ]
}
# 还会随着新增 role 越来越胀：
# path "kv/data/role-2_secrets/*" { ... }
# path "kv/data/role-3_secrets/*" { ... }
EOF

BAD_BROKER_A_TOKEN=$(vault token create -policy=bad-broker-A -ttl=1h -field=token)
```

worker 直接用这枚 token 取机密：

```bash
VAULT_TOKEN=$BAD_BROKER_A_TOKEN vault kv get kv/my-role_secrets/app1
```

返回 `password   real-secret-pwd-xyz`——能成功取到。

**问题**：

1. worker **本身不是这条机密的最终消费者**——它只是个调度系统
2. 一旦 worker 被攻陷，所有它有权限读的机密都被一次性泄漏
3. 审计日志里这次读取的"身份"是 broker token，**与具体的某个 runner
   无法关联**——破窗之后没法做"撤销那一个被盗身份"

直接对应 [4.2 章 §1](/ch4-app-role) 引的 _Blast-radius of an
identity_ 原则被破坏。

## 5.2 反模式 B：worker 把 RoleID 和 SecretID 一起递给 runner

参考 [4.2 章 §8.2](/ch4-app-role)。

策略允许 worker 直接读裸 SecretID（**没有** `min_wrapping_ttl` 那
道防线）：

```bash
vault policy write bad-broker-B - <<EOF
path "auth/approle/role/+/role-id" {
  capabilities = [ "read" ]
}
path "auth/approle/role/+/secret-id" {
  capabilities = [ "create", "read", "update" ]
}
EOF

BAD_BROKER_B_TOKEN=$(vault token create -policy=bad-broker-B -ttl=1h -field=token)
```

worker 直接取裸 SecretID + RoleID 然后递给 runner：

```bash
ROLE_ID_BAD=$(VAULT_TOKEN=$BAD_BROKER_B_TOKEN vault read -field=role_id \
    auth/approle/role/my-role/role-id)
SECRET_ID_BAD=$(VAULT_TOKEN=$BAD_BROKER_B_TOKEN vault write -f -field=secret_id \
    auth/approle/role/my-role/secret-id)

echo "worker 现在两半都拿到了："
echo "  ROLE_ID=$ROLE_ID_BAD"
echo "  SECRET_ID=$SECRET_ID_BAD"
```

worker 自己当然也能登录拿应用的 token：

```bash
VAULT_TOKEN=$(vault write -field=token auth/approle/login \
    role_id=$ROLE_ID_BAD \
    secret_id=$SECRET_ID_BAD) vault kv get kv/my-role_secrets/app1
```

**问题**：worker 同时拿到两半——攻破 worker = 攻破所有 runner。
[4.2 章 §1](/ch4-app-role) 那条 "RoleID 和 SecretID 唯一可同时出现的
位置就是最终客户端" 的中心原则被破坏。

> 与 §5.1 反模式 A 比，B 这种"看起来 worker 没接触机密本身"的写法**
> 更隐蔽**——但实际安全后果一模一样。

## 5.3 反模式 C：worker 给 runner 派"代签"的子 token

参考 [4.2 章 §8.3](/ch4-app-role)。

把 worker 配成有"创建子 token + 任意 policy"的能力：

```bash
vault policy write bad-broker-C - <<EOF
path "auth/token/create" {
  capabilities = [ "create", "update", "sudo" ]
}
EOF

BAD_BROKER_C_TOKEN=$(vault token create -policy=bad-broker-C -ttl=1h -field=token)
```

worker 直接给 runner 派子 token：

```bash
CHILD_TOKEN=$(VAULT_TOKEN=$BAD_BROKER_C_TOKEN vault token create \
    -policy=app-read-policy -ttl=10m -field=token)

VAULT_TOKEN=$CHILD_TOKEN vault kv get kv/my-role_secrets/app1
```

成功取到机密。

**问题**：worker 现在能**任意签发**带 `app-read-policy` 的子 token。
攻破 worker 一样意味着可以源源不断地刷出能取机密的 token——和 B
本质等价，比 B 更隐蔽因为没有"两半凭据"那种显眼信号。

## 5.4 三种反模式与推荐范式的对照

| 模式 | broker 拥有什么 | runner 拥有什么 | 攻陷 broker 的后果 |
| :--- | :--- | :--- | :--- |
| **推荐**（step 4） | 仅能换 wrapped SecretID | RoleID + SecretID + 应用 token | 攻击者只能在 100-300s 窗口里偷一枚 wrapping token，且会被合法 runner 立刻识破 |
| **反 A**（§5.1） | 全部应用机密的明文权限 | 机密的明文 | 所有走过这个 broker 的应用机密一次性泄漏 |
| **反 B**（§5.2） | RoleID + SecretID | RoleID + SecretID | 攻击者可任意以 runner 身份登录取所有机密 |
| **反 C**（§5.3） | 任意签发子 token 的能力 | 子 token | 攻击者可源源不断刷子 token 取机密 |

## 5.5 清理

把这一节加出来的所有"坏"策略清理掉，role / 机密保留供回顾：

```bash
vault policy delete bad-broker-A
vault policy delete bad-broker-B
vault policy delete bad-broker-C
```

如果想把整个 approle 关掉（把这套实验从 Vault 上清掉）：

```bash
# 关掉 approle 认证方法 = 撤掉所有它签出来的 token + 删掉所有 role 配置
vault auth disable approle

# 关掉 KV 引擎
vault secrets disable kv

# 删 step 4 留下的应用读策略 + broker 策略
vault policy delete app-read-policy
vault policy delete broker-policy
```

> 注意：[4.1 章](/ch4-auth-basic) 那张表里讲过的 "禁用一个 Auth
> Method = 批量登出所有通过它登录的 Token" 在这里直接见效——执行
> `vault auth disable approle` 会把 step 4 里 runner 拿到的应用
> token 一并失效（哪怕它还没到 TTL）。

实验完成。
