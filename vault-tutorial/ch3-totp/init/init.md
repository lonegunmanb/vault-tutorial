# 实验：TOTP 机密引擎双模式全流程

3.12 章我们梳理了 Vault TOTP 机密引擎的两种官方定位：

- **Generator 模式**：第三方服务给你一段 `otpauth://...` URL，Vault
  像 Google Authenticator 一样替你按时算 TOTP code
- **Provider 模式**：Vault 自己生成新的 seed key，把 barcode / `otpauth://...`
  URL 发给用户去扫；用户回头提交 code 时由 Vault 负责说 `valid` / `invalid`

本实验在一个 Dev 模式 Vault 上把这两条路完整跑一遍，并且**全程在终端里
完成**——用 `oathtool` 当作"用户手机上的 authenticator app"，整个过程
不依赖任何手机或外部服务。

- **Step 1**：启用 `totp` 引擎，把 `totp/keys/...` 与 `totp/code/...`
  两个核心端点的角色分清楚（一个管 key 定义，一个出/验 code）
- **Step 2**：Generator 模式——喂入官方文档示例的 `otpauth://...`，
  `vault read totp/code/<name>` 拿当前 TOTP；用 `oathtool` 在本机用同一
  个 base32 secret 独立算一份，证明 Vault 跟硬件 authenticator 算法完
  全一致
- **Step 3**：Provider 模式——`generate=true` 让 Vault 自己生 seed；
  从响应里挖出 `otpauth://...` URL，用 `oathtool` 模拟"用户手机上的
  authenticator app"算出当前 code，再 `vault write totp/code/<name>
  code=...` 让 Vault 验证；故意提交错误 code 看 `valid=false`，再演
  示时间 skew 窗口的实际效应
- **Step 4**：进阶参数与 ACL 隔离——调 `period` / `digits` /
  `algorithm` / `skew` 看时间窗口与算法切换效果；用两条 policy 把
  "管 key 的 operator" 和 "读/验 code 的 user" 在权限层面真正拆开
  （这正是官方文档 ACL 段落给出的权限分工的字面落地）

实验环境会预先：

- 安装 Vault 并以 Dev 模式启动（root token = `root`）
- 持久化 `VAULT_ADDR` / `VAULT_TOKEN`，所有终端直接 `vault` 命令
- 安装 `oathtool`（用来在终端里算 TOTP，模拟手机 authenticator app 的行
  为）和 `jq`

不预置任何 TOTP key——所有 enable、写 key、读/验 code 都由你手动执行。
