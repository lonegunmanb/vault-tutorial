# 第四步：观察不调用 TokenReview 的撤销边界

这一节演示 JWT auth 与 Kubernetes auth 的关键差异：JWT auth 不调用 TokenReview API，因此它不能实时询问 Kubernetes“这个 ServiceAccount 是否已经被删除”。只要 JWT 尚未过期、签名有效且 claim 满足 role 约束，Vault 仍可能接受它。

## 4.1 删除 ServiceAccount

先删除 `demo/jwt-app` ServiceAccount。

```bash
kubectl delete serviceaccount jwt-app -n demo
kubectl get serviceaccount -n demo
```

此时 Kubernetes 中已经不存在 `jwt-app` 这个 ServiceAccount 对象。

## 4.2 用删除前签发的 JWT 再次登录

再次提交第一步保存的 `/root/jwt-app-token.txt`。

```bash
vault write -format=json auth/jwt/login \
  role=jwt-app \
  jwt=@/root/jwt-app-token.txt | jq '.auth | {policies, metadata, lease_duration}'
```

只要这枚 JWT 还没有过期，这次登录通常仍会成功。原因是 `auth/jwt` 只验证签名和 claim，并不调用 Kubernetes TokenReview API 查询 ServiceAccount 当前状态。

## 4.3 对照 Kubernetes auth 的撤销语义

在 [4.4 Kubernetes 认证](/ch4-k8s) 中，Vault 会拿客户端提交的 ServiceAccount Token 调用 Kubernetes TokenReview API，因此 Kubernetes API server 能参与判断 token 当前是否仍然有效。

JWT auth 的优势是结构轻、依赖少、可以在 Vault 不能访问 Kubernetes API 时工作；代价是撤销语义较弱，所以应使用短生命期 token、明确 audience，并在需要即时撤销时选择 Kubernetes auth。

## 4.4 清理实验资源

清理 Vault auth method、policy 和 Kubernetes namespace。

```bash
vault auth disable jwt
vault policy delete jwt-app-read
kubectl delete namespace demo
```

## 4.5 这一步的核心闭环

本实验最后验证了一个生产上非常重要的边界：JWT auth 是签名验证模型，Kubernetes auth 是 TokenReview 模型。两者都能让 Kubernetes 工作负载登录 Vault，但适用的撤销、网络依赖和故障模式不同。