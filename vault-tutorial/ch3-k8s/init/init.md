# 实验：Kubernetes 机密引擎的三种 SA Token 签发模式

[3.11 Kubernetes 机密引擎](/ch3-k8s) 讲清楚了 manager SA + 三种 Role 模式的全部模型。
本实验在 Killercoda 预置的 **kubeadm 单节点 Kubernetes 集群** 上把三种模式跑一遍，并用 token-only 的 `kubectl auth can-i`
验证每次签出的 token 权限符合预期、用 `kubectl get role,rolebinding,sa` 观察 Lease 到期时的清理行为。

---

## 实验环境

后台脚本会自动准备好：

- **Killercoda 预置 kubeadm 单节点集群**（`kubernetes-kubeadm-1node` 后端镜像，当前随 Killercoda 更新到受支持版本）
  - kubeconfig: 使用镜像预置的 `/root/.kube/config` 或 `/etc/kubernetes/admin.conf`
- **Vault 1.19.2** Dev 模式，`VAULT_ADDR=http://127.0.0.1:8200`、`VAULT_TOKEN=root`
- **Manager SA**：`vault-manager` (在 `vault-system` namespace)
  - ClusterRole `vault-kubernetes-secrets` 已绑定，包含模式 A/B/C 全部所需权限
  - 已显式创建一个 `kubernetes.io/service-account-token` 类型的 Secret 生成长期 token
- **Vault `kubernetes/config` 已写好** —— 你不需要手工配置连接
- **预置 K8s 资源**（在 `default` namespace）：
  - SA: `viewer-sa`（模式 A 用）
  - Role: `pod-reader`（模式 A/B 用，权限：`pods:get,list`）
  - RoleBinding: `viewer-binding`（绑 viewer-sa → pod-reader）
- 工具: `vault` / `kubectl` / `jq`

---

## 你将亲手验证的事实

1. **三种模式的清理边界**：A 不留任何 K8s 对象；B 只删临时 SA + RoleBinding；C 把 Role 也一并删掉
2. **token 权限完全由绑定的 Role 决定**：与 manager SA 自己的权限**无关**
3. **Lease 隔离**：多次申领产生独立的临时对象集合，分别 revoke 时只清各自那一组
4. **K8s 1.24+ 的 SA Secret 必须显式创建**——这是配 Vault manager token 的关键技巧

预期耗时：15 ~ 25 分钟；Kubernetes 环境由 Killercoda 预置，不需要在场景中再安装集群。
