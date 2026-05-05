# 第四步：改密码、改 policy、验证小写归一化并清理

![Step 4 故事板：维护本地用户登记册](../assets/step4-userpass-maintenance-story.png)

userpass API 为维护动作提供了独立端点：改密码、改 policies、删除用户、列出用户都不是同一个语义。

## 4.1 更新 alice 密码

```bash
vault write auth/userpass/users/alice/password password="new-alice-pass"
```

旧密码现在应无法登录，新密码可以登录。

```bash
vault login -method=userpass username=alice password=alice-pass

vault login -method=userpass username=alice password=new-alice-pass
```

## 4.2 更新 bob 的 policies

```bash
vault write auth/userpass/users/bob/policies token_policies="team-reader"

vault login -method=userpass username=bob password=bob-pass -format=json | jq '.auth.token_policies'
```

这个更新影响后续新登录签发出来的 token policies。

## 4.3 验证用户名小写归一化

```bash
vault login -method=userpass username=MARY password=mary-pass -format=json | jq '.auth.metadata'
vault login -method=userpass username=mary password=mary-pass -format=json | jq '.auth.metadata'
```

官方文档说明，提交的用户名会小写化，所以 `MARY` 和 `mary` 会命中同一个用户条目。

## 4.4 删除用户并清理 auth method

```bash
vault delete auth/userpass/users/alice
vault delete auth/userpass/users/bob
vault delete auth/userpass/users/mary
vault auth disable userpass
```

删除用户会移除这个用户名条目；禁用 auth method 会清理整个 `auth/userpass` mount。

## 4.5 这一步的核心闭环

userpass 是本地、直接、低依赖的用户名密码 auth method；它的简单性来自“用户就在 Vault auth method 内部”，也意味着你要自己负责这些用户的生命周期和安全边界。