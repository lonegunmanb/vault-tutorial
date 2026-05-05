# 第五步：禁用 auth method 触发批量撤销

最后观察 `vault auth disable` 的影响。先让 `bob` 再登录一次，得到一枚由 `staff/` 认证方法签发的 token。

```bash
BOB_TOKEN=$(vault login -method=userpass -path=staff -token-only username=bob password=builder)
VAULT_TOKEN=$BOB_TOKEN vault token lookup | grep -E 'display_name|policies|ttl'
```

禁用 `staff/` 认证方法。

```bash
vault auth disable staff/
```

禁用后，`staff/` 不能再用于登录。

```bash
vault login -method=userpass -path=staff username=bob password=builder 2>&1 | tail -4
```

同时，先前通过 `staff/` 签发的 token 也应失效。

```bash
VAULT_TOKEN=$BOB_TOKEN vault token lookup 2>&1 | tail -4
```

查看当前认证方法列表，确认 `staff/` 已经被移除。

```bash
vault auth list
```

这一阶段的关键点是：`auth disable` 不是简单隐藏登录入口，它还会撤销通过该认证方法生成的访问 token。
