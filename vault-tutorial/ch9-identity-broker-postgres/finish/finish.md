# 实验完成

恭喜完成 9.6 节的动手实验。回顾本实验亲眼跑通的几条核心规律：

1. **Vault identity brokering 是"换上游、不换下游"**——第一步与第二步用了完全不同的 Phase 1 认证方法（AWS IAM via LocalStack vs Kubernetes ServiceAccount via TokenReview），但 Phase 2 的 ACL policy（`db-readonly`）与 Phase 3 的 `database/config/postgres-broker` + `database/roles/readonly` 一字未改。Vault 已经把"身份"与"凭据"彻底解耦，新接入一种平台只需要在 Phase 1 加一个 auth method、在 Vault role 上把"可登录身份"绑死，下游一切复用。
2. **Phase 1 的"外部身份验证"是 Vault 主动外呼完成的**——第一步里 Vault 把 CLI 提交的 `GetCallerIdentity` 签名转给 LocalStack STS 验签；第二步里 Vault 用 reviewer JWT 调集群 API server 的 TokenReview 端点验证 ServiceAccount JWT。Vault 不会盲信调用方自己说的话，**外部身份必须由原生 IdP 出具背书**。
3. **临时账号自带"上游身份"水印**——第一步派生出来的账号前缀是 `v-iam-readonly-...`，第二步是 `v-kubernetes-readonly-...`。Vault 自动把 auth method 名字写进账号名，这是审计时反向追溯"该凭据是从哪条认证路径派生"的关键锚点。
4. **Phase 3 的权限边界由目标系统的 GRANT 语句决定，不由 Vault ACL 决定**——本实验里 `database/roles/readonly` 的 `GRANT SELECT ON ALL TABLES IN SCHEMA demo TO {{name}}` 完全是 PG 端的 SQL，Vault ACL 只决定"能不能调到这条端点"。这条边界在生产里极易被搞混。
5. **lease 是凭据生命周期的中央账本**——`vault lease revoke` 一声令下，Vault 主动回到 PG 端按 `revocation_statements` 把临时账号 DROP 干净；不主动 revoke，TTL 到期同样会被 Vault 收回。**应用永远不需要、也不应该**自己保管"如何注销这份凭据"的逻辑。

下一步建议：

- 把本实验中的"通用下游 + 多种上游"模式套到真实生产：业务方接入 Vault 的成本只剩"配一条 Vault role + 在 IdP 里挂对身份"，**所有数据库引擎、PKI、KV 等下游配置都可以由平台团队集中维护**。
- 把"凭据短租约 + 主动 revoke"作为新增数据库接入 Vault 的**默认策略**——参考 [3.14 节 PostgreSQL 引擎](https://lonegunmanb.github.io/vault-tutorial/ch3-postgres.html) 的 Static Role / Dynamic Role 对比，绝大多数业务场景应该走 Dynamic Role。
- 给 Vault 集群至少配两台审计设备（参考 [8.1 节审计设备综述](https://lonegunmanb.github.io/vault-tutorial/ch8-audit-overview.html)）——Phase 1 的 `aws/login`、`kubernetes/login` 与 Phase 3 的 `database/creds/...` 申领事件都是审计的一等公民，能在出事时按 `v-iam-readonly-...` / `v-kubernetes-readonly-...` 前缀直接定位"是谁、在哪条认证链上、为哪个目标系统、签了哪份凭据"。
- 把 [9.4 节](https://lonegunmanb.github.io/vault-tutorial/ch9-acme-caddy.html) 的 PKI 自动签证书与本节的 brokering 范式串起来读：PKI 的 `pki/issue/<role>` 与 database 的 `database/creds/<role>` 在 Vault 内部是**同构的 Phase 3 端点**——同一套 brokering 抽象覆盖了 TLS 证书与数据库口令两类完全不同的目标域。
- 严格警惕本节正文 §6 列出的两类反模式：CI/CD 拉机密注入环境变量、长生命周期 AppRole——它们看上去也"用了 Vault"，但**根本不是 brokering**，请回到 9.6 节正文反复对照"为什么不是"。
