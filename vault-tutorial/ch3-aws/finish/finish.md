# 恭喜完成 AWS 机密引擎实验！🎉

这一节你把"动态机密"的核心理念在一个本地 AWS 模拟器上跑通了——没花
一分钱、没改任何真 AWS 账号，就摸清了 Vault 的 IAM 凭据铸造与回收
流程。

## 本实验的核心收获

| 阶段 | 你亲手验证的事实 |
| :--- | :--- |
| **`config/root` = 种子 key** | 写入即被加密保存、`secret_key` 不可回读；`iam_endpoint` / `sts_endpoint` 让 Vault 可指向任意 AWS 兼容服务 |
| **Role 是模板** | 写 Role 不会动 AWS；只有 `vault read aws/creds/...` 那一刻 Vault 才去 `CreateUser` / `CreateAccessKey` |
| **`iam_user` 真的造 user** | 每次取凭据 = MiniStack IAM 多一个真 User；`vault lease revoke` 立刻反过来 `DeleteUser` |
| **`assumed_role` 不造 user** | 调 `sts:AssumeRole` 拿三件套（带 `session_token`）；AWS IAM User 数量保持不变 |
| **路径决定一切** | `iam_user` 走 `aws/creds/<role>`，`assumed_role` 走 `aws/sts/<role>`；写错就 `unknown role` |
| **Policy 必须精确到 Role 名** | `aws/creds/*` 通配 = 应用能拿管理员凭据；正确写法是 `aws/creds/s3-app` 这一层 |
| **`config/*` 默认禁** | 应用 token 不要碰 root key、不要碰 `rotate-root`、不要改 lease 配置 |

## 一些实验里特意没演示的内容

- **`federation_token`**：MiniStack 没实现 `sts:GetFederationToken`，
  所以 §3.3 里讲的这种类型只能停留在文档。需要时拿真 AWS 账号试一把
- **`rotate-root` / `rotation_period`**：MiniStack 的 `iam:CreateAccessKey`
  对同一 user 的并发支持比真 AWS 弱，演示效果不稳定。生产里这是必做
  动作——把 `aws/config/root` 当首要风险面定期换 key
- **跨账号 `assumed_role`**：本实验所有资源都在 MiniStack 的伪账号
  `000000000000` 里，没法演示"账号 A 的 root key 去 AssumeRole 到账号
  B"。理解上把 §3.2 的 `role_arns` 换成另一个账号下的 ARN 即可

## 切回真实 AWS 时只需改两件事

1. **删掉 `iam_endpoint` / `sts_endpoint`**：让 Vault 走 AWS 公网端点
2. **`access_key` / `secret_key` 换成真 IAM User 的凭据**：并按 §6.2
   把它的权限收窄到只能调 `iam:*User*` / `iam:*AccessKey*` / `sts:*`

其他 Role / Policy / `vault read aws/creds/...` 用法**完全一致**——
这是"用本地模拟器做开发"的最大价值：业务代码不用改一行就能切到生产。

## 清理实验环境

```bash
docker rm -f ministack
vault secrets disable aws
```

`disable aws` 会自动 revoke 所有该引擎下的 lease——但 MiniStack 容器
已经没了，那些 IAM User 也没人能看见了，无所谓。

## 下一站

- 继续阅读 [3.4 / 3.5 等其他机密引擎](/) ——同样的 Lease + Role 心
  智模型在 Database / SSH / PKI 上几乎完全复用
- 回顾 [2.3 Lease](/ch2-lease)——你刚才的每一次 `lease revoke` 都
  是那一章理论的实战演示
- 跳到 [5.7 Mount Migration](/ch5-mount-migration) 看怎么把 `aws/`
  搬到 `aws-prod/` 的同时保住所有 Role 和已有 Lease
