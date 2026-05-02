---
order: 312
title: 3.12 PKI 机密引擎：让 Vault 成为你的证书颁发机构
group: 第 3 章：核心机密引擎管理体系 (Secret Engines)
group_order: 30
---

# 3.12 PKI 机密引擎：让 Vault 成为你的证书颁发机构

> **本章脉络**：PKI Secrets Engine 是 Vault 中最复杂也最强大的引擎之一——它让 Vault 化身完整的证书颁发机构（CA），动态签发 X.509 证书。
> 本章从概念入门出发，先走通一条"最小可用链路"，再分别演示 Root CA 与 Intermediate CA 的快速搭建，
> 接着深入生产环境的注意事项、CA 轮换原语，最后讲解 ACME 自动化与故障排查。
> 无论你是第一次接触 PKI，还是正在将现有 CA 迁移到 Vault，都能在本章找到对应的知识点。

参考：
- [PKI Secrets Engine — Vault Docs](https://developer.hashicorp.com/vault/docs/secrets/pki)
- [PKI Secrets Engine API](https://developer.hashicorp.com/vault/api-docs/secret/pki)

---
## 1. PKI 引擎概念入门

> **核心结论**：PKI Secrets Engine 是 Vault 内置的动态 X.509 证书签发引擎。
> 它让服务在请求时即刻获得证书，**无需**走传统的"生成私钥 + CSR → 提交给 CA → 等待人工验签"流程。
> Vault 自带的认证与鉴权机制直接充当 CA 的"验证环节"，从而将证书签发完全自动化。
> 设计哲学的核心是 **短 TTL + 每实例唯一证书 + 瞬时证书（Ephemeral）**——证书越短命，吊销需求越小，安全态势越好。

---

### 1.1 PKI Secrets Engine 是什么

PKI Secrets Engine 是一种动态签发 X.509 证书的 Secrets Engine。当应用或服务需要 TLS 证书时，只需向 Vault 发出请求，引擎即可即时生成并返回证书与私钥，整个过程完全自动化。

![PKI 引擎与传统 CA 签发流程对比](/images/ch3-pki/pki-vs-traditional-ca.png)

### 1.2 解决了什么痛点

传统证书签发依赖一条冗长的人工链路：

1. 服务方生成私钥和 CSR（Certificate Signing Request）
2. 将 CSR 提交给 CA（Certificate Authority）
3. CA 进行人工验证与签名
4. 等待签发结果并部署证书

Vault PKI 引擎将上述步骤压缩为一次 API 调用。Vault 自带的认证与鉴权机制充当了 CA 的"验证环节"，服务无需再经历手动的验签等待。

---

### 1.3 设计哲学：短 TTL + 大量短命证书

PKI 引擎的核心设计围绕以下几条理念：

| 理念 | 说明 |
| --- | --- |
| **短 TTL 减少吊销需求** | 只要 TTL 保持相对短（relatively short），撤销（revocation）就不太可能被需要，CRL 也能保持很小，引擎因此可以扩展到大规模工作负载。 |
| **每实例一张唯一证书** | 每个运行中的应用实例持有独立证书，消除多实例共享证书带来的吊销与轮换痛点。 |
| **瞬时证书（Ephemeral）** | 证书可以在应用启动时拉取并存放在内存中，应用关闭时即丢弃，**永不写入磁盘**。 |

![短 TTL 与瞬时证书的运维心智模型](/images/ch3-pki/short-ttl-mental-model.png)

> **提示**：短 TTL 策略与传统"签发一张长期证书、小心翼翼地吊销"的模式截然不同。**（编者注）** 初次接触时可能会觉得"频繁签发"增加了复杂度，但实际上它大幅简化了吊销管理——当证书本身只有几小时甚至几分钟的有效期时，即使私钥泄漏，影响窗口也极为有限。

---

### 1.4 术语铺垫

以下术语将在后续章节中频繁出现，这里做一个简要铺垫：

| 术语 | 简介 |
| --- | --- |
| **X.509** | 定义公钥证书格式的国际标准，TLS/SSL 证书均基于此标准。 |
| **CA（Certificate Authority）** | 证书颁发机构，负责签发和管理数字证书。 |
| **Root CA（根 CA）** | 信任链的最顶层，其证书为自签名；Root CA 的私钥安全性决定整条信任链的安全。 |
| **Intermediate CA（中间 CA）** | 由 Root CA 签发的下级 CA，实际对外签发终端证书；即使中间 CA 被攻破，也可通过 Root CA 进行吊销而不影响其他分支。 |
| **CSR（Certificate Signing Request）** | 证书签名请求，包含申请者的公钥与身份信息，提交给 CA 后由 CA 签发正式证书。 |
| **CRL（Certificate Revocation List）** | 证书吊销列表，CA 定期发布的已吊销证书清单；短 TTL 策略下 CRL 可保持很小。 |
| **OCSP（Online Certificate Status Protocol）** | 在线证书状态协议，允许客户端实时查询某张证书是否已被吊销，比 CRL 更及时。 |

![Root CA 与 Intermediate CA 的两层信任结构](/images/ch3-pki/ca-hierarchy.png)

---

### 1.5 Vault PKI 文档矩阵概览

Vault 官方的 PKI 文档由多篇子文档组成，本教程将分阶段覆盖其中的核心主题。以下是整体矩阵与本教程的对应关系：

| 官方子文档 | 内容 | 本教程覆盖情况 |
| --- | --- | --- |
| **Overview** | 概念入门（即本节） | ✅ 第 1 节 |
| **Setup and Usage** | 引擎的启用与基本用法 | ✅ 第 2 节（最小可用链路） |
| **Quick Start — Root CA Setup** | 搭建根 CA 的快速指南 | ✅ 第 3 节 |
| **Quick Start — Intermediate CA Setup** | 搭建中间 CA 的快速指南 | ✅ 第 4 节 |
| **Considerations** | 运维使用注意事项清单 | ✅ 第 5 节（踩坑 / 最佳实践） |
| **Rotation Primitives** | 用于轮换的不同证书类型 | ✅ 第 6 节 |
| **ACME** | Vault 对 ACME 协议的支持与限制 | ✅ 第 7 节（含故障排查） |

---

### 1.6 企业版功能提示

> **提示**：Vault Enterprise 还额外提供以下证书签发协议与服务，本教程不做展开：
>
> - **CIEPS**（Certificate Issuance External Policy Service）
> - **EST**（Enrollment over Secure Transport）
> - **CMPv2**（Certificate Management Protocol v2）
> - **SCEP**（Simple Certificate Enrollment Protocol）
>
> 社区版用户可忽略上述功能；如需了解详情，请参阅官方企业版文档。

---

### 1.7 SHA-1 弃用警告

> ⚠️ **警告**：当 PKI 引擎将外部 X.509 证书用于 **TLS 或签名校验**（TLS or signature validation）时，**针对使用 SHA-1 的 X.509 证书做签名校验**（verifying signatures against X.509 certificates that use SHA-1）已被弃用。自 **Vault 1.12** 起，若不启用变通方案（workaround），将无法继续使用此类证书。

---

### 1.8 API 与 Terraform 概览

PKI Secrets Engine 提供完整的 HTTP API，所有通过 CLI 能完成的操作均可通过 API 实现。

此外，HashiCorp 官方 Terraform Provider 提供了丰富的 PKI 相关资源，覆盖以下类别：

- **配置类**：`pki_secret_backend_config_urls`、`pki_secret_backend_crl_config` 等
- **密钥与签发者**：`pki_secret_backend_key`、`pki_secret_backend_issuer`
- **角色与证书**：`pki_secret_backend_role`、`pki_secret_backend_cert`、`pki_secret_backend_sign`
- **Root / Intermediate CA**：`pki_secret_backend_root_cert`、`pki_secret_backend_intermediate_cert_request` 等

> **提示**：在后续实操章节中，我们将以 CLI 方式演示为主。读者可根据自身需求选择 CLI、HTTP API 或 Terraform 进行操作。**（编者注）** 生产环境中推荐使用 Terraform 进行 PKI 基础设施的声明式管理，以获得可审计、可重复的配置。

**延伸阅读**：

- [PKI Secrets Engine HTTP API](https://developer.hashicorp.com/vault/api-docs/secret/pki)
- [Build Your Own Certificate Authority (CA)](https://developer.hashicorp.com/vault/tutorials/secrets-management/pki-engine)
- [Build CA in Vault with an offline Root](https://developer.hashicorp.com/vault/tutorials/secrets-management/pki-engine-external-ca)
- [Enable ACME with PKI secrets engine](https://developer.hashicorp.com/vault/tutorials/secrets-management/pki-acme-caddy)
- [PKI Unified CRL and OCSP With Cross Cluster Revocation](https://developer.hashicorp.com/vault/tutorials/secrets-management/pki-unified-crl-ocsp-cross-cluster)
- [Configure Vault as a Certificate Manager in Kubernetes with Helm](https://developer.hashicorp.com/vault/tutorials/kubernetes/kubernetes-cert-manager)
- [Generate mTLS Certificates for Nomad using Vault](https://developer.hashicorp.com/vault/tutorials/secrets-management/vault-pki-nomad)

---

在理解了 PKI 引擎的核心概念与设计哲学之后，接下来我们动手实操——走通从启用引擎到签发第一张证书的完整链路。
## 2. 最小可用链路——从启用到签发

多数 secrets engine 并非开箱即用，PKI 也不例外。原文开篇便指明：

> *"Most secrets engines must be configured in advance before they can perform their functions. These steps are usually completed by an operator or configuration management tool."*

也就是说，PKI 引擎的初始化（启用 → 调优 → 配置 CA → 配置 URL → 定义 Role）通常由 **operator 或配置管理工具** 预先完成，之后才交给业务侧按 Role 签发证书。两个角色的边界非常清晰：**配置者**负责建立信任链与策略，**使用者**只需知道 Role 名即可申领证书。

本节将走完这条"最小可用链路"——六步跑通一张证书的签发。

![PKI 最小可用链路流水线](/images/ch3-pki/setup-pipeline.png)

---

### 2.1 Step 1：启用 PKI Secrets Engine

```shell-session
$ vault secrets enable pki
Success! Enabled the pki secrets engine at: pki/
```

默认挂载路径等于引擎名称，即 `pki/`。如果需要挂载到自定义路径，可使用 `-path` 参数：

```shell-session
$ vault secrets enable -path=pki_root pki
```

> **提示**：自定义路径对"一个 Vault 同时承担多个 CA"非常重要——例如分别挂载 `pki_root/` 和 `pki_int/`，后续讲解 intermediate CA 时会用到这一技巧。

---

### 2.2 Step 2：调优 `max-lease-ttl`

```shell-session
$ vault secrets tune -max-lease-ttl=8760h pki
Success! Tuned the secrets engine at: pki/
```

默认的 max lease TTL 仅 **30 天**，对证书场景而言可能太短，因此示例将其调整到 **1 年**（`8760h` = 365 × 24）。

这里有一个重要的 **两层 TTL 概念**需要理解：

| 层级 | 作用 | 谁来设置 |
| --- | --- | --- |
| **Engine 级** `max-lease-ttl` | 全局上限，所有 Role 均不可突破 | operator 通过 `vault secrets tune` |
| **Role 级** `max_ttl` | 按 Role 进一步收紧，只能 ≤ engine 级上限 | operator 在定义 Role 时设定 |

> **提示**：`8760h` 中的 `h` 表示小时，是 Vault 接受的时间单位之一。**（编者注）** 常见单位还有 `s`（秒）和 `m`（分钟），大部分场景用 `h` 即可。

---

### 2.3 Step 3：配置 CA 证书

```shell-session
$ vault write pki/root/generate/internal \
    common_name=my-website.com \
    ttl=8760h
```

返回字段包括 `certificate`、`expiration`、`issuing_ca`、`serial_number`。

Vault 支持两种模式配置 CA：

1. **导入已有密钥对** —— 外部生成的 CA 证书与私钥导入 Vault。
2. **由 Vault 生成自签 root** —— 即上面使用的 `internal` 模式。

> ⚠️ **警告**：官方推荐 root CA **保管在 Vault 之外**，只把签发好的 **intermediate CA** 交给 Vault。这是生产实践中的关键安全原则——降低 root 私钥暴露面、便于离线保管。本步使用 `internal` 模式仅为演示快速跑通，生产环境请走 intermediate 流程（后续章节会详细讲解）。

使用 `internal` 类型时，**私钥永不出 Vault**——命令输出中只返回证书信息，不会回显私钥。**（编者注）** 与之对应的还有 `exported` 模式，会在响应中一次性返回私钥，适用于需要将 CA 私钥备份到外部 HSM 等特殊场景，但安全风险更高。

---

### 2.4 Step 4：配置 URL

```shell-session
$ vault write pki/config/urls \
    issuing_certificates="http://127.0.0.1:8200/v1/pki/ca" \
    crl_distribution_points="http://127.0.0.1:8200/v1/pki/crl"
```

这两个 URL 会被写进将来签发的每一张证书的 **AIA**（Authority Information Access）与 **CRL Distribution Points** 扩展，客户端据此验证证书链与吊销状态。

> ⚠️ **警告**：示例中的 `127.0.0.1:8200` 仅适用于本地实验。**生产环境必须替换为对客户端可达的对外地址**（域名或负载均衡器地址），否则浏览器或其他客户端将无法获取 CA 链与 CRL。

> **提示**：虽然这些值可以将来再更新，但**已签发证书内嵌的 URL 不会随配置更新而改变**。因此应养成尽早正确配置的习惯——实验阶段可以用占位值，但在签发生产证书之前务必改为正式地址。

---

### 2.5 Step 5：配置 Role

```shell-session
$ vault write pki/roles/example-dot-com \
    allowed_domains=my-website.com \
    allow_subdomains=true \
    max_ttl=72h
```

Role 是 PKI 引擎的 **"模板/策略"**——它将 Vault 中的一个名称映射到一套证书签发规则。用户或自动化工具在申请证书时，指定 Role 名即可，无需了解底层 CA 细节。

示例中三个关键参数：

| 参数 | 含义 |
| --- | --- |
| `allowed_domains` | 白名单域名，限定该 Role 可签发的域 |
| `allow_subdomains=true` | 允许签发白名单域的任意子域（如 `www.my-website.com`、`api.my-website.com`） |
| `max_ttl=72h` | Role 级 TTL 上限，不能超过 engine 级的 `max-lease-ttl`（呼应 Step 2 的两层 TTL 概念） |

> **提示**：Role 名（`example-dot-com`）只是 Vault 内部标识，调用方按 Role 名请求证书。它与实际签发的 CN（Common Name）或 SAN 没有直接关系。

---

### 2.6 Usage：签发证书

配置完成后，持有合适权限 Vault token 的用户或自动化工具即可签发证书：

```shell-session
$ vault write pki/issue/example-dot-com \
    common_name=www.my-website.com
```

返回字段包括 `certificate`、`issuing_ca`、`private_key`、`private_key_type`（`rsa`）、`serial_number`。

几个关键要点：

- **私钥是动态生成、随响应一次性返回**——客户端必须在此刻保存，**Vault 不存储该私钥**。若未及时保存，只能重新申请一张新证书。
- 证书有效期受 Role 的 `max_ttl` 约束（本例为 72h），体现了 **"短生命周期证书"** 的理念，这是 Vault PKI 的核心价值之一。**（编者注）** 相比传统 CA 动辄一年甚至更长的 TTL，短周期证书大幅缩小了私钥泄露后的风险窗口。
- 响应中同时返回 `issuing_ca` 与信任链，方便自动化脚本一次拿齐部署所需的全部材料。
- **（编者注）** 端点形式为 `pki/issue/<role名>`：调用方只需知道 Role 名，无需了解底层 CA 的具体配置——抽象边界非常清晰。

> **提示**：PKI 引擎提供完整的 HTTP API，可在自动化场景中直接调用，无需依赖 CLI。

---

### 2.7 小结

回顾整条最小可用链路：

| 步骤 | 命令关键路径 | 核心作用 |
| --- | --- | --- |
| ① 启用引擎 | `vault secrets enable pki` | 在 Vault 中挂载 PKI secrets engine |
| ② 调优 TTL | `vault secrets tune -max-lease-ttl=8760h pki` | 设定 engine 级证书最大有效期上限 |
| ③ 配置 CA | `pki/root/generate/internal` | 建立信任锚点（CA 证书） |
| ④ 配置 URL | `pki/config/urls` | 告诉证书持有者去哪里验证链与吊销 |
| ⑤ 定义 Role | `pki/roles/<name>` | 创建签发模板，约束域名、TTL 等策略 |
| ⑥ 签发证书 | `pki/issue/<role>` | 按 Role 动态生成证书 + 私钥 |

![PKI 流水线全景图——生产 vs 演示对比](/images/ch3-pki/prod-vs-demo.png)

**生产 vs 演示关键差异速查**：

| 维度 | 演示（本节） | 生产建议 |
| --- | --- | --- |
| CA 模式 | `internal` 自签 root | 外部 root CA + Vault 持有 intermediate |
| URL 地址 | `127.0.0.1:8200` | 对客户端可达的域名或负载均衡器地址 |
| 证书 TTL | 可按需设长以方便实验 | 尽量短（配合自动轮转降低风险窗口） |

> **提示**：本节尚未涉及 intermediate CA、证书吊销（Revoke）、CRL 重建、Role 的更多字段（如 `key_type`、`key_bits`、`allow_ip_sans` 等），这些内容将在后续章节展开。

---

上一节展示了 PKI 引擎的六步最小可用链路。接下来，我们用一个完整的示例来演示 Root CA 的快速搭建过程。
## 3. Root CA 快速搭建

> **核心结论**：本节是使用 Vault PKI Secrets Engine **最短路径跑通 Root CA** 的入门示例。
> 流程为：挂载 `pki` 后端 → 调整 mount 最大 TTL → 生成自签名 Root 证书 → 配置 URL → 定义 Role → 签发证书。
> 本例为求简单，**直接用 Root CA 签发叶子证书**；生产中应使用 Root → Intermediate → Leaf 的层级结构。
> 引用："Generally you'll want a root certificate to only be used to sign CA intermediate certificates."

---

### 3.1 挂载 PKI 后端

与 `kv` 不同，`pki` 后端**默认不挂载**，必须显式 enable：

> "Unlike the `kv` backend, the `pki` backend is not mounted by default."

```bash
vault secrets enable pki
```

输出参考：`Successfully mounted 'pki' at 'pki'!`

---

### 3.2 调整 mount 的最大租约 TTL

Root CA 通常需要长生命周期，而 Root CA 证书的有效期**受 mount 最大 TTL 限制**，所以需要先把 mount 的 max TTL 调大：

> "since it honors the maximum mount TTL, first we adjust that"

```bash
vault secrets tune -max-lease-ttl=87600h pki
```

`87600h` ≈ 10 年：

> "That sets the maximum TTL for secrets issued from the mount to 10 years."

Role 还可以**进一步收紧** TTL：

> "Note that roles can further restrict the maximum TTL."

> **（编者注）** 如果忘记先执行 `vault secrets tune`，生成 Root 证书时指定的 `ttl` 会被 mount 默认最大 TTL 截断，最终得到一个远比预期短的 CA 证书。

---

### 3.3 CA 证书来源的三种方式

PKI 引擎支持三种 CA 配置方式：

> "We'll take advantage of the backend's self-signed root generation support, but Vault also supports generating an intermediate CA (with a CSR for signing) or setting a PEM-encoded certificate and private key bundle directly into the backend."

总结如下：

| 方式 | 说明 | 适用场景 |
| --- | --- | --- |
| **自签名 Root** | Vault 内部直接生成自签名根证书（本节使用） | 快速搭建、开发测试 |
| **生成 Intermediate CSR** | Vault 生成 CSR，由外部 Root CA 签名后导入 | 生产环境分层架构 |
| **导入已有 PEM bundle** | 将外部已有的证书 + 私钥 bundle 直接写入引擎 | 迁移现有 CA 到 Vault |

![CA 证书来源三种方式对比](/images/ch3-pki/ca-source-comparison.png)

---

### 3.4 生成自签名 Root 证书

```bash
vault write pki/root/generate/internal \
    common_name=myvault.com \
    ttl=87600h
```

**路径解析**：`pki/root/generate/internal` 中 `internal` 表示本次生成的私钥**安全存放在 backend mount 中**。

返回字段包括：`certificate`、`expiration`、`issuing_ca`、`serial_number` 等。

> "The returned certificate is purely informational; it and its private key are safely stored in the backend mount."

返回的 `certificate` 仅为信息性内容；证书与私钥本身由 Vault 安全存储在 backend mount 中，不需要也不应该手动复制私钥到外部。

> **（编者注）** `internal` 模式下生成的私钥不会在该命令的响应中返回；关于是否可导出等具体语义，请参考 PKI API 文档。

---

### 3.5 配置 URL

签发出的证书需要内嵌 **CRL 分发点**与 **issuing CA** 的访问 URL，便于客户端验证证书链：

> "Generated certificates can have the CRL location and the location of the issuing certificate encoded."

```bash
vault write pki/config/urls \
    issuing_certificates="http://vault.example.com:8200/v1/pki/ca" \
    crl_distribution_points="http://vault.example.com:8200/v1/pki/crl"
```

> "These values must be set manually and typically to FQDN associated to the Vault server, but can be changed at any time."

这些 URL 通常设置为 Vault 服务器对应的 FQDN，且可以随时修改。

> **（编者注）** 如果 URL 配置成客户端无法访问的地址，会导致客户端取不到 CA 证书或 CRL，进而造成证书验证失败。

---

### 3.6 配置 Role

Role 是一个逻辑名称，映射到一组用于生成凭证的策略：

> "A role is a logical name that maps to a policy used to generate those credentials."

Role 定义了**谁能签发什么样的证书**（域名、TTL、key 类型等约束）。

```bash
vault write pki/roles/example-dot-com \
    allowed_domains=example.com \
    allow_subdomains=true \
    max_ttl=72h
```

关键参数含义：

| 参数 | 含义 |
| --- | --- |
| `allowed_domains` | 限制该 Role 可签发的域名范围 |
| `allow_subdomains` | 设为 `true` 时允许签发子域证书（如 `blah.example.com`） |
| `max_ttl` | Role 层面进一步限制证书有效期；与 mount 级别 TTL 形成层级约束关系 |

---

### 3.7 签发证书

```bash
vault write pki/issue/example-dot-com \
    common_name=blah.example.com
```

路径模式为 `pki/issue/<role-name>`：

> "To generate a new certificate, we simply write to the `issue` endpoint with that role name"

> "Vault has now generated a new set of credentials using the `example-dot-com` role configuration. Here we see the dynamically generated private key and certificate."

这里体现了 **动态凭证（dynamic credentials）** 的概念——与传统手工申请证书的运维模式形成对比，每次调用都会生成全新的证书和私钥。

返回字段逐一说明：

| 字段 | 说明 |
| --- | --- |
| `certificate` | 签发的叶子证书 |
| `issuing_ca` | 签发该证书的 CA 证书 |
| `private_key` | 动态生成的私钥，会返回给调用者 |
| `private_key_type` | 私钥类型（如 `rsa`） |
| `serial_number` | 证书序列号，用于后续吊销等操作 |

![证书签发流程](/images/ch3-pki/issue-certificate-flow.png)


---

### 3.8 ACL 分层设计方向

> "Using ACLs, it is possible to restrict using the pki backend such that trusted operators can manage the role definitions, and both users and applications are restricted in the credentials they are allowed to read."

权限分层可沿以下方向设计：

- **Operator**：管理 mount、role、URL 配置（如 `pki/roles/*`、`pki/config/*` 的写权限）。
- **应用 / 用户**：仅授予 `pki/issue/<role>` 的 `update` 权限，不能修改 Role 定义。

> **（工程补充）** 上述路径与 capability 分配为基于 Vault 通用 ACL 模型的示例性补充，非原文明示。实际落地时可结合 Vault Policy 章节的内容，为不同角色编写细粒度策略。

---

### 3.9 调试提示：`vault path-help`

> "If you get stuck at any time, simply run `vault path-help pki` or with a subpath for interactive help output."

`vault path-help` 是 PKI（以及任何 Secrets Engine）调试时的实用命令，可以查看引擎支持的所有路径及其参数说明：

```bash
# 查看 pki 引擎的顶层帮助
vault path-help pki

# 查看特定子路径的帮助
vault path-help pki/issue
vault path-help pki/roles
```

---

### 3.10 延伸阅读

本节只是 PKI 引擎的 quick start；生产部署建议参考以下资源实现 Root + Intermediate 分层：

- 进阶教程：[Build Your Own Certificate Authority (CA)](https://developer.hashicorp.com/vault/tutorials/secrets-management/pki-engine)
- 企业版功能：[PKI Secrets Engine with Managed Keys](https://developer.hashicorp.com/vault/tutorials/enterprise/managed-key-pki)，介绍外部托管私钥
- API 参考：[PKI Secrets Engine API](https://developer.hashicorp.com/vault/api-docs/secret/pki)

---

Root CA 快速跑通后，接下来是生产环境中更为推荐的做法——搭建 Intermediate CA，让 Root 退居幕后。

## 4. Intermediate CA 快速搭建

> **核心结论**：在前面的 Root CA 快速入门中，证书是直接由 Root CA 签发的——这并不是推荐做法。
> 生产环境的标准实践是：Root CA 只用来签发 Intermediate CA 证书，而日常的叶子证书由 Intermediate CA 签出。
> 本节在已有的 Root CA（`pki` 路径）基础上，搭建一个 Intermediate CA（`pki_int` 路径），
> 完成从**挂载引擎 → 生成 CSR → Root 签名 → 装回证书 → 配置 URL → 创建 Role → 签发叶子证书**的完整流程。

---

### 4.1 为什么需要 Intermediate CA

Root CA 直接签发叶子证书存在两个主要问题：

1. **Root 暴露面过大**：每次签发都要使用 Root 私钥，一旦 Root 私钥泄露，整条信任链全部作废，影响范围不可控。
2. **缺乏层级隔离**：没有中间层来做策略收敛（如域名限制、TTL 限制），所有签发逻辑都堆在 Root 上。

引入 Intermediate CA 后：

- Root CA 可以**离线保护**——只在签发/续签 Intermediate 证书时才启用。
- 日常签发工作全部交给 Intermediate CA，即使 Intermediate 私钥泄露，也只需吊销并替换该 Intermediate，Root 不受影响。
- 不同业务线可以各自拥有独立的 Intermediate CA，实现权限与域名的物理隔离。

> **提示**：本节操作假设你已经按照前面 Root CA 章节完成了 `pki` 路径的挂载和 Root CA 的生成。如果尚未完成，请先回到该节操作。

---

### 4.2 挂载第二个 PKI Backend

同一个 `pki` secrets engine 可以在 Vault 中多次挂载，只要使用不同的 `path` 来区分。这里我们用 `pki_int` 表示 intermediate：

```shell-session
$ vault secrets enable -path=pki_int pki
Successfully mounted 'pki' at 'pki_int'!
```

> **提示**：`-path` 参数决定了后续所有操作的路径前缀。你可以根据实际需要自行命名，例如 `pki_intermediate`、`pki_dept_a` 等，但建议保持简洁且具有辨识度。

---

### 4.3 调整 max_lease_ttl

为 `pki_int` 挂载点设置最大租约时长为 43800 小时（约 5 年）：

```shell-session
$ vault secrets tune -max-lease-ttl=43800h pki_int
Successfully tuned mount 'pki_int'!
```

> ⚠️ **警告**：Intermediate 的 max TTL **应（should）** 小于或等于 Root CA 的 TTL。
>
> **（编者注）** 如果 Intermediate 证书的有效期超出了 Root CA 证书的有效期，那么在 Root 过期后 Intermediate 也将失效，这在验证时会造成信任链断裂。

**（编者注）** Vault 中 TTL 存在层级收敛关系：请求级 TTL ≤ Role TTL ≤ 挂载点 max_lease_ttl ≤ 证书有效期。`vault secrets tune` 设置的是挂载点级别的上限，实际签发时还可以在 Role 和请求中做更细粒度的约束。

---

### 4.4 生成 Intermediate CSR

在 `pki_int` 路径下生成一份证书签名请求（CSR），私钥由 Vault 内部生成且**永远不会导出**：

```shell-session
$ vault write pki_int/intermediate/generate/internal \
      common_name="myvault.com Intermediate Authority" \
      ttl=43800h
```

输出中的关键字段是 `csr`——一段 PEM 格式的证书签名请求。请将其保存到本地文件，以便下一步使用：

```shell-session
$ vault write -field=csr pki_int/intermediate/generate/internal \
      common_name="myvault.com Intermediate Authority" \
      ttl=43800h > pki_int.csr
```

> **提示**：`generate/internal` 中的 `internal` 表示私钥由 Vault 内部生成并托管。除此之外还有 `exported`（私钥会返回给调用者）和 `existing`（使用已导入的密钥）等方式，PKI API 也支持 `kms`（使用外部 KMS 管理的密钥）。本例使用 `internal`，这也是最常见的选择。

> **提示**：这里的 `common_name` 仅用于 CSR 的 Subject 字段，标识该 CA 的名称。真正可以签发哪些域名的证书，由后续创建的 Role 中的 `allowed_domains` 控制。

---

### 4.5 用 Root CA 签发 Intermediate 证书

把上一步得到的 CSR 提交给 Root CA 签名。在本例中，Root CA 就在同一个 Vault 实例的 `pki` 路径下：

```shell-session
$ vault write pki/root/sign-intermediate \
      csr=@pki_int.csr \
      format=pem_bundle \
      ttl=43800h
```

输出中包含以下关键字段：

| 字段 | 说明 |
| --- | --- |
| `certificate` | 签好的 Intermediate CA 证书（PEM 格式） |
| `issuing_ca` | 签发该证书的 CA（即 Root CA）的证书 |
| `serial_number` | 序列号 |
| `expiration` | 到期时间戳 |

将返回的 `certificate` 保存到本地文件：

```shell-session
$ vault write -field=certificate pki/root/sign-intermediate \
      csr=@pki_int.csr \
      format=pem_bundle \
      ttl=43800h > signed_certificate.pem
```

> **提示**：`format=pem_bundle` 会以 PEM bundle 形式输出，便于后续 `set-signed` 导入。

**（编者注）** 在现实生产环境中，Root CA 往往是**离线 CA**——存放在断网的安全环境中，只在需要签发或续签 Intermediate 证书时才启用。本例为了简化演示，Root 和 Intermediate 放在了同一个 Vault 实例中。

---

### 4.6 写回签好的证书（set-signed）

把 Root 签好的证书装回 `pki_int` 挂载点，与之前在内部生成的私钥配对：

```shell-session
$ vault write pki_int/intermediate/set-signed \
      certificate=@signed_certificate.pem
Success! Data written to: pki_int/intermediate/set-signed
```

至此，Intermediate CA 才真正可用。在 `set-signed` 完成之前，`pki_int` 无法签发任何业务证书。

整个流程可以总结为三步模式，这个模式适用于**任何外部 CA 签发场景**：

1. **Generate CSR** — 在 Vault 中生成密钥对和 CSR
2. **External Sign** — 将 CSR 交给外部（或上级）CA 签名
3. **Set Signed** — 将签好的证书导回 Vault

---

### 4.7 配置 URL

为 `pki_int` 配置颁发者证书位置和 CRL 分发点。这些 URL 会被嵌入到后续签发的每张证书的扩展字段中（AIA 和 CRL Distribution Points），客户端据此获取 CA 链或吊销列表：

```shell-session
$ vault write pki_int/config/urls \
      issuing_certificates="http://127.0.0.1:8200/v1/pki_int/ca" \
      crl_distribution_points="http://127.0.0.1:8200/v1/pki_int/crl"
```

> **提示**：这些 URL 必须手动设置，但可以随时更改。不过需要注意：URL 配置的改动只影响**之后**签发的证书，已签发证书中内嵌的 URL 不会改变。

> ⚠️ **警告**：生产环境中通常应使用对外可达的负载均衡域名（如 `https://vault.example.com/v1/pki_int/ca`），而非 `127.0.0.1`。

---

### 4.8 创建 Role

Role 是一个逻辑名称，映射到一组签发策略，用于控制可以签发哪些域名的证书、最大 TTL 等参数：

```shell-session
$ vault write pki_int/roles/example-dot-com \
      allowed_domains=example.com \
      allow_subdomains=true \
      max_ttl=72h
```

| 参数 | 说明 |
| --- | --- |
| `allowed_domains` | 允许签发的基础域名 |
| `allow_subdomains` | 设为 `true` 后允许 `foo.example.com`、`bar.example.com` 等子域名 |
| `max_ttl` | 该 Role 签出证书的最大有效期 |

注意 `max_ttl=72h` 与挂载点级别的 5 年形成了明显的收敛——这正是层级 TTL 的设计意图：越靠近叶子证书，TTL 越短，降低泄露后的影响窗口。

---

### 4.9 签发证书

一切就绪后，通过 `issue` 端点即可签发证书：

```shell-session
$ vault write pki_int/issue/example-dot-com \
      common_name=blah.example.com
```

输出包含以下字段：

| 字段 | 说明 |
| --- | --- |
| `certificate` | 签发的叶子证书 |
| `issuing_ca` | 签发该证书的 Intermediate CA 证书 |
| `ca_chain` | 信任链中的所有中间 CA 证书 |
| `private_key` | 动态生成的私钥 |
| `private_key_type` | 私钥类型（如 `rsa`） |
| `serial_number` | 证书序列号 |

一次调用即返回**动态生成的私钥 + 证书 + CA 链**，可以直接交给应用使用。

**关于 `ca_chain` 字段**：`ca_chain` 返回信任链中的所有中间 CA 证书，但**不包含 Root CA 证书**。这是因为 Root CA 通常由操作系统或浏览器的信任库提供，不需要服务端在 TLS 握手时主动发送。客户端通常需要服务端发送 leaf 证书 + intermediate 链，Root 则从本地信任库中查找。

**（编者注）** 除了 `issue` 端点之外，PKI 引擎还提供 `sign` 端点——它接受客户端自己生成的 CSR 进行签名，不会返回私钥。适用于客户端自行管理密钥的场景。

---

### 4.10 整体流程速查

从零到签发一张 Intermediate CA 颁发的叶子证书，共 **8 步**：

| 步骤 | 命令 | 说明 |
| --- | --- | --- |
| ① | `vault secrets enable -path=pki_int pki` | 挂载 Intermediate PKI 引擎 |
| ② | `vault secrets tune -max-lease-ttl=43800h pki_int` | 设置挂载点最大 TTL |
| ③ | `vault write pki_int/intermediate/generate/internal ...` | 生成 CSR |
| ④ | `vault write pki/root/sign-intermediate csr=@... format=pem_bundle ttl=43800h` | Root CA 签发 Intermediate 证书 |
| ⑤ | `vault write pki_int/intermediate/set-signed certificate=@...` | 导回签好的证书 |
| ⑥ | `vault write pki_int/config/urls ...` | 配置 AIA / CRL URL |
| ⑦ | `vault write pki_int/roles/<role> ...` | 创建签发角色 |
| ⑧ | `vault write pki_int/issue/<role> common_name=...` | 签发叶子证书 |

![Intermediate CA 八步签发流程](/images/ch3-pki/intermediate-ca-8-steps.png)

---

### 4.11 注意事项汇总

1. **TTL 链**：通常建议满足 **请求 TTL ≤ Role max_ttl ≤ 挂载点 max_lease_ttl ≤ Intermediate 证书有效期 ≤ Root 证书有效期**。实际签发结果还受 issuer 的 NotAfter 行为（如 `leaf_not_after_behavior`）影响，可能被截断或拒签。

2. **权限策略分别写**：`pki` 与 `pki_int` 虽然是同一个 secrets engine，但挂载在不同路径上，Vault 的 ACL 策略需要**分别编写**。例如只允许某团队访问 `pki_int/issue/*` 而不能碰 `pki/root/*`。

3. **`set-signed` 之前不可签发**：在 `set-signed` 完成之前，`pki_int` 挂载点没有可用的签名证书，任何 `issue` 或 `sign` 请求都会失败。

4. **URL 改动只影响后续证书**：`config/urls` 的变更只会写入之后签发的证书中，已签发证书内嵌的 AIA 和 CRL Distribution Points URL 不会被追溯更新。

5. **`format=pem_bundle`**：在 `sign-intermediate` 时使用 `pem_bundle` 格式可以返回适合导入的 PEM bundle，简化后续 `set-signed` 的操作。

6. **验证签发结果**：**（编者注）** 可以使用 `openssl` 查看签发的证书详情，确认 Issuer、Subject、AIA、CRL 等字段是否符合预期：

   ```shell-session
   $ openssl x509 -in cert.pem -text -noout
   ```

---

至此，我们已经掌握了 Root CA 和 Intermediate CA 的搭建方法。但在真正投入生产之前，还有大量"必须提前了解"的注意事项——它们将决定你的 PKI 体系能否安全、高效地运行。
## 5. 生产注意事项与最佳实践

> **核心结论**：PKI Secrets Engine 功能强大，但在生产中需要围绕安全、架构、性能、证书生命周期、角色收口和运维可观测六个维度做好规划。
> 官方原文开篇即提醒："You should read all of these _before_ using this secrets engine or generating the CA"。
> 本节将这些注意事项按逻辑分组呈现，作为上手前的"踩坑清单"。

---

### 5.1 安全基础

#### 根 CA 安全

1. **不要把外部已有的 Root CA 私钥放进 Vault**。Vault 存储虽安全但仍是网络软件，根 CA 应离线/隔离保管。如果根 CA 托管在 Vault 之外，应签发一张较短生命周期的 intermediate CA 证书，将其导入 Vault 使用。
2. **私钥只能在生成时导出**——事后无法再导出。导出能力还可以通过 ACL 路径来进一步限制。
3. **推荐 CSR 流程**：让 Vault 生成 CSR（不导出私钥），再由外部根 CA（或第二个 `pki` 挂载点）签名。这样私钥始终不离开 Vault。
4. **Managed Keys（Enterprise，自 1.10）**：使用 `kms` 类型生成 root/intermediate，私钥由外部 KMS/HSM 保管，Vault 看不到私钥。**（编者注）** 这是企业级安全增强方案，适用于对密钥保管有严格合规要求的场景。

#### 安全下限

- Vault 一直强制 **SHA256** 签名，不允许 SHA1。
- 自 0.5.1 起 RSA 至少 **2048** 位；1024 位被禁止。

#### Token 寿命与吊销

- Token 过期会吊销其下所有 lease。长寿命 CA 证书需要相应长寿命的 token，容易遗忘。
- 自 **0.6** 起，root/intermediate CA 不再关联 lease，避免了误吊销。若要主动吊销，请使用 `pki/revoke` 端点。

---

### 5.2 架构设计

#### 一个挂载点一个 CA

自 Vault 1.11 起支持单挂载多 issuer，但官方**强烈推荐**每个挂载点只挂一个 issuer。

**核心理由是权限管理**：对 root 的高权限操作与日常 leaf 签发应分开 mount——能操作 root 的人很少，但需要签 leaf 的人很多。分离后便于审计与最小权限控制。

**常见模式**：一个 mount 专门做根 CA（只用于签 intermediate CSR），其它 mount 各自承载一个 intermediate。

**CA 轮换的两种方式**：

1. **新挂载点**：创建新 mount 承载新 CA，老 mount 保留直到 CRL 过期。
2. **同 mount 多 issuer**：老 issuer 限制为只签 CRL，便于交叉签名且消费者不需改配置；过渡期结束后应清除老 issuer。

**按 TTL 拆 issuer**：短期证书用 Vault 内 intermediate（性能好），长期证书用 HSM 后端 intermediate（安全好），同 mount 共存，由 role 的 `max_ttl` 控制选择。

> ⚠️ **警告**：必须始终配置一个 **默认 issuer**（default issuer）。默认 issuer 用于未显式指定 issuer 的请求；当被吊销证书的原 issuer 已不在该 mount 时，吊销条目会落到默认 issuer 的 CRL 上。

#### 使用 CA 层级

推荐 root → intermediate(s) → leaf 的三层结构。root 离线/HSM 强保护，intermediate 在 Vault 中负责签发。

**按用途拆 intermediate**——VPN 签名、邮件签名、测试 vs 生产 TLS 等，可让各自的 CRL 更小，且高风险长寿命 intermediate 可走 HSM 而不影响易轮换 intermediate 的性能。

**Name Constraints**：可在 root/intermediate 生成时设置 `permitted_dns_domains`、`permitted_ip_ranges`、邮件域、URI 域等约束，配合 role 的 `allowed_domains` 实现多层隔离。

**Cross-Signed Intermediates**：在同一 mount 内做交叉签名时，需要 `manual_chain` 覆盖。顺序示例：`self → this root → other copy of intermediate → other root`，这样签发请求会返回完整的交叉签链。

![推荐的 CA 层级梯度（按用途拆 intermediate）](/images/ch3-pki/ca-hierarchy-by-purpose.png)

**（编者注）** 上图展示了推荐的 CA 层级梯度。实际部署中 intermediate 的数量和用途取决于业务需求，但建议至少将测试与生产环境隔离到不同的 intermediate。

#### Cluster URL 的重要性

Vault 1.13 引入 **templated AIA URLs**；结合 per-cluster URL 配置（`set-cluster-configuration`），可让 AIA 自动指向当前签发证书的 Performance Replication 集群。

> ⚠️ **警告**：必须在 **每个** Performance Replication 集群上正确设置 Cluster URL；否则证书签发（REST 和 ACME）都会失败。这是多集群部署的高频踩坑点。

---

### 5.3 性能与密钥选型

#### 密钥类型对性能的影响

- **RSA 比 EC 慢得多**：RSA 密钥生成需要找素数，耗时且不稳定；Ed25519 几乎只需要随机数据。
- **位数越大签名越慢**：RSA 2048→4096、ECDSA P-256→P-521 都会增加耗时；不仅签发慢，TLS 握手验证也会变慢。
- **`/pki/sign` 比 `/pki/issue` 快**：`sign` 不需要 Vault 生成密钥，前提是客户端有足够的熵源。
- **CA 自身密钥类型同样重要**：RSA CA 签出来的签名也是 RSA。

**存储与租约对性能的放大效应**：使用远端存储（如 Consul）+ `no_store=false` + 元数据 + 每证书 lease 会显著拖慢签发。大规模部署（≥ 250k 活动证书）建议靠 audit log 在 Vault 外追踪。

**基准数字**（仅作量级参考，30s benchmark，单节点 Raft）：

| 密钥类型 | 不存证 | 存证 | 存证 + Lease |
| --- | --- | --- | --- |
| EC P-256 | ~300k | ~65k | ~20k |
| EC P-521 | ~30k | — | ~18k |
| RSA-4096 | ~160 张 | — | — |

> **提示**：RSA-4096 的 95% 密钥生成耗时超过 10 秒。ACME 会额外增加延迟（必须存证 + 验证挑战）。

#### 集群可扩展性

大多数非读操作需要写存储，会被转发到 active 节点。以下操作可在 **Performance Standby** 上水平扩展：

- `ca[/pem]`、`cert/<serial>`、`cert/ca_chain`、`config/crl`、`certs`（list）、`ca_chain`、`crl[/pem]` 的读取
- `issue`、`sign`、`sign-verbatim` 的签发

> ⚠️ **警告**：`issue` / `sign` / `sign-verbatim` 要在 Performance Standby 上直接处理（不被转发），必须 **同时满足三个条件**：
> 1. Role 的 `no_store=true`
> 2. `generate_lease=false`
> 3. 不写元数据（`no_store_cert_metadata=true` 或未提供 `metadata`）
>
> 否则请求仍会被转发到 active 节点。

---

### 5.4 证书生命周期管理

#### 短证书寿命对 CRL 友好

Vault 的哲学是短期凭据。私钥仅在签发时返回给客户端一次，私钥丢失通常等过期即可，无需吊销。

- **CRL 重建很贵**：Vault 必须将 **所有** 已吊销证书读入内存才能重建 CRL，且客户端需要重新拉取。
- Vault 不支持滑动窗口的多 CRL 端点；建议 **不签发寿命超过你能接受的 CRL 生命周期的证书**。HA 模式可保证 CRL 端点高可用。
- 多 issuer（≥1.11）下不同 issuer 有各自 CRL，可能需要重建多份。
- **Delta CRL + OCSP（≥1.12）+ 自动重建**：让吊销不必每次都全量重建 CRL，只按计划重建。

**`leaf_not_after_behavior`（≥1.11）** 有三个选项：

| 选项 | 行为 | 推荐场景 |
| --- | --- | --- |
| `err` | 如果 leaf 的 NotAfter 超过 issuer 的 NotAfter，拒绝签发 | intermediate（强烈推荐） |
| `truncate` | 将 leaf 的 NotAfter 截断到 issuer 的 NotAfter | intermediate（可接受） |
| `permit` | 允许 leaf 的 NotAfter 超出 issuer 的 NotAfter | 仅适合 root |

> **提示**：intermediate 强烈建议设为 `err` 或 `truncate`；`permit` 仅适合 root，因为 intermediate 验链时仍会被检查 NotAfter。

**建议有效期梯度**：

- Root：2–10 年
- Intermediate：6 个月–2 年
- Leaf：30–90 天

**量级影响**：10–1000 张长期存储证书没问题；50k–100k 开始造成压力；500k+ 即使短 TTL 也会拖累大集群。过期证书应使用 tidy 清理。

**用 `no_store=true` 不存证**：当签发量大、TTL 短（官方给出的阈值是 **< 30 天**）时，可在 Role 上设置 `no_store=true`，让 Vault 签发后**不把证书写入存储**，只随响应返回给调用者。

| 维度 | 收益 | 代价 |
| --- | --- | --- |
| **吞吐** | 大幅提升（参考 5.3 基准表，"不存证"列比"存证"快 5–10 倍） | — |
| **存储 / CRL** | 存储不再随签发量线性膨胀；CRL 重建压力下降 | — |
| **集群扩展** | 满足 Performance Standby 直接处理签发的必要条件之一（见 5.3） | — |
| **吊销** | — | 无法按 serial 吊销（Vault 不知道这张证书存在） |
| **审计 / 留痕** | — | 需依赖 audit log 在 Vault 外追踪签发记录 |

> **提示**：在大签发量 + 短 TTL 场景下，`no_store=true` 是**官方推荐**做法；长 TTL + 偶尔需要主动吊销 + 量不大的场景，仍建议保留默认 `no_store=false`。

> ⚠️ **警告**：即便符合"短 TTL"条件，某些**高风险证书类型仍应保留 `no_store=false`**——典型例子是宽通配符证书（如 `*.example.com`），一旦泄漏影响面巨大，需要精确的吊销能力；而像 `service.example.com` 这类范围明确的内部服务证书，即便 90 天 TTL 也可以放心使用 `no_store=true`。决策依据是**单张证书泄漏的影响面**，不是单纯的 TTL 长度。

**BYOC（Bring Your Own Certificate，≥1.12）**：能吊销未存储的证书（调用者提交完整证书来吊销），因此 `no_store=true` 现在可以"全局安全"地使用——吊销代价从此不再是必须存证的理由。

#### 必须提前配置 issuing/CRL/OCSP URL

Vault 不知道自己被部署在哪里，必须通过 `config/urls` 手动配置颁发 CA URL、CRL 分发点和 OCSP 服务器 URL（可逗号分隔多个）。

> **（编者注）** 下例中的具体字段名（如 `ocsp_servers`）属于示例性补全；中间笔记仅给出概念，准确字段名以 PKI API 文档为准。

```shell-session
$ vault write pki/config/urls \
    issuing_certificates="https://vault.example.com:8200/v1/pki/ca" \
    crl_distribution_points="https://vault.example.com:8200/v1/pki/crl" \
    ocsp_servers="https://vault.example.com:8200/v1/pki/ocsp"
```

> **提示**：Performance Replication 环境下，每个集群有自己的 CRL，需要在 AIA 中分别列出各集群 URL，或在 Vault 外做合并分发。多 issuer 环境建议使用 per-issuer AIA 字段，而不是全局 `/config/urls`，否则链构建/自动 CRL 检测可能指向错误 issuer。

#### CRL 与 OCSP 分发

CRL 与 OCSP 响应均由 Vault 内的 CA 签名，可以通过非安全、非认证的通道（如 HTTP）分发。

> ⚠️ **警告**：OCSP GET 有一个已知问题——当编码后的请求 URL 中包含连续 `/` 时，可能出现间歇性 400 错误。建议优先使用 OCSP POST。

#### 自动化 CRL 构建与 tidy

自 1.12 起，`/config/crl` 支持自动重建（含 Delta CRL），`/config/auto-tidy` 支持自动清理过期/吊销证书。**两者都应启用**，以兼顾 PKIX 生态兼容性和性能。

> **（编者注）** 下例中的 `auto_rebuild_grace_period`、`delta_rebuild_interval`、`tidy_cert_store`、`tidy_revoked_certs`、`safety_buffer` 等具体字段及示例值属于示例性补全；中间笔记仅给出概念，准确字段以 PKI API 文档为准。

```shell-session
$ vault write pki/config/crl \
    auto_rebuild=true \
    auto_rebuild_grace_period="12h" \
    enable_delta=true \
    delta_rebuild_interval="15m"

$ vault write pki/config/auto-tidy \
    enabled=true \
    tidy_cert_store=true \
    tidy_revoked_certs=true \
    safety_buffer="72h"
```

#### 吊销支持的"光谱"

自 1.13 起，PKI 提供按集群规模和吊销量选择的多种方案。

**Cross-Cluster CRLs（仅 Enterprise Performance Replication）**：

- Performance Replication 下，issuer/role 跨集群同步，但已签发证书与吊销记录是各集群本地的。
- `cross_cluster_revocation=true`：允许在任意集群通过序列号请求吊销。主集群写"待处理吊销"，由实际持有证书的集群处理并回报。可用 `tidy_revocation_queue=true` + `revocation_queue_safety_buffer` 清理无效请求。
- `unified_crl=true`：所有集群共享统一吊销视图，CRL 与 OCSP 都受影响。统一 CRL 由主集群 active 节点重建，可能很大；必要时设置 `disabled=true` 或调大 Raft `max_entry_size`。
- 跨集群写入是同步的；失去 gRPC 连接时跨集群吊销请求会失败需重试，但本地写过的吊销记录会最终同步。

**推荐策略**（按吊销量递增排列）：

| 场景 | 建议方案 |
| --- | --- |
| 吊销少且带宽足够 | 开启 auto rebuild + cross-cluster queue + unified CRL |
| 统一 CRL 太大 | 依赖 OCSP（`unified_crls` 与 `disabled` 可独立控制） |
| 吊销/跨集群流量太高 | 分片 CRL，让 leaf 的 AIA 指向各自签发集群 |
| 极高签发量 | 用 audit log 外部追踪，`no_store=true` 让 Vault 只做签发，CRL 在外部维护 |

> **提示**：Vault 目前不支持外部签名 OCSP 请求。

---

### 5.5 Role 安全

#### 角色安全使用

Role 应当做到 **"one role, one thing"**——不要创建"万能 role"。

**不要让 root CA 直接绑定 role 签发 leaf 证书**；root 只应签发 intermediate。

**关键参数建议**：

| 参数 | 推荐值 | 说明 |
| --- | --- | --- |
| `allow_any_name` | `false`（默认） | 防止签发任意域名证书 |
| `allow_localhost` | `false`（生产） | 除非服务确实监听 localhost |
| `allow_wildcard_certificates` | `false` | 默认是 `true`（出于向后兼容）；尤其和 `allow_subdomains`/`allow_glob_domains` 组合使用时务必关闭 |
| `enforce_hostnames` | `true`（默认） | TLS 服务场景强制主机名校验 |
| `allow_ip_sans` | `false` | 默认是 `true`；除非真的需要 IP 证书 |
| `no_store` | `true`（高签发量/短 TTL 场景） | 换取吞吐量；不能按序列号吊销，但 BYOC（≥1.12）可补 |
| `key_usage` / `ext_key_usage` | 按需限制 | 默认值已适合 client/server TLS；Vault 实现 RFC 5280，生成的 key usage 扩展被标为 _critical_，无法被忽略 |

---

### 5.6 运维可观测

#### 遥测（Telemetry）

在通用请求遥测之外，PKI 额外暴露 `issue` / `sign` / `sign-verbatim` / `revoke` 的计数与耗时。指标键形如 `mount-path,operation,[failure]`，labels 包含 namespace 与 role name。

> **提示**：这些是 per-node 指标，需跨节点/集群聚合后才能反映全局状况。

#### 审计（Auditing）

Vault 默认对 audit 日志中的字符串键做 HMAC，需要 tune（un-HMAC）来获得有用信息。

**建议 un-HMAC 的请求字段**：`csr`、`certificate`（导入/重签时）、`issuer_ref`、`common_name`、`alt_names`、`other_sans`、`ip_sans`、`uri_sans`、`ttl`、`not_after`、`serial_number`、`key_type`、`private_key_format`、`managed_key_name`、`managed_key_id`、`ou`、`organization`、`country`、`locality`、`province`、`street_address`、`postal_code`、`permitted_*`、`excluded_*`、`policy_identifiers`、`ext_key_usage_oids`。

**建议 un-HMAC 的响应字段**：`certificate`、`issuing_ca`、`serial_number`、`error`、`ca_chain`（视噪音程度酌情）。

> ⚠️ **警告**：以下字段**绝对不要** un-HMAC：
> - `private_key`（响应中签发出的私钥）
> - `pem_bundle`（导入 issuer 时可能含敏感私钥）
> - `crl`（CRL 可能很大，写入日志影响性能）
> - `http_raw_body`（防止破坏日志格式）
>
> 仅启用 syslog 时若日志写不下，Vault 会以不透明 `500` 拒绝请求。建议同时启用 `file` 类型 audit 设备作为备份。

#### 基于角色的访问 / ACL

文档建议按 **5 种 persona** 划分 PKI 相关的访问控制：

| Persona | 典型职责 | 关键路径（节选） |
| --- | --- | --- |
| **Unauthed** | 无 token 的外部客户端 | 读取：`/ca`、`/ca_chain`、`/crl`、`/crl/delta`、`/cert/:serial`、`/issuers`（list）、`/issuer/:ref/(json\|der\|pem)`、`/issuer/:ref/crl`、`/ocsp/<request>`（Read）；写入：`/ocsp`（Write，POST 形式 OCSP） |
| **Requester** | 普通证书申请者 | `/certs`（list）、`/revoke-with-key`、`/roles`（list）与 `/roles/:role`（Read）、`/(issue\|sign)/:role` |
| **Advanced** | 高级签发操作 | `/issuer/:ref/(issue\|sign)/:role` |
| **Agent** | 管理 role/吊销，可能代签发 | `/config/auto-tidy`、`/config/crl`、`/config/issuers`、`/config/ca`（Read）、`/crl/rotate`、`/sign-verbatim`、`/revoke`、`/tidy*`、role 写、issuer 读 |
| **Operator** | 全权管理 issuer/key | `/config/*`（Write）、issuer/key 生成、import、根/中间签名、`/root/*`、`/keys/*` 等高权限路径 |

> **提示**：使用 Managed Keys 时还需额外的 `sys/mounts` 读取权限和 managed-keys API 权限。

---

### 5.7 企业版与已知问题

#### 复制下的数据集（Enterprise Performance Replication）

| 跨集群同步 | 不跨集群（本地数据） |
| --- | --- |
| Issuers & Keys、Roles、CRL Config、URL Config、Issuer Config、Key Config | CRL、Revoked Certificates、Leaf/Issued Certificates、Certificate Metadata |

**含义**：`no_store=false` 的 leaf 证书仅存在于签发它的集群。主集群与 PR Secondary 的 active 节点都能签发以提升扩展性，但每个集群有自己的 CRL；要么在外部做统一 CRL，要么应用方知道要拉所有集群的 CRL。

#### ACME 安全考量

Vault 1.14 引入了 ACME（RFC 8555）服务端支持。ACME 的安全考量涉及验证挑战的外部请求、EAB 策略、公网暴露等多个维度。**（编者注）** ACME 的详细用法与安全配置将在后续 ACME 专题章节中展开，此处仅概述要点：默认威胁模型复杂，公网可达的 Vault 强烈建议强制 `eab_policy=always-required`。

#### PSS 支持限制

- Go 不支持使用 `rsaPSS` OID（`1.2.840.113549.1.1.10`）的证书/Key/CSR；Vault 要求一律使用 `rsaEncryption` OID（`1.2.840.113549.1.1.1`）。
- OpenSSL 从 PKCS8 PSS 私钥生成的 CA/CSR 会带 `rsaPSS` OID，会被 Vault 拒绝。**解决方案**：先转为 PKCS#1v1.5 私钥再签 CSR。Vault 仍可按 role/签名机制使用 PSS 签名（SubjectPublicKeyInfo 与 SignatureAlgorithm 是正交的）。
- **限制**：Go 不支持以 PSS 算法签 CSR。当 managed key（如 GCP / PKCS#11 HSM）要求 PSS 时，`pki/intermediate/generate/kms` 会因签名校验失败而出错。**解决方案**：在 Vault 外生成 CSR，再导入签好的最终证书。
- Go 也不支持以 PSS 签 OCSP 响应；Vault 会自动把 PSS 吊销签名算法降级为 PKCS#1v1.5，但某些 KMS（HSM、GCP）可能不允许同一 key 同时支持两种签名方案，导致 OCSP 响应签名失败返回内部错误。

#### Issuer 存储迁移问题

升级到多 issuer 存储布局（影响版本：< 1.11.6 / < 1.12.2 / < 1.13）期间若发生写错误，默认 issuer 的 `ca_chain` 可能只剩 self-reference。

**日志特征**：`failed to persist issuer ... chain to disk: <cause>`，且仅在 mount 含多个 issuer 时出现。

**手工修复步骤**：

```shell-session
$ vault patch pki/issuer/default manual_chain="self"
$ vault patch pki/issuer/default manual_chain=""
$ vault read pki/issuer/default
```

先设置 `manual_chain="self"` 再改回空值，触发链重建，然后验证 `ca_chain` 是否正确。

#### Issuer 约束强制

自 1.18.3（含对应企业版 1.18.3+ent / 1.17.10+ent / 1.16.14+ent）起，Vault 在签发 leaf 时会额外校验 issuer 的约束扩展（extended key usage、name constraints、issuer name 复制是否正确）。

报错应通过修正 issuer 证书自身来解决。可用环境变量 `VAULT_DISABLE_PKI_CONSTRAINTS_VERIFICATION=true` 完全关闭校验，但官方明确警告这是 **"last resort"**。

#### 自动化 leaf 证书续期

推荐自动化续签 leaf 证书，可选方案：

- **Vault Agent 模板**：基于证书的 `validTo` 自动触发续期。
- **cert-manager**：Kubernetes/OpenShift 环境下使用 cert-manager + Vault CA，由 cert-manager 自动管理证书生命周期。

---

掌握了生产注意事项后，我们进入一个更高级的话题——当 CA 证书到期或需要更换时，如何平滑轮换而不影响已签发的叶子证书？
## 6. 轮换原语——Cross-Sign、Reissue 与 Temporal

> **核心结论**：自 Vault 1.11.0 起，PKI Secrets Engine 支持单个 mount 中存在多个 issuer，
> 这是所有轮换原语得以实现的前提。本节把根/中间 CA 的轮换抽象成三种"原语（primitives）"——
> Cross-Sign、Reissue 与 Temporal，理解它们的本质后再进行组合，即可应对绝大多数轮换场景。
> 请牢记一个关键观察：**信任真正取决于密钥材料，而不是证书对象**。

---

### 6.1 背景：单 mount 多 issuer

Vault 1.11.0 引入了"单 mount 多 issuer"能力——同一个 PKI mount point 下可以同时存在多个 issuer（即多个 CA 证书/密钥对）。这意味着新旧 CA 可以在同一 mount 内共存，签发的叶子证书与链可以灵活指向不同的 issuer。

没有这项能力，每一次 CA 轮换都意味着创建全新的 mount、迁移所有 role 配置、切换所有消费方——代价极高。单 mount 多 issuer 是后续三种轮换原语的前提。

---

### 6.2 X.509 证书字段回顾（与轮换相关）

在讨论轮换原语之前，需要先弄清楚：X.509 证书里哪些字段决定了"信任传递"，哪些字段在轮换时会发生变化。

**（编者注）** 一个基础约束需要牢记：一张证书只能有一个 Issuer；Issuer 由签发证书的 Subject + 公钥共同标识。一个密钥对可以被多张证书使用，但一张证书只能绑定一份密钥材料。

以下是与轮换直接相关的字段：

| 字段 | 说明 | 轮换影响 |
| --- | --- | --- |
| **Subject Public Key Info** | 公钥材料（私钥不在证书中，但由公钥唯一确定） | Cross-Sign 与 Reissue 都要求复用同一密钥材料 |
| **Subject** | 标识证书归属实体；轮换时通常需保持一致 | SAN 主要用于 TLS 主机名校验，对中间证书链验证不那么关键 |
| **Validity（notBefore / notAfter）** | 有效期范围 | RFC 5280 不强制子证书有效期不超过签发者，但要求若无法维持吊销状态应提前撤销 |
| **Issuer / signatureValue** | Issuer 字段填的是签发者的 Subject；signatureValue 是签发者私钥对整张证书的签名 | Cross-Sign 时 Issuer 会不同；Reissue 时 Issuer 保持一致 |
| **Authority Key Identifier (AKI)** | 可包含签发者公钥的 hash，或签发者 Subject + Serial Number | Vault 只写入公钥 hash 形式；后一种形式会阻断轮换（见 6.8） |
| **Serial Number** | 同一签发者下唯一 | 无论 Cross-Sign 还是 Reissue，Serial Number 一定改变 |
| **CRL Distribution Points** | 告诉验证方去哪里取 CRL | 主要是信息性的；中间证书被吊销时会出现在父 CA 的 CRL 上，可能阻断轮换 |

关于 Validity 的几个细节：

- `leaf_not_after_behavior` 是 per-issuer 设置（而非 per-role），通过 `/pki/issuer/:issuer_ref` 端点配置。
- 浏览器对 trust store 中的受信任根证书有时会"忽略过期"，但中间证书仍会按有效期严格校验。

> ⚠️ **警告**：根证书通常不可吊销（not revocable）。但如果一个中间证书被按 serial 吊销，它会出现在父 CA 的 CRL 上，这可能阻止轮换流程的正常进行。

---

### 6.3 轮换的整体思想

并非所有证书轮换的难度都相同。

**叶子证书的轮换是"日常"操作**。替换证书并重载服务即可，依赖的是 trust store 中的 CA 而非叶子证书自身。在 Vault 中通过 `/pki/issue/:name`、`/pki/sign/:name`，或者 ACME（RFC 8555）完成。

**中间证书的轮换"几乎一样简单"**——前提是运维到位：叶子签发时服务配置中的完整证书链会被同步更新。操作就是生成新中间 CA → 由根签发 → 切换到新中间签发；只要老的链仍然受信，老叶子继续可验证。

**（编者注）** Let's Encrypt 就是通过 cross-sign 来解决老 Android 设备的兼容性问题的。

**真正困难的是根证书轮换**。根证书分布在所有终端的 trust store 中，组织级的更新通常以"月"为单位。

以下是贯穿全节的**关键观察**：

> **信任真正取决于密钥材料，而不是证书对象。** 两张拥有相同 Subject 但不同公钥的 issuer 证书，无法验证同一张叶子证书；只有当密钥材料相同时才可以。

理解这个观察后，三种轮换原语就变得自然了。

---

### 6.4 Cross-Sign 原语

#### 概念

Cross-Sign 是最常见的轮换原语。其核心思路：同一份 CSR 由两个不同的 CA 签发，得到两张证书。这两张证书拥有**相同的 Subject、相同的公钥（密钥材料）**；但 Issuer **可能**不同，Serial Number **一定**不同。

Cross-Sign 通常**只用于中间 CA**——因为终端服务/校验库一般只接受单一叶子证书。

两次签名不必同时进行，间隔可达数年。一份 CSR 可以被多个根 cross-sign，无数量限制。

#### 流程

```
generate key pair
    ├── generate CSR ── signed by root A ── intermediate C
    └── generate CSR ── signed by root B ── intermediate D
```

#### 证书层次

任一 root 在 trust store 中均可验证 leaf：因为 intermediate C 和 intermediate D 的密钥材料相同，leaf 的 signatureValue 无论走哪条链都能被验证。

**本质**：Cross-Sign 是一种"统一原语"——把两条独立的信任路径合并为一条对 leaf 透明的路径。

![Cross-Sign 的信任路径合并图](/images/ch3-pki/cross-sign-trust-merge.png)

#### Cross-Signed roots 的注意事项

两个 root 之间也可以互相 cross-sign，但产物本质上是一张"看起来像 root 的中间证书"（因为不再是自签名），通常需要随信任链一起下发。

> **提示**：更优做法是 cross-sign 顶层中间证书，而不是 root——除非旧 root 历史上直接签发过叶子证书。

#### 在 Vault 中执行

Cross-Sign 在 Vault 中分三步：

1. **生成 CSR**：使用 `/intermediate/cross-sign` 端点。当用 `cert A` 去 cross-sign `cert B` 时，需要在 generation 阶段提供 `cert B` 的 `key_ref`、Subject 等参数。

2. **签发**：使用 `/issuer/:issuer_ref/sign-intermediate` 在 `cert A` 下签发，传入 `cert B` 的 Subject 等字段。`cert A` 可以位于 Vault 之外。

3. **导入**：通过 `/issuers/import/cert` 导入交叉签名证书。

成功后（前提：`cert A`、`cert B` 及其 key material 都在该 Vault 内）：cross-sign 证书的 `ca_chain` 会包含 `cert A`；`cert B` 的 `ca_chain` 会包含该 cross-sign 证书及其链。

> ⚠️ **警告**：Vault 不会自动从已有 issuer 推断 Subject 等参数，它仅复用相同的密钥材料。所有 Subject 字段必须显式传入。

#### `manual_chain` 注意事项

若一对 cross-sign 证书都被导入到**同一 mount**，Vault 自动构链时只会使用其中一条路径——因为 leaf 签发时 `ca_chain` 直接复制自签发 issuer。

修复方式是在 issuer 上设置 `manual_chain`，显式指定完整的 cross-sign 链：

```shell-session
$ vault patch pki/issuer/intA manual_chain=self,rootA,intB,rootB
$ vault patch pki/issuer/intB manual_chain=self,rootB,intA,rootA
```

这样 leaf 签发时就会带上完整的 cross-sign 链，客户端可以选择任一路径完成验证。

---

### 6.5 Reissue 原语

#### 概念

Reissue（重签发）是指用**已有的密钥材料**生成新证书，通常发生在原证书快过期或已过期时，由原父 CA 重新签发。自签名（root）情况下，父 CA 就是自己。

与 Cross-Sign 的区别：Cross-Sign 强调"不同签发者"，Reissue 强调"同签发者、不同时间"。

适用范围更广：**leaf、intermediate、root 都可以使用** Reissue。

因为 Serial Number 必然变更，证书内容会变化，但所有现存 leaf 的签名仍然有效——因为密钥未变。

**（编者注）** 可以把 Reissue 理解为"延长护照有效期但不换人"——身份（密钥）不变，只是证件（证书）更新了。

#### 流程

```
generate key pair（保存）
   └── generate CSR（同字段）── signed by issuer ── 时间点 T1
                              └── signed by issuer ── 时间点 T2
                              └── signed by issuer ── 时间点 T3 ...
```

同一密钥可被多次 reissue，但出于安全考虑应在某个时间点真正轮换密钥，而非无限续期。

#### 证书层次

```
            root
       ┌─────┴─────┐
original cert  reissued cert   （同一密钥材料）
            │
       leaf certificates
```

**特性**：reissued root 可作为中间证书出现在 TLS 链中，链回 trust store 里仍存在的旧 root。

**定位**：Reissue 是一种"递增原语"——延长既有密钥的生命周期。

![Reissuance 的时间线图](/images/ch3-pki/reissuance-timeline.png)

#### 在 Vault 中执行

**Reissue root**：

使用 `/issuers/generate/root/existing` 端点，通过 `key_ref` 复用密钥。成功后两个 issuer 互相出现在对方的 `ca_chain` 中（除非被 `manual_chain` 阻止）。

**Reissue intermediate**（三步）：

1. 使用 `/issuers/generate/intermediate/existing`，通过 `key_ref` 生成新 CSR；
2. 由父 CA（可能在 Vault 之外）签名；
3. 通过 `/intermediate/set-signed` 导入签好的证书。

成功后：两个 issuer 的 `ca_chain` 仅首项不同（除非被 `manual_chain` 阻止）。

> **提示**：与 Cross-Sign 一样，Vault 不会自动推断 Subject 等参数，必须显式传入。

---

### 6.6 Temporal 原语

Temporal 原语在 Cross-Sign / Reissue 的基础上引入**时间维度**，用于将 root 轮换到新密钥并延长整体寿命。分两种方向：

**Forward primitive（向前担保）**：用旧证书去为新密钥背书。

示例：DST Root CA X3 → ISRG Root X1。旧根 CA 签发一张中间证书，该中间证书使用的是新根的密钥材料，从而让仅信任旧根的客户端也能验证新根签发的叶子证书。

**Backwards primitive（向后担保）**：用新证书去为旧密钥背书。

示例：ISRG Root X1 → R3（R3 原由 DST Root CA X3 签发）。新根 CA 签发一张中间证书，使用的是旧中间的密钥材料，确保已经切到新根的客户端也能验证旧链签出的叶子。

#### 典型建议

- 对于分层 CA 架构的组织，把所有中间证书用新旧两个根分别 cross-sign，通常就够了。
- 若历史上**直接用 root 签过叶子证书**，则需把旧 root 作为新 root 下的 reissue（更短有效期），结合两种原语形成 backwards primitive；并建议未来转向标准分层结构。

---

### 6.7 原语的局限性

三种原语并非万能，存在以下限制：

**AKI 格式问题**：如果证书中的 Authority Key Identifier 使用的是"Issuer Subject + Serial Number"形式（而非公钥 hash 形式），会阻断 Cross-Sign 与 Reissue。Vault 原生不会生成这种 AKI 格式，且 Vault 严格使用随机 serial，所以 Vault 签发的证书是安全的；但导入外部证书时需要注意。

**Serial 唯一性要求**：浏览器和校验引擎会缓存证书，要求 serial 唯一。严格来讲，Cross-Sign 时（来自不同 CA）可以复用相同 serial（只要那个 CA 没用过），但 Reissue 不行——因为 Reissue 本质上是同一签发者，该签发者必须签发具有唯一 serial number 的证书。

> ⚠️ **警告**：在引入外部签发的证书到 Vault PKI 体系之前，务必确认其 AKI 格式为公钥 hash 形式，否则后续的 Cross-Sign 和 Reissue 操作可能会失败。

---

### 6.8 推荐的根证书轮换流程

以下是假设组织遵循最佳实践（分层 CA 架构）时的推荐轮换流程，共 6 步。整个过程的耗时与自动化程度强相关。

![推荐根轮换 6 步流程图](/images/ch3-pki/root-rotation-6-steps.png)

#### 第 1 步：生成新 root

生成一个新的根证书。建议使用新的 Common Name 以便区分新旧 root。密钥材料**无需**与旧 root 相同——这里正是引入全新密钥的时机。

> **提示**：实际端点参考 `/issuers/generate/root/...`，具体参数见官方 API 文档。

#### 第 2 步：Cross-Sign 所有现存中间证书

用新 root 对所有现存中间证书执行 Cross-Sign，并按 6.4 节的说明设置 `manual_chain`。这样服务在续签时，拿到的 `certificate` + `ca_chain` 中会同时包含新旧两条信任路径。

#### 第 3 步：推动叶子证书续签

让所有叶子证书续签以拿到新的 cross-sign 链：

- **短寿命证书**可自动完成（配合自动化续签机制）。
- **长寿命证书**（服务器证书、代码签名证书、客户端认证证书）需要主动手动轮换。

> ⚠️ **警告**：这一步通常是整个流程中耗时最多的环节。

#### 第 4 步：验证新 root 可用性

链全部更新后，新部署的系统可以只安装新 root 即上线，与所有已更新链的老系统互通。

#### 第 5 步：一次性切根

在所有终端同时添加新 root、移除旧 root。落后或离线的设备会拖慢这一步的推进速度。

#### 第 6 步：清理与归档

所有系统都使用新 root 后，安全地移除/归档旧 root 和旧 intermediate，并更新 `manual_chain` 使其仅指向新链。

---

### 6.9 小结

| 原语 | 核心特征 | 密钥是否变化 | 签发者是否变化 | 适用对象 |
| --- | --- | --- | --- | --- |
| **Cross-Sign** | 同一密钥被不同 CA 签发 | 不变 | 变化 | 主要用于中间 CA |
| **Reissue** | 同一密钥被同一 CA 在不同时间签发 | 不变 | 不变 | leaf / intermediate / root 均可 |
| **Temporal** | 在前两者基础上引入时间维度 | 可变（引入新密钥） | 视方向而定 | root 轮换到新密钥 |

三种原语的共同基础是那个关键观察：**信任跟着密钥走，不跟着证书对象走**。只要密钥材料相同，无论证书如何变化，已签发的叶子证书都能被验证。

在 Vault 中执行这些原语时，务必记住：**Vault 不会自动推断字段，所有参数必须显式传入**。

---

最后一个话题：如何利用 ACME 协议实现证书的全自动申请与续期，以及遇到问题时如何排查。
## 7. ACME 自动化与故障排查

> **核心结论**：ACME（Automatic Certificate Management Environment）是 IETF 标准协议（RFC 8555），
> 用于自动化客户端向 CA 证明域名所有权并申请叶子证书。
> Vault PKI 引擎原生支持 ACME 协议，提供多目录（directory）结构、外部账户绑定（EAB）以及灵活的策略控制，
> 让组织在保持安全管控的前提下实现证书生命周期的全自动化。

---

### 7.1 ACME 协议简介

传统的证书申请流程通常需要人工生成 CSR、提交给 CA、等待审核、下载证书——每一步都容易出错且耗时。ACME 协议（RFC 8555）将这一切标准化并自动化：客户端向 ACME CA 发起请求，通过**挑战（Challenge）**证明对域名的所有权，验证通过后 CA 自动签发证书。

ACME 协议定义了三种主流挑战类型：

| 挑战类型 | 验证方式 | 适用场景 |
| --- | --- | --- |
| **HTTP-01** | 客户端在目标域的 HTTP 端点放置指定资源（`/.well-known/acme-challenge/`） | 有公网 80 端口的 Web 服务器 |
| **DNS-01** | 客户端在目标域的 DNS 中添加指定 TXT 记录 | 通配符证书、无公网 HTTP 入口的场景 |
| **TLS-ALPN-01** | 客户端在目标域的 443 端口提供带有特定 ALPN 扩展的 TLS 握手 | 只开放 443 端口的场景 |

挑战的核心工作原理：客户端在目标域上放置特定资源，ACME CA（此处即 Vault）从外部验证该资源是否存在，从而证明客户端确实控制该域名。

![ACME 挑战流程示意图](/images/ch3-pki/acme-challenge-flow.png)

> **（编者注）** ACME 协议最广为人知的实现是 Let's Encrypt。Vault PKI 引擎作为 ACME CA 时，工作原理相同，但证书由组织自己的 PKI 体系签发。

---

### 7.2 Vault PKI 的 ACME 目录

Vault PKI 支持多个 ACME directory，每个 directory 在默认配置、issuer、role 上各有不同。通过不同的 URL 路径，ACME 客户端可以连接到不同的 directory，从而获得不同的证书签发行为。

#### 7.2.1 目录路径表

| 目录路径 | 说明 |
| --- | --- |
| `/pki/acme/directory` | 顶层目录，行为取决于 `default_directory_policy` |
| `/pki/issuer/:issuer_ref/acme/directory` | 指定 issuer |
| `/pki/roles/:role/acme/directory` | 指定 role |
| `/pki/issuer/:issuer_ref/roles/:role/acme/directory` | 同时指定 issuer 与 role |
| `/pki/external-policy(/:policy)/acme/directory` | 使用 CIEPS（企业版） |
| `/pki/issuer/:issuer_ref/external-policy(/:policy)/acme/directory` | issuer + CIEPS（企业版） |

> **提示**：如果不需要精细控制，直接使用顶层目录 `/pki/acme/directory` 即可，其行为由 `default_directory_policy` 决定。

#### 7.2.2 `default_directory_policy` 四种取值

| 取值 | 行为 |
| --- | --- |
| `forbid` | 禁用该目录，ACME 客户端访问时会被拒绝 |
| `sign-verbatim` | 类似 Sign Verbatim，但加上 ACME 协议的所有权验证；只要客户端能证明对标识符的所有权就签发证书 |
| `role:role_ref` | 强制 ACME 挑战验证，并使用指定 role 限制证书内容（如域名白名单、TTL 等） |
| `external-policy` | 强制 ACME 挑战验证，但用 CIEPS（Certificate Issuance External Policy Service）替代 role 来验证和模板化证书（企业版功能）；可用 `external-policy:policy` 形式显式指定 policy 名称 |

> ⚠️ **警告**：`sign-verbatim` 模式下，只要 ACME 挑战通过，客户端请求的任何域名都会被签发证书。生产环境应优先使用 `role:role_ref` 来限制允许的域名范围。

---

### 7.3 外部账户绑定（EAB）

#### 7.3.1 EAB 是什么

ACME 外部账户绑定（External Account Binding，EAB）可以强制客户端在向 Vault 注册 ACME 账户前，先持有 Vault 颁发的有效外部账户绑定凭据。

**（编者注）** ACME 请求不走传统 Vault 认证（Token、AppRole 等），而是走 ACME 协议本身的认证机制。EAB 只在初次注册时由已认证的 Vault 客户端获取，再交给 ACME 客户端使用。EAB token 只把 ACME 注册绑定到一个已认证的 Vault endpoint，而不绑定具体 client entity 或其他信息。

#### 7.3.2 创建 EAB Token

EAB Token 包含 key identifier 与 HMAC key，由 ACME 客户端用于 EAB 鉴权。创建命令：

```shell-session
$ vault write -f /pki/acme/new-eab
```

该命令返回 `id` 与 `key` 两个字段。

#### 7.3.3 配合 Certbot 使用 EAB

将 EAB 的 `id` 和 `key` 传递给 ACME 客户端（以 Certbot 为例）：

```shell-session
$ certbot certonly \
    --server https://localhost:8200/v1/pki/acme/directory \
    --eab-kid <id> \
    --eab-hmac-key <hmac-key>
```

#### 7.3.4 公网部署建议

> ⚠️ **警告**：如果 Vault 暴露在公网上，强烈建议启用 EAB 以防止未授权的证书签发。可使用环境变量 `VAULT_DISABLE_PUBLIC_ACME` 强制为所有 ACME 实例开启 EAB。

---

### 7.4 在 PKI 挂载上启用 ACME

#### Step 1：调整 mount 的 allowed_response_headers

ACME 协议依赖 `Link`、`Location`、`Replay-Nonce` 三个 HTTP 响应头做 nonce 交换、资源定位和目录跳转。必须在 PKI 挂载上 tune 放行这些头：

```shell-session
$ vault secrets tune \
    -allowed-response-headers=Link \
    -allowed-response-headers=Location \
    -allowed-response-headers=Replay-Nonce \
    pki/
```

**（编者注）** 如果不执行此步骤，ACME 客户端将无法正确解析 Vault 的响应，导致协议握手失败。

#### Step 2：配置 cluster path 与 ACME 参数

cluster path 决定了 ACME directory 给客户端返回的基础 URL：

```shell-session
$ vault write pki/config/cluster path=https://cluster-b.vault.example.com/v1/pki
```

配置 ACME 主参数：

```shell-session
$ vault write pki/config/acme \
    enabled=true \
    default_directory_policy="role:role-acme-a" \
    eab_policy="always-required" \
    allowed_roles="role-acme-a,role-acme-b"
```

关键字段说明：

| 字段 | 作用 |
| --- | --- |
| `enabled` | 开启 ACME 支持 |
| `default_directory_policy` | 控制顶层目录的签发策略 |
| `eab_policy` | 设为 `always-required` 时强制所有 ACME 注册必须携带 EAB |
| `allowed_roles` | 限制可通过 ACME 使用的 role 范围 |

> **提示**：以上配置是一个"生产级安全配置"的最小模板——启用 ACME、限定允许的 role、强制 EAB，三者缺一不可。

---

### 7.5 故障排查

#### 错误 1：`ACME feature requires local cluster 'path' field configuration to be set`

**症状**：在 Performance Secondary 节点上读取 `/config/acme` 或 ACME 客户端连接 directory 时报该错误。如果 ACME 在某些节点能用而在另一些节点不能用，通常意味着该集群地址未设置。

**原因**：cluster 配置参数中缺少 cluster address。

**修复**：每个 Performance Replication 集群都需要单独配置 `/config/cluster` 的 `path` 字段，应指向该 mount 在本集群上 TLS 可达的地址（可以是负载均衡器或 DNS 轮询地址）：

```shell-session
$ vault write pki/config/cluster path=https://cluster-b.vault.example.com/v1/pki
```

配置完成后，重新读取确认无 warning：

```shell-session
$ vault read pki/config/acme
```

**（编者注）** 在 Vault Enterprise 的 Performance Replication 架构中，每个 PR 集群都有独立的网络地址，因此每个集群都必须单独配置 cluster path。

---

#### 错误 2：`Unable to register an account with the ACME server`

**症状**：客户端注册新账户失败，提示 "Unable to register an account with ACME server"。Certbot debug log 中可能看到 "Server requires external account binding"，或客户端报 "The request must include a value for the 'externalAccountBinding' field"。

**原因**：服务端配置了 `eab_policy=always-required` 后，新账户注册和已有账户复用都会失败——必须用 Vault 颁发的 EAB token 创建一个新账户。EAB 用于 initial registration，不能给已有账户的复用补带。

**修复步骤**：

1. 用 Vault token 申请新的 EAB：

```shell-session
$ vault write -f pki/roles/my-role-name/acme/new-eab
```

该命令返回 `directory`、`id`、`key` 三个字段。

2. 把 EAB 传给 ACME 客户端（以 Certbot 为例）：

```shell-session
$ certbot certonly \
    --server https://cluster-b.vault.example.com/v1/pki/roles/my-role-name/acme/directory \
    --eab-kid <id> \
    --eab-hmac-key <hmac-key>
```

> ⚠️ **警告**：传给 ACME 客户端的 directory URL 必须与申请 EAB 时使用的 directory **完全匹配**。

---

#### 错误 3：`Failed to verify eab`

**症状**：客户端报 "The client lacks sufficient authorization :: failed to verify eab"。

**原因**：EAB token 与所用 directory 不匹配——在 A directory 申请的 EAB 却用于向 B directory 注册。

**修复**：**directory ↔ new-eab 的路径必须配对**。对路径 `/some/path/acme/directory`，必须从对应的 `/some/path/acme/new-eab` 获取 EAB token。例如：

- 如果使用 `/pki/roles/my-role/acme/directory`，则 EAB 必须从 `/pki/roles/my-role/acme/new-eab` 获取
- 如果使用 `/pki/acme/directory`，则 EAB 必须从 `/pki/acme/new-eab` 获取

**（编者注）** 这是最容易踩的坑——特别是在组织内有多个 role 和 directory 时，一定要确认 EAB 申请路径与 ACME 注册路径一致。

---

#### 错误 4：`ACME validation failed for {challenge_id}`

**症状**：Vault server 日志或 ACME 客户端获取证书时报类似错误：

```
ACME validation failed for a465a798-...-tls-alpn-01: ...
```

说明服务端无法验证客户端选择的挑战。

**原因**：Vault 通过客户端选择的挑战类型（`dns-01` / `http-01` / `tls-alpn-01`）无法验证服务身份，因此不会签发证书。

**修复方向**：

这是网络层错误，需从 **Vault 出站连通性** 和 **被验证主机入站端口** 两端排查：

| 挑战类型 | Vault 需要连通的目标 |
| --- | --- |
| `dns-01` | DNS 服务器（需放行相应 DNS 查询流量） |
| `http-01` | 目标机的 **80** 端口 |
| `tls-alpn-01` | 目标机的 **443** 端口 |

- 确保从 Vault server 角度 DNS 配置正确，必要时通过 `dns_resolver` 设置自定义 DNS 解析器
- 检查防火墙规则，确认 Vault 能通过相应端口访问目标主机

---

#### 错误 5：`account in status: revoked`

**症状**：续签证书时客户端报 "The client lacks sufficient authorization: account in status: revoked"。

**原因**：执行手动 `tidy_acme`，或开启了 auto-tidy 且 `tidy_acme=true` 时，Vault 会周期性清理过期的 ACME 账户。使用已被清理账户的客户端连接会被拒绝。

**修复**：根据 ACME 客户端文档清除本地缓存配置，重新建立账户（如果服务端启用了 EAB，还需要重新申请 EAB token）。

> **提示**：在配置 tidy 相关参数时，请充分评估清理周期和 `tidy_acme` 开关的影响，避免在证书续签窗口期内清理掉仍在使用的 ACME 账户。

---

### 7.6 寻求帮助时需要提供的信息

当 ACME 相关问题需要向社区或 HashiCorp 支持团队求助时，请准备以下信息：

| 信息项 | 说明 |
| --- | --- |
| **ACME 客户端名称与版本** | 例如 Certbot 2.x、Caddy 2.x、acme.sh 等 |
| **ACME 客户端的日志/输出** | 包含完整的错误信息和调试输出 |
| **Vault server 的 DEBUG 级别日志** | 设置 `log_level = "debug"` 后复现问题并收集日志 |

> **（编者注）** DEBUG 级别日志可能包含敏感信息，提交前请做脱敏处理。

---

### 7.7 延伸阅读

- [Build Your Own Certificate Authority (CA)](https://developer.hashicorp.com/vault/tutorials/secrets-management/pki-engine) — 从零构建 CA 的入门教程
- [PKI Secrets Engine with Managed Keys](https://developer.hashicorp.com/vault/tutorials/enterprise/managed-key-pki) — 企业版托管密钥与 PKI 引擎集成
- [PKI Secrets Engine API 参考](https://developer.hashicorp.com/vault/api-docs/secret/pki) — 完整 API 文档
- [Use ACME with Caddy](https://developer.hashicorp.com/vault/tutorials/secrets-management/pki-acme-caddy) — 与 Caddy 集成的官方教程

---

## 小结

本章从七个维度全面覆盖了 Vault PKI Secrets Engine 的核心知识：

1. **概念入门**——理解 PKI 引擎的定位、短 TTL 哲学与基础术语。
2. **最小可用链路**——六步跑通从启用到签发的完整流程。
3. **Root CA 快速搭建**——用自签名模式最快体验 CA 签发。
4. **Intermediate CA 快速搭建**——生产推荐的分层架构实操。
5. **生产注意事项**——安全、性能、密钥选型、CRL/OCSP、Role 收口、ACL 设计。
6. **轮换原语**——Cross-Sign、Reissue、Temporal 三板斧，应对 CA 生命周期管理。
7. **ACME 自动化**——让证书续期不再需要人工介入，并掌握常见故障的排查方法。

掌握这些内容后，你已经具备在生产环境中运营 Vault PKI 体系的基础能力。建议根据实际需求，进一步参考官方 API 文档和 Terraform Provider 进行自动化部署。

---

## 互动实验

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch3-pki"/>



