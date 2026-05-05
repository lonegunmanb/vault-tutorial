# 第一步：启用和调优认证方法挂载点

先查看当前启用的认证方法。dev server 默认会有 `token/`，它是 Vault 的基础认证后端。

```bash
vault auth list
```

在启用一个新认证方法前，可以先看该类型的登录帮助。这里使用 `userpass`，因为它最适合在教学环境中观察用户名、密码与 token 的关系。

```bash
vault auth help userpass | head -20
```

把 `userpass` 挂载到自定义路径 `staff/`。注意这里的路径最终对应 API 前缀 `auth/staff/`。

```bash
vault auth enable -path=staff -description="Training user login" userpass
```

对这个挂载点调优：把默认 TTL 设为 30 分钟，最大 TTL 设为 2 小时，并启用一个较小的用户锁定阈值用于观察配置项。

```bash
vault auth tune \
  -default-lease-ttl=30m \
  -max-lease-ttl=2h \
  -user-lockout-threshold=5 \
  -user-lockout-duration=10m \
  staff/
```

查看详细列表和 tune 配置，确认 `staff/` 已经是一个独立的认证方法挂载点。

```bash
vault auth list -detailed | grep -E 'Path|staff/'
vault read sys/auth/staff/tune | grep -E 'default_lease_ttl|max_lease_ttl|user_lockout'
```

最后创建两个教学用户：`alice` 能读取 `secret/app/config`，`bob` 只有默认权限。

```bash
vault write auth/staff/users/alice password="wonderland" token_policies="app-read" token_ttl=20m
vault write auth/staff/users/bob password="builder" token_policies="default" token_ttl=20m
```

这一阶段的关键点是：`vault auth ...` 管理的是“登录入口”，还没有真正让任何人登录。
