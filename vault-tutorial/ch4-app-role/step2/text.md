# 第二步：bind_secret_id 与 secret_id_num_uses=1

[4.2 章 §4.2](/ch4-app-role) 解释过：`role_id` 是登录端点的硬性必填
参数；`role_id` 指向的 role 上还可以挂各种**约束**，决定还需要带什
么、满足什么条件才能拿 token。`bind_secret_id` 是默认开启的那个最常
见约束。

[4.2 章 §5](/ch4-app-role) 同时讲过 SecretID 自己的两道安全装置：
**Binding CIDRs** 和 **Response Wrapping**。`secret_id_num_uses` 还
不属于这两道装置，但 best-practices 文档里有一段专门提到 _"For best
security, set `secret_id_num_uses` to `1` use."_——这一步把两个字段
都设上去，亲手验证一次"用完即焚"。

## 2.1 把约束加到既有 role 上

注意：`vault write auth/approle/role/<role>` 是**全量更新**——你 step
1 里写的所有字段，在这条命令里没出现的都会被重置成默认值。所以这次
要把 step 1 的字段全部带上，再额外加 `secret_id_num_uses=1`：

```bash
vault write auth/approle/role/my-role \
    token_type=batch \
    bind_secret_id=true \
    secret_id_ttl=10m \
    token_ttl=20m \
    token_max_ttl=30m \
    secret_id_num_uses=1
```

> `bind_secret_id=true` 其实就是默认值，这里**显式写出来**让 role 配
> 置自描述。看一眼现在的 role 配置：
>
> ```bash
> vault read auth/approle/role/my-role
> ```
>
> 应该看到 `bind_secret_id` `true` 和 `secret_id_num_uses` `1` 这两
> 行。

## 2.2 取一个新 SecretID（这次只能用 1 次）

老 SecretID 是按老 role 配置发的（40 次），仍然有效——但我们这次要
验证新约束，所以取个新的：

```bash
ROLE_ID=$(vault read -field=role_id auth/approle/role/my-role/role-id)
SECRET_ID=$(vault write -f -field=secret_id auth/approle/role/my-role/secret-id)
echo "新 SECRET_ID=$SECRET_ID"
```

返回里 `secret_id_num_uses` 应该是 `1`。

## 2.3 第一次登录：成功

```bash
vault write auth/approle/login \
    role_id=$ROLE_ID \
    secret_id=$SECRET_ID
```

看到 token 输出——成功，跟 step 1 一样。

## 2.4 第二次登录：用同一个 SecretID 立刻被拒

紧接着再敲一次完全相同的命令——SecretID 没换，但它的 `num_uses` 已
经被消费完了：

```bash
vault write auth/approle/login \
    role_id=$ROLE_ID \
    secret_id=$SECRET_ID
```

会立刻报错：

```
Error writing data to auth/approle/login: Error making API request.

URL: PUT http://127.0.0.1:8200/v1/auth/approle/login
Code: 400. Errors:

* invalid secret id
```

> `invalid secret id` 是 Vault 故意给的"模糊"错误——它**不会告诉你
> 到底是 SecretID 不存在、过期了、还是被用完了**，因为这些信息会让
> 攻击者反推 SecretID 是否存在。任何"密码"型字段被拒，都建议给一致
> 的错误消息——这是 Vault 在 API 层的标准做法。

## 2.5 关掉 bind_secret_id 试试纯 RoleID 登录

把 `bind_secret_id` 关掉，role 退化成"知道 RoleID 就能登"的状态。注
意：[4.2 章 §4.2](/ch4-app-role) 说这只在配合**其它约束**（比如 CIDR）
时才是合理设计——单独关掉等于把 SecretID 整个机制白送。我们这里只
做演示。

```bash
vault write auth/approle/role/my-role \
    token_type=batch \
    bind_secret_id=false \
    token_ttl=20m \
    token_max_ttl=30m
```

只用 RoleID 登录：

```bash
vault write auth/approle/login role_id=$ROLE_ID
```

竟然成功了——返回里有 token。这就是 `bind_secret_id=false` 的字面
意思：登录端点不再要求 `secret_id` 参数。

> **这个状态生产环境绝对不要用**——任何能拿到 RoleID（一个不被当作
> 机密的 UUID）的人都能换出 token。`bind_secret_id=false` 只在一个
> 场景下合理：和 `secret_id_bound_cidrs` 严格组合，让"只有来自指定
> IP 段的客户端"才能换 token——也就是把"我是谁"的证明从 SecretID 转
> 移到 IP 地址上。Step 3 会演示这个组合。

## 2.6 把 bind_secret_id 改回去，role 复位

```bash
vault write auth/approle/role/my-role \
    token_type=batch \
    bind_secret_id=true \
    secret_id_ttl=10m \
    token_ttl=20m \
    token_max_ttl=30m \
    secret_id_num_uses=1
```

为下一步准备。下一步给 role 加 CIDR 约束，看 Vault 端在哪一层拦不
合规来源。
