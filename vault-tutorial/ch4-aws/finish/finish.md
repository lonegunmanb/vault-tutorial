# 恭喜完成 AWS 认证实验！🎉

这一节你用 MiniStack 模拟 AWS，把 [4.3 章](/ch4-aws) 里 AWS 认证方
法**iam 完整链路 + ec2 配置面 + 运维端点**亲手敲了一遍。

## 本实验的核心收获

| 阶段 | 你亲手验证的事实 |
| :--- | :--- |
| **MiniStack + config/client** | `iam_endpoint` 直连本地 4566；`sts_endpoint` 指向 4567 的 Content-Type shim；`iam_server_id_header_value` 也写在这里 |
| **iam 真实登录链路** | `vault login -method=aws` → CLI 用 `dev-user` 凭据签 GetCallerIdentity → Vault 转给 MiniStack STS → STS 返回 ARN → Vault 据此签 token |
| **root ARN 限制** | `arn:aws:iam::000000000000:root` 只能证明 STS 可用；Vault iam 登录要用 `user/...` / `role/...` / `assumed-role/...` 这类普通 principal |
| **header_value 这道防线** | 漏掉 `header_value=` 的登录在 Vault 端就被拒（`iam server id header values do not match`），不会发给 STS |
| **bound_iam_principal_arn 精确匹配** | 用 `app-user` 登只绑定 `dev-user` 的 role 被拒（`IAM Principal ... does not belong to the role`） |
| **bound_iam_principal_arn 通配符** | 改成 `arn:aws:iam::000000000000:*` 后该账号下任意 principal 都能登 |
| **resolve_aws_unique_ids** | 默认 true 会调 IAM 解析 unique ID；本实验显式关掉，直接演示 ARN 绑定与匹配 |
| **写入侧 mixing 拦截** | iam role 加 `bound_ami_id`（未开 inferencing）/ ec2 role 加 `bound_iam_principal_arn` 都被 Vault 在写入时直接拒 |
| **登录侧 mixing 拦截** | iam 风格请求打 ec2 role / 反之均报 `auth method ... is not allowed for role ...` |
| **ec2 PKCS#7 验签** | iam 验签转给 AWS、ec2 验签 Vault 自己做——伪造 PKCS#7 在 Vault 这层就被拒 |
| **运维端点** | `identity-accesslist` / `roletag-denylist` / `tidy` 的语义与字段——`tidy` 默认 `safety_buffer=72h` |

## 一张图总结整章

```
            ┌──────────────────────────────────────────────────┐
            │            AWS 认证方法（trusted 3rd-party）     │
            │  信任根：AWS（IAM 签名 / EC2 PKCS#7）            │
            └──────────────────┬───────────────────────────────┘
                               │
              ┌────────────────┴─────────────────┐
              │                                  │
           iam 方法                          ec2 方法
              │                                  │
   client SigV4(GetCallerIdentity)        AWS 给 EC2 的 PKCS#7(IID)
              │                                  │
   Vault 转发 → AWS STS 验签           Vault 用内置 AWS 公钥验签
              │                                  │
   bound_iam_principal_arn                  bound_ami_id / bound_account_id /
   （列表 + 结尾通配）                       bound_iam_role_arn / role_tag /
   inferred_entity_type=ec2_instance        Client Nonce + TOFU accesslist /
   开启推断后可加 ec2-only 约束              instance migration / deny list

   额外防重放：iam_server_id_header_value（iam 专用）
   AWS SigV4 自带 15 分钟时间窗
   ec2 方法 instance ID 进 identity-accesslist；
   role tag 错配后写 roletag-denylist；两边由 tidy 清理
```

## 接下来去哪儿

回到 [4.3 章正文](/ch4-aws)：

- §2 / §4 那段 iam 流程 + ARN 绑定，对应你 step 2 / step 3 真实跑通
  的链路与拒绝现场
- §3 + §6 ec2 流程 + mixing，对应你 step 4 看到的写入 / 登录两道关
- §8 / §9 / §10 三节的 accesslist / nonce / role tag deny list，对
  应你 step 4 跑过的运维端点
- §13 plugin WIF 是企业版独有，开源版了解即可

下一节预告：第 4 章后续小节会继续逐个 Auth Method 动手——
`kubernetes`、`jwt/oidc`、`cert` 等。
