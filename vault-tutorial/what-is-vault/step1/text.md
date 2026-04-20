# 第一步：拉取并验证官方 Vault 镜像

在生产环境中，**软件供应链安全** 是部署 Vault 的第一道防线。本步骤演示官方推荐的版本验证流程。

## 1.1 查看本机已安装的 Vault 版本

实验环境为加速启动，已经预装了 Vault 二进制（直接从 `releases.hashicorp.com` 下载）。先看看版本：

```bash
vault version
```

> **生产环境的真正最佳实践**：使用 `hashicorp/vault` 这个 **Verified Publisher** 镜像（Docker Hub 上带蓝色徽章），并且 **务必指定具体版本号**，绝不使用 `latest`。

## 1.2 验证下载文件的完整性（演示）

HashiCorp 官方为每个版本同步发布 SHA256 校验和。在生产部署流水线中，应该把这一步固化为强制门禁。

```bash
VAULT_VERSION=$(vault version | head -1 | awk '{print $2}' | tr -d 'v')
echo "当前版本：${VAULT_VERSION}"

# 查看官方校验和清单（仅查看，不实际下载）
curl -fsSL "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_SHA256SUMS" | head -20
```

你会看到所有平台二进制的 SHA256。HashiCorp 还为这个 SHA256SUMS 文件本身提供了 GPG 签名（`SHA256SUMS.sig`），可以用 HashiCorp 公钥验证签名链。

## 1.3 演示用 Docker 拉取官方镜像

如果当前环境支持 Docker（部分场景不支持），可以这样拉取并查看带版本标签的镜像：

```bash
# 仅演示，无需等待完成（Killercoda 网络对 Docker Hub 速度有限）
# docker pull hashicorp/vault:1.19.2
# docker image inspect hashicorp/vault:1.19.2 --format '{{.Id}}'
```

## 关键要点

| 错误做法 | 正确做法 |
| :--- | :--- |
| `docker pull vault` | `docker pull hashicorp/vault:1.19.2` |
| `docker pull hashicorp/vault:latest` | 指定具体版本号 |
| 直接信任二进制 | 校验 SHA256 + GPG 签名 |
| 从社区镜像源拉取 | 只用 Verified Publisher 来源 |

完成后点击 **Continue** 进入下一步。
