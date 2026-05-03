# 恭喜完成 AppRole 实验！🎉

这一节你把 [4.2 章](/ch4-app-role) 里 AppRole 的两大支柱——**字段、
trusted broker 范式**——亲手敲了一遍。

## 本实验的核心收获

| 阶段 | 你亲手验证的事实 |
| :--- | :--- |
| **Pull 模式最小闭环** | `auth enable approle` → write role → read role-id → write -f secret-id → write login = 拿到 batch token |
| **batch vs service token** | `token_type=batch` 签出来的 token 是 `hvb.` 开头、`accessor: n/a`、不可续期——零 storage 开销 |
| **bind_secret_id** | 默认 true，登录强制要求 `secret_id`；关掉后只看 RoleID 就能登（除非另搭 CIDR 否则等同于把 SecretID 机制白送） |
| **secret_id_num_uses=1** | SecretID 用一次后第二次登录立刻被拒，错误信息是模糊的 `invalid role or secret ID` |
| **CIDR 烙印** | `secret_id_bound_cidrs` 改了之后必须**取个新 SecretID** 才会生效——已发的 SecretID 仍按发出时的 CIDR 走 |
| **CIDR 拒绝错误** | 和 SecretID 校验拒绝的"模糊错误"不同：CIDR 拒绝给出精确的 `source address "..." unauthorized through CIDR restrictions on the secret ID` |
| **min_wrapping_ttl 这道 ACL 防线** | 没带 `-wrap-ttl` 的请求直接被策略 deny——broker 永远拿不到裸 SecretID |
| **wrapping token 一次性硬约束** | 双重 unwrap 立刻报 `wrapping token is not valid or does not exist`——这是审计层识破"中途偷看"的根因 |
| **trusted broker 范式** | admin 不接触 SecretID、broker 不接触 SecretID 明文、runner 是**唯一**两半凭据同时出现的位置 |

## 一张图总结整章

```
            ┌──────────────────────────────────────────────────┐
            │              AppRole 认证方法                    │
            │     trusted broker（不是 trusted 3rd-party）     │
            └──────────────────┬───────────────────────────────┘
                               │
              ┌────────────────┴─────────────────┐
              │                                  │
        两半凭据                          约束与生命周期
              │                                  │
       ┌──────┴──────┐                  ┌────────┼────────┐
       │             │                  │        │        │
    RoleID       SecretID            CIDR    num_uses    TTL
       │             │                  │        │        │
   "用户名"      "密码"               IP 白    SecretID  TTL/
   半公开       必须保密              名单     用一次     wrapping
       │             │                  │      就废       TTL
   可写镜像          │                  │
   可入环境变量      │
                  ┌──┴──┐
                  │     │
              Pull       Push
              UUID       客户端自定义
              (推荐)     (兼容老 App-ID)
                  │
              ┌───┴────┐
              │        │
           裸 SecretID  Wrapped SecretID
                        │
                 一次性信封 + 100-300s
                 + min/max_wrapping_ttl
                 ACL 防线
                        │
                trusted broker 范式
                  worker → runner
```

## 接下来去哪儿

回到 [4.2 章正文](/ch4-app-role)：

- §5 那张"两道安全装置"对应你 step 3（CIDR）+ step 4（Wrapping）亲
  手验证过的两类拒绝现场
- §6 的 Jenkins 工作流 10 步，对应你 step 4 的 admin → worker →
  runner 三角

下一节预告：第 4 章后续小节会继续逐个 Auth Method 动手——
`kubernetes`、`jwt/oidc`、`cert` 等。
