# 恭喜完成 Kubernetes 机密引擎实验！🎉

## 你亲手验证了什么

| 步骤 | 已验证 |
| --- | --- |
| **Step 1** | manager SA 的 ClusterRole 含 `bind`+`escalate`；最简申领能成功表示连接通路全开 |
| **Step 2 模式 A** | 仅借用现有 SA；token 权限来自 `viewer-sa` 现有 RoleBinding；revoke 不留任何 K8s 对象需要清理 |
| **Step 3 模式 B** | 现场建临时 SA + 临时 RoleBinding 引用现有 `pod-reader` Role；revoke 删 2 个，Role 留 |
| **Step 4 模式 C** | 现场建 Role + RoleBinding + SA 三件套；token 权限严格按 rules；revoke 三件套全消 |
| **Lease 隔离** | 多次申领产生独立的对象集；分别 revoke 时只清各自那组 |

## 三种模式的清理边界一图速记

```
         模式 A             模式 B              模式 C
       ┌────────┐       ┌──────────┐      ┌─────────────┐
申领时 │ (无)   │       │ +SA +RB  │      │ +Role+RB+SA │
revoke │ (无)   │       │ -SA -RB  │      │ -Role-RB-SA │
       └────────┘       └──────────┘      └─────────────┘
       借用现有 SA      复用现有 Role     全量现场生成
       审计弱           审计强            审计强 + 权限可任意
       权限固定         权限固定          权限可现场组合
```

## 与 LDAP / AWS 引擎的同模型映射

| 操作 | AWS 引擎 (3.3) | LDAP 引擎 (3.10) | K8s 引擎 (3.11) |
| --- | --- | --- | --- |
| 临时身份 | IAM User / Assumed Role | 临时 LDAP entry / 已有账号 | 临时 SA / 已有 SA |
| 凭据 | AccessKey + SecretKey | username + password | SA Token (JWT) |
| Lease 到期清理 | 删 IAM User 或 token 自然失效 | 删 LDAP entry 或改密 | 删 SA/RB/Role 或 token 自然过期 |

## 三个最容易踩的坑

1. **K8s 1.24+ 不再自动生成 SA Secret** —— 必须手工 `kubectl apply` 一个
   `kubernetes.io/service-account-token` 类型的 Secret 来获取 manager 长期 token。
   本实验的 background.sh 演示了正确做法。

2. **模式 C 报 `forbidden ... cannot escalate ... permissions`** —— manager SA 缺 `bind`/`escalate`。
   这是 K8s 的反权限提升保护，本实验的 ClusterRole 已显式授予。

3. **`vault read kubernetes/config` 看不到 token** —— 不是 bug，机密字段从不回显。
   要验证配置，直接 `vault write kubernetes/creds/<role> kubernetes_namespace=<ns>` 试一次申领。

## 与下一节的衔接

本节是"**Vault → K8s 集群**"。下一节（未来的 7.X）会反过来——"**Pod → Vault**"，
即 Pod 用自己的 SA JWT 登录 Vault 拿 Vault Token。两节合起来构成 Vault 与 K8s 的完整双向集成。

**返回文档**：[3.11 Kubernetes 机密引擎](/ch3-k8s)
