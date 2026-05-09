# 第四步：阅读 Kubernetes persistent cache 模型

本实验不直接部署 Kubernetes Pod，但已经准备好一份与官方 persistent cache 文档对应的配置片段。先阅读 sidecar Proxy 配置，重点观察 `cache.persist "kubernetes"`。

```bash
sed -n '1,180p' /root/proxy-k8s-persistent-cache.hcl
```

这个配置表达了四件事：persistent cache type 是 `kubernetes`；cache file 路径是 `/vault/proxy-cache`；恢复缓存失败时默认按错误处理；ServiceAccount token 用于 Kubernetes cache 的完整性检查。

再阅读 initialization Proxy container 使用的配置。它与 sidecar 配置的关键区别，是顶层 `exit_after_auth = true`，表示完成一次成功 Auto-auth 并写入相关状态后退出。

```bash
sed -n '1,120p' /root/proxy-k8s-init.hcl
```

继续阅读 Pod 清单模型。它展示了 initialization Proxy container 和 sidecar Vault Proxy container 如何通过同一个 memory volume 交接 cache file。

```bash
sed -n '1,240p' /root/proxy-k8s-pod.yaml
```

请特别注意下面三点：

| 配置位置 | 含义 |
| :--- | :--- |
| `emptyDir.medium: Memory` | cache file 只在 Pod 生命周期内通过内存卷共享 |
| `initContainers.proxy-init` | initialization Proxy container 先完成 Auto-auth 并准备交接状态 |
| `containers.vault-proxy` | sidecar Proxy 读取同一个 cache file，继续为 app container 服务 |

最后检查本实验使用的 Vault 版本，并把版本差异纳入排错清单。

```bash
vault version
vault proxy -h | head -20
```

在生产排错时，可以按下面顺序检查：

| 顺序 | 检查项 | 说明 |
| :--- | :--- | :--- |
| 1 | listener 是否接受请求 | 缺少 `X-Vault-Request: true` 常见为 412 |
| 2 | Auto-auth 是否成功 | 看日志中的 authentication 与 token sink |
| 3 | 最终 token 是否正确 | 分清 `true` 与 `force` 模式 |
| 4 | Vault policy 是否允许路径 | 403 多数发生在这一层 |
| 5 | Proxy 与 Vault 版本是否匹配 | 版本不一致通常是背景信息，涉及新功能时再深入判断 |

停止第二个 Proxy，释放端口。

```bash
kill "$(cat /tmp/proxy-force.pid)"
```

这一阶段的关键点是：Kubernetes persistent cache 只应用于同一 Pod 内 initialization Proxy container 与 sidecar Proxy container 之间的 tokens 和 leases 交接，不应被设计成跨 Pod 或长期保存 secret values 的共享存储。