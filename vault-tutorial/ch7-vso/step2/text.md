# 第二步：声明 VaultConnection 与 VaultAuth

查看预生成的 `VaultConnection` 与 `VaultAuth` 清单。`VaultConnection` 描述 Vault 服务地址；`VaultAuth` 通过 `vaultConnectionRef` 指向它，并声明使用 Kubernetes auth method、登录 Vault role `vso-app`、使用本 namespace 中的 `vso-app` ServiceAccount。

```bash
cat /root/vso-conn-auth.yaml
```

应用清单。两个对象都创建在 `vso-demo` namespace 中——这是 VSO 跨 namespace 安全模型的强约束：被引用的 ServiceAccount 必须与同步资源处于同一 namespace。

```bash
kubectl apply -f /root/vso-conn-auth.yaml
```

查看资源状态。`VaultAuth` 的 status 在被 VSO 接受后会出现 `Available` 类型的 condition（`status: True`）。

```bash
kubectl -n vso-demo get vaultconnection
kubectl -n vso-demo get vaultauth
kubectl -n vso-demo describe vaultauth vault-auth | tail -30
```

如果 status 中出现错误信息，最常见的原因是：Vault 的 Kubernetes auth role 未绑定到当前 namespace 与 ServiceAccount，或者 `VaultAuth.spec.kubernetes.audiences` 与 Vault role 的 `audience` 不一致。可以再次回到第一步比对。
