---
order: 71
title: 7.1 章节导览与三种接入形态选型
group: 第 7 章：应用自动化接入与 Kubernetes 云原生集成
group_order: 70
---

# 7.1 章节导览与三种接入形态选型

> **核心结论**：应用程序在使用 Vault 时，必须先取得一枚客户端令牌
> （client token），然后再用这枚令牌去读取真正想要的机密。把这套
> 「先认证、再续期、再读取」的流程写进每一个应用，会带来代码维护和
> 测试的额外成本。Vault 通过三类辅助组件——**本机进程 Vault Agent**、
> **独立守护进程 Vault Proxy**、以及 **Kubernetes 平台层的三件套
> （Vault Secrets Operator / Vault Secrets Store CSI provider /
> Vault Agent Injector）**——把这部分流程下沉到应用之外完成。本章后续
> 各节会逐一展开，本节先建立统一心智模型并给出选型对照。

参考：
- [Why use Agent or Proxy? — Vault Docs](https://developer.hashicorp.com/vault/docs/agent-and-proxy)
- [Run Vault on Kubernetes — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes)
- [Kubernetes integrations comparison — Vault Docs](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/comparisons)
- 已学衔接：[4.4 Kubernetes 认证](/ch4-k8s)、[4.9 JWT/OIDC 认证](/ch4-jwt)、[5.6 Vault Proxy CLI](/ch5-vault-proxy)、[3.11 Kubernetes 机密引擎](/ch3-k8s)

---

## 1. 应用接入 Vault 的"最后一公里"问题

Vault 对绝大多数 API 请求都要求带上一枚有效的客户端令牌（client
token），这一限制同样适用于 CLI 与各语言的官方 SDK。也就是说，应用
程序想要从 Vault 读取任何一条机密之前，必须先选择一种认证方法完成
登录、取得令牌，再用这枚令牌发起后续业务请求。

如果直接把这套逻辑写进应用代码，业务工程师就要承担两类与业务无关的
工作：一类是调用 Vault 认证 API 取得令牌、保存令牌、定期续期或失败
重试；另一类才是真正的「读机密」请求。这意味着每一个接入 Vault 的
应用都要被改造、被测试、被持续维护，从而显著抬高了接入成本。

对于应用数量不多、且团队希望对每个应用与 Vault 之间的交互细节保持
严格控制的场景，把这套逻辑写在应用里反而是合理的；但对于应用数量
庞大的大型企业，往往缺乏对每个应用持续维护一份 Vault 集成代码的
资源与专业能力；又或者，应用本身是由第三方部署进来的，不允许向其
中加入额外的 Vault 集成代码。

为了在不修改应用代码的前提下解决这一难题，Vault 引入了 Vault Agent
与 Vault Proxy：Agent 负责取得机密并以多种方式提供给应用使用；Proxy
负责在应用与 Vault 之间充当代理，可以选择性地简化认证过程并对请求
进行缓存。两者均不需要 Vault 企业版授权，包含在所有 Vault 二进制和
官方镜像中；少量特性（例如静态机密缓存）只有连接到企业版服务器时
才可用。

在 Kubernetes 环境中，HashiCorp 提供三套官方原生集成，让工作负载
在不修改应用代码的前提下消费 Vault 机密：Vault Secrets Operator、
Vault Secrets Store CSI provider、以及 Vault Agent Injector。

![应用在没有 Agent / Proxy 时必须自行管理"先认证再读机密"的全部步骤；引入辅助组件后，这部分流程被外移到应用之外](/images/ch7-overview/last-mile-problem.png)

---

## 2. 三种部署形态：Agent、Proxy、Kubernetes 平台三件套

为了避免后续章节频繁切换上下文，这里先按部署形态把全部六个候选组件
归到三类，并明确每一类的能力边界。

### 2.1 本机 Agent 进程：模板渲染与进程供给

Vault Agent 与 Vault Proxy 在能力上有共同点也有分工。两者都支持
Auto-auth 自动认证、都支持作为 Windows 服务运行、都支持缓存通过
自身新建的令牌与租约；区别在于 Agent 还支持模板渲染（templating）与
进程监督（process supervisor，把机密以环境变量形式注入子进程），
而这两项能力在 Proxy 上不存在。

需要特别注意的是，Vault Agent 早期同时承担 API 代理职责，但在能力
对比表中，Agent 的「API proxy」一栏已经被官方明确标记为 Deprecated；
对应的能力在 Proxy 一栏标记为支持。这是后续章节（特别是 7.2 与 7.3）
只把 Agent 作为「模板渲染 / 进程供给」专用工具讲解，而不再把它当成
透明 API 代理使用的根本原因。

### 2.2 独立 Proxy 网关：API 代理与令牌/租约缓存

Vault Proxy 的核心定位是「位于应用与 Vault 之间的代理」：可选地简化
应用认证过程，并对请求进行缓存。在能力对比表中，Proxy 拥有 Auto-auth、
新建令牌与租约缓存、API 代理、以及面向 KV 静态机密的缓存（仅企业版
可用）；它不具备模板渲染与进程监督能力。

Vault Proxy 的命令行用法、配置文件结构、Auto-auth 与缓存语义已经在
[5.6 轻量级代理服务指令](/ch5-vault-proxy) 中完整讲解过，本章后续
（7.4）会聚焦在 Proxy 的部署拓扑选择与缓存边界，避免重复解释 CLI
与配置语法。

### 2.3 Kubernetes 平台三件套：VSO、CSI provider 与 Agent Injector

在 Kubernetes 环境下，HashiCorp 提供三套官方集成，每一套都有自己的
适用场景，需要根据安全策略、机密治理需求、易用性以及系统可用性
保证来选择。

**Vault Secrets Operator（VSO）** 通过协调自定义资源定义（CRD），
把 Vault 中的机密同步成原生 Kubernetes Secret，应用程序可以使用
标准的 Kubernetes 模式去消费这些 Secret。它适合偏好原生 Kubernetes
工作流、并希望机密既可以写入持久化集群存储、也可以选择临时挂载卷
的团队。

**Vault Secrets Store CSI provider** 基于厂商无关的 Secrets Store
CSI driver，把 Vault 机密以临时挂载卷（ephemeral volumes）的形式
挂载到 Pod 内；它适合同时使用多种机密存储、或希望沿用厂商无关 CSI
标准的组织。

**Vault Agent Injector** 在 Pod 中注入 Vault Agent 边车容器，由边车
容器与 Vault 完成认证，再把机密渲染到与业务容器共享的内存卷中供其
读取；它适合那些需要在同一份模板中引用多条 Vault 机密、或者需要
更广泛认证方法支持的应用。

下表把官方对照表整理成中文版，便于在选型时快速对照；详细的特性矩阵
与性能特征会在 7.5–7.9 各节展开。

| 维度 | Vault Secrets Operator | Vault Secrets Store CSI provider | Vault Agent Injector |
| --- | --- | --- | --- |
| 支持的机密类型 | Static/KV、PKI、Dynamic、Database、AppRole secret IDs | All（全部） | All（全部） |
| 支持的认证方法 | K8s、AppRole、GCP、AWS、JWT | K8s、JWT | K8s 及其它 auto-auth 方法 |
| 存储模型 | 默认写入 Kubernetes Secret；CSI driver 模式下为临时卷 | 临时 Kubernetes Secret 或临时卷 | 临时卷 |
| 是否原生 Kubernetes 风格 | 是 | 是 | 否 |
| 机密数据持久化 | 默认持久化于 etcd；CSI driver 模式下为临时 | 临时持久化或临时 | 临时 |
| 机密数据模板化 | 是 | 否 | 是 |
| Pod 自动伸缩是否依赖 Vault | 默认否，CSI driver 模式下是 | 是 | 是 |
| 应用之间共享同一份机密 | 是 | 是 | 否 |

性能维度上，官方文档给出了一致的趋势：在「对 Vault 的负载」「Pod
内机密的生命周期」「资源消耗」「可扩展性」这四个角度上，VSO 普遍
处于较低的负载、较低的资源消耗，并且机密生命周期独立于 Pod 生命
周期；Agent Injector 则是负载与资源消耗最高的一档，且机密生命
周期与 Pod 生命周期强绑定。CSI provider 在资源消耗维度上接近 VSO
一端，但在「对 Vault 的负载」与「按 Pod 建立独立连接」的连接模型
上更接近 Agent Injector 一端。

![三种 Kubernetes 集成在与 Vault 之间的连接拓扑、机密呈现位置、与 Pod 生命周期耦合度上的差异](/images/ch7-overview/k8s-three-integrations.png)

---

## 3. 与本书已有章节的衔接

本章不是从零开始讲 Kubernetes 与 Vault 的关系。在进入后续小节之前，
请读者先复习以下四节，因为本章会反复引用其中已经建立的概念：

[4.4 Kubernetes 认证方法](/ch4-k8s) 解释了 Pod 如何通过自身的
ServiceAccount JWT 向 Vault 证明身份。本章三种 Kubernetes 集成在
官方支持的认证方法清单中都包含 Kubernetes 认证，复习这一节有助于
理解后续章节中 Pod 如何向 Vault 出示身份凭证。

[4.9 JWT/OIDC 认证方法](/ch4-jwt) 与 Kubernetes 认证同源——
Kubernetes 集群签发的 ServiceAccount Token 本身就是一种 JWT，可以
被 Vault 通过标准 JWT/OIDC 认证方法验证。VSO 与 CSI provider 的
认证方法清单中都包含 JWT，正是这种同源关系的体现。

[5.6 Vault Proxy CLI](/ch5-vault-proxy) 已经把 `vault proxy` 的
配置文件结构、Auto-auth、API 代理与缓存边界讲解完毕。本章 7.4 节
会复用这些结论，重点讨论 Proxy 在「每应用边车」「每节点共享」
「网关式共享」三种部署位置上的取舍，而不再重复解释配置语法。

[3.11 Kubernetes 机密引擎](/ch3-k8s) 是与本章方向相反的链路——它
让 Vault 主动调用目标 K8s 集群的 API 为某个 ServiceAccount 签出
短生命期 Token；本章三种集成的方向则相反：是 K8s 工作负载主动从
Vault 拉取或同步机密。区分清楚两者的方向有助于避免后续选型混淆。

> **本章后续阅读路径**：
> - 7.2 / 7.3 聚焦 Vault Agent 的两条主线（模板渲染、进程供给）；
> - 7.4 专门讨论 Vault Proxy 的部署拓扑与缓存边界；
> - 7.5 / 7.6 / 7.7 / 7.8 分别动手实战 Agent Injector、CSI provider、VSO 静态机密、VSO 动态机密与 PKI；
> - 7.9 收束三种 K8s 集成的选型矩阵与决策树。

---

## 4. 互动实验

为了在动手之前先建立对「同一份机密能被多种方式取出」这一事实的
直觉，本节配套实验让学员在同一台 Vault dev server 上，分别用
三种不同方式取出同一条 KV 机密：

- **Step 1**：用最朴素的 `vault kv get` 直接读取，观察请求所使用的
  令牌、机密的呈现位置（CLI 标准输出）以及调用主体。
- **Step 2**：启动一个最小化的 Vault Agent，使用模板渲染把同一条
  KV 机密写入本地文件，观察机密以「文件」形式落地的产物形态。
- **Step 3**：启动一个最小化的 Vault Proxy，让另一份未持有 token
  的 CLI 通过 Proxy 读取同一条机密，观察 Proxy 代办的 Auto-auth
  令牌如何被强制附加到请求上。
- **Step 4**：在终端里把三种方式的「认证主体、令牌存放位置、机密
  呈现形式、缓存归属」整理成一张三栏对照表，作为本章后续学习的
  锚点。

本实验只覆盖单机三种方式的对比，不在此处部署 Kubernetes 控制器；
Kubernetes 三件套的实验留到 7.5 / 7.6 / 7.7 / 7.8 节再展开。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch7-overview" title="实验：用三种方式各取一次同一份 KV 机密" />
