---
order: 67
title: 6.7 分布式服务注册与发现（K8s 原生发现机制与 Consul 集成模式）
group: 第 6 章：集群配置文件调优与高可用自动化运维
group_order: 60
---

# 6.7 分布式服务注册与发现（K8s 原生发现机制与 Consul 集成模式）

> **核心结论**：`service_registration` 是 Vault 配置文件中一个**可选**的顶层块，专门解决"我使用 Raft 这类自带存储后端、但仍然希望把 Vault 节点的活跃 / 待命 / 封印状态对外广播给服务发现系统"这一类需求。它与 `storage` 块解耦：当存储后端选用 Consul 时，Vault 会**隐式**完成服务注册；当存储后端选用 Raft 等其它后端时，必须**显式**声明 `service_registration` 才能让 Consul 或 Kubernetes 感知到节点状态。本节按"为什么需要这一块 → Consul 集成模式 → Kubernetes 原生发现模式 → 选型与排障要点"的顺序展开。

本节是第 6 章配置文件深入系列的第六节，承接 6.6 节"集群高可用模式"中关于 `api_addr` 与活跃 / 待命节点路由的讨论。6.6 节解决的是"客户端连到哪台 Vault 都能正确被路由到活跃节点"，而本节解决的是更前置的一步——"客户端 / 负载均衡器 / Kubernetes Service 自身如何在不内置 Vault 拓扑知识的情况下，实时找到当前的活跃节点"。

---

## 1. `service_registration` 块在 Vault 配置中的位置与适用边界

`service_registration` 是 Vault 配置文件中一个**可选**的顶层块，用于配置 Vault 的服务注册机制。其设计场景十分明确：当运维人员希望使用 Consul 这一类系统进行**服务发现**，但**存储后端**却选用了另外一种系统（例如 Raft）时，就需要这一块来弥合两者。

当 Consul 被同时用作存储后端时，Vault 会**隐式**地使用 Consul 完成服务注册，此时**无需**再声明 `service_registration` 块。

如果希望使用 Raft 之类的其它存储后端，同时仍要让外部系统能够通过服务发现机制定位 Vault 节点，则需要在配置文件中**同时**声明 `service_registration` 与 `storage` 两块。官方文档给出的范例是：用 Consul 进行服务注册，用 Raft 持久化数据。

`service_registration` 块的通用语法形式为 `service_registration [NAME] { [PARAMETERS...] }`，其中 `NAME` 用于指定具体的服务注册提供者（目前开源版支持的两种实现是 `consul` 与 `kubernetes`）。对于同时支持环境变量的参数，**环境变量的取值优先级高于配置文件**。

> 该配置项是在 Vault 1.4.0 中引入的，更老的版本无法直接套用本节的写法。

![service_registration 与 storage 在配置文件中的关系：当存储后端不是 Consul 时，必须显式声明一个独立的 service_registration 块来让外部系统感知 Vault 节点状态](/images/ch6-service-registration/stanza-position.png)

---

## 2. Consul 服务注册：把 Vault 节点登记进 Consul 服务目录

Consul 服务注册（Consul Service Registration）会把 Vault 作为一个服务登记进 [Consul][consul]，并附带一个默认的健康检查；该集成由 HashiCorp 官方提供并支持。

### 2.1 基本配置：指向本机 Consul agent

最简化的配置只需指向一台**本机 Consul agent** 的地址即可，官方明确建议**不要直接与 Consul 服务器通信，而应通过本机 agent**：

```hcl
service_registration "consul" {
  address = "127.0.0.1:8500"
}
```

如果 Vault 以 HA 模式运行，则需要在 `address` 中显式包含传输协议前缀（`http://` 或 `https://`），例如 `http://127.0.0.1:8500`。

### 2.2 注册成功后 Vault 在 Consul 中暴露的三个 DNS 入口

一旦配置生效且 Vault 已被 unseal，Consul 服务目录中将出现以下三类可被 DNS 查询的端点：

- `active.vault.service.consul`：当前的**活跃节点**；
- `standby.vault.service.consul`：所有处于**待命**状态、且**已 unseal** 的节点；
- `vault.service.consul`：所有**已 unseal** 的节点（无论活跃 / 待命）。

处于 sealed 状态的 Vault 节点会主动在健康检查中将自身标记为不健康，因此**不会**被 Consul 的服务发现层返回。

![Consul 服务注册后形成的三个 DNS 端点：active 只解析到当前活跃节点，standby 只解析到已 unseal 的待命节点，vault 解析到全部已 unseal 节点；sealed 节点全部被 Consul 主动剔除](/images/ch6-service-registration/consul-three-endpoints.png)

### 2.3 关键参数：服务命名、健康检查、ACL token 与 TLS

`consul` 服务注册块下最常用的几个参数与默认值如下：

- `address`（默认 `127.0.0.1:8500`）：Consul agent 的地址，可以是 IP、DNS 名或 unix socket。官方建议指向**本机 Consul agent**，不要直接对话 Consul 服务器。
- `check_timeout`（默认 `5s`）：Vault 向 Consul 上报健康检查信息的间隔，使用 `30s`、`1h` 这类带单位的时间字符串。
- `disable_registration`（默认 `false`）：是否禁止 Vault 向 Consul 注册自身。
- `scheme`（默认 `http`）：与 Consul 通信使用的协议，可选 `http` 或 `https`。文档**强烈建议**对非本机连接使用 `https`；当使用 unix socket 时该参数会被忽略。
- `service`（默认 `vault`）：在 Consul 中注册的服务名。
- `service_tags`（默认空字符串）：注册时附加在服务上的、**大小写敏感**的逗号分隔标签列表。
- `service_meta`（默认空 map）：附加在服务注册上的键值对元数据。
- `service_address`（默认未设置）：在 Consul 中注册的服务专用地址。如果不设置，Vault 会使用其已知的 HA redirect 地址——这通常正是希望的行为。把该字段显式设为空字符串 `""` 则会让 Consul 动态使用注册节点自身的配置，便于结合 Consul 的 `translate_wan_addrs` 机制。
- `token`（默认空字符串）：用于将 Vault 服务注册到 Consul 服务目录所需的 [Consul ACL token][consul-acl]，**注意这不是 Vault token**。

与 Consul 的 TLS 通信涉及一组 `tls_*` 参数：`tls_ca_file`（CA 证书路径，未指定时回落到系统证书 bundle）、`tls_cert_file`（与 Consul 通信使用的证书路径，可选）、`tls_key_file`（与之配套的私钥路径），它们的取值应当对应 Consul 配置文件中的 `ca_file`、`cert_file`、`key_file` 三项。

`tls_min_version`（默认 `tls12`）规定与 Consul 通信时的最低 TLS 版本，可选值为 `tls10`、`tls11`、`tls12`、`tls13`。`tls_skip_verify`（默认 `false`）允许跳过 TLS 证书校验，但官方明确**强烈不建议**启用该选项。

### 2.4 Consul ACL 最小授权策略

如果 Consul 启用了 ACL，则 Vault 用于注册自身所使用的 token 必须具备相应权限。在大多数场景下（假设服务名沿用默认的 `vault`），下列 Consul ACL 策略已经足够：

```json
{
  "service": {
    "vault": {
      "policy": "write"
    }
  }
}
```

### 2.5 典型部署形态示例

官方文档列出了四种典型示例配置：

1. **本机 agent**：完全不写参数，使用默认地址 `127.0.0.1:8500`。

   ```hcl
   service_registration "consul" {}
   ```

2. **自定义地址 + ACL token**：

   ```hcl
   service_registration "consul" {
     address = "10.5.7.92:8194"
     token   = "abcd1234"
   }
   ```

3. **通过本机 unix socket 与 Consul 通信**：

   ```hcl
   service_registration "consul" {
     address = "unix:///tmp/.consul.http.sock"
   }
   ```

4. **使用自签 CA / 证书 / 私钥的 TLS 通信**：

   ```hcl
   service_registration "consul" {
     scheme        = "https"
     tls_ca_file   = "/etc/pem/vault.ca"
     tls_cert_file = "/etc/pem/vault.cert"
     tls_key_file  = "/etc/pem/vault.key"
   }
   ```

---

## 3. Kubernetes 原生发现：用 Pod 标签暴露 Vault 节点状态

Kubernetes 服务注册（Kubernetes Service Registration）的工作原理与 Consul 截然不同：它不是把 Vault 注册进某个外部目录，而是**把 Vault 当前的状态以标签（label）形式打到运行该 Vault 进程的 Pod 上**，使 Kubernetes 原生的 `Service` 选择器能够直接据此筛选 Pod。该机制**仅在 Vault 运行于 HA 模式时可用**，并由 HashiCorp 官方支持。

### 3.1 配置：声明意图、提供 namespace 与 pod 名

Kubernetes 服务注册块的最小完整写法是：

```hcl
service_registration "kubernetes" {
  namespace = "my-namespace"
  pod_name  = "my-pod-name"
}
```

`namespace` 与 `pod_name` 也可以**改用环境变量** `VAULT_K8S_NAMESPACE` 与 `VAULT_K8S_POD_NAME` 注入，便于结合 [Kubernetes Downward API](https://kubernetes.io/docs/tasks/inject-data-application/downward-api-volume-expose-pod-information/) 在 Pod 启动时自动写入。

如果**仅**通过环境变量提供这两个值，配置文件中**仍然必须**保留一个空的 `service_registration "kubernetes" {}` 块用于声明意图——Vault 不会仅凭环境变量自行推断要启用 Kubernetes 注册。

### 3.2 Pod ServiceAccount 必备的 RBAC 授权

为了能够把标签写回自身 Pod，Vault 进程所使用的 ServiceAccount 必须被授予对 Pods 资源的 `get`、`update`、`patch` 权限：

```yaml
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  namespace: mynamespace
  name: vault-service-account
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "update", "patch"]
```

### 3.3 Vault 写到 Pod 上的五个标签及其含义

启用 Kubernetes 服务注册后，正常运行的 Vault Pod 会带有形如下面的标签：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: vault
  labels:
    vault-active: "false"
    vault-initialized: "true"
    vault-perf-standby: "false"
    vault-sealed: "false"
    vault-version: 1.21.2
```

而当 Pod 被关闭后，Vault 会更新标签到反映关闭状态的取值（`vault-initialized: "false"`、`vault-sealed: "true"` 等）。

各标签的精确语义如下：

- `vault-active`（取值 `"true"` 或 `"false"`）：每当 Vault 的活跃状态发生变化时被动态更新；`true` 表示当前 Pod 是活跃节点（leader），`false` 表示当前 Pod 是待命节点。
- `vault-initialized`（取值 `"true"` 或 `"false"`）：每当 Vault 的初始化状态变化时被动态更新；`true` 表示当前已初始化，`false` 表示尚未初始化。
- `vault-perf-standby`（取值 `"true"` 或 `"false"`）：每当 Vault 的 leader / standby 状态变化时被动态更新；**该字段只有当 Pod 隶属于一个 performance standby 集群时才有意义**，否则恒为 `false`。`true` 表示当前 Pod 是 performance standby，`false` 表示当前 Pod 是 performance leader。
- `vault-sealed`（取值 `"true"` 或 `"false"`）：每当 Vault 的封印状态变化时被动态更新；`true` 表示当前已封印，`false` 表示当前已解封。
- `vault-version`（字符串，例如 `"1.21.2"`）：Vault 的版本号，**在该 Pod 的生命周期内不会变化**。

![Kubernetes 服务注册写到 Pod 上的标签：把活跃 / 待命 / 封印 / 版本号等运行时状态打成 label，让 Service 选择器能够直接挑出"当前活跃且已解封的那一台"](/images/ch6-service-registration/k8s-pod-labels.png)

### 3.4 据标签构建"始终指向活跃节点"的 Service

配合上述标签，可以创建一个只选中"当前活跃节点"的 Kubernetes `Service`，从而获得一个永远指向 leader 的稳定端点；其关键在于在 `selector` 中加入 `vault-active: "true"`，并将 `publishNotReadyAddresses` 设为 `false`，使失败的 Pod 自动从服务池中被移除：

```yaml
apiVersion: v1
kind: Service
metadata:
  labels:
    app.kubernetes.io/instance: vault
    app.kubernetes.io/name: vault
    helm.sh/chart: vault-0.32.0
  name: vault-active-us-east
  namespace: default
spec:
  clusterIP: 10.7.254.51
  ports:
  - name: http
    port: 8200
    protocol: TCP
    targetPort: 8200
  - name: internal
    port: 8201
    protocol: TCP
    targetPort: 8201
  publishNotReadyAddresses: false
  selector:
    app.kubernetes.io/instance: vault
    app.kubernetes.io/name: vault
    component: server
    vault-active: "true"
  type: ClusterIP
```

这样一个"活跃节点 Service"可以直接作为 Vault 复制的 primary 地址使用，例如：

```shell-session
$ vault write -f sys/replication/performance/primary/enable \
    primary_cluster_addr='https://vault-active-us-east:8201'
```

### 3.5 据标签编排"零停机滚动升级"

同样借助这些标签，可以与 `OnDelete` 升级策略配合，把镜像版本升级动作变得可控且可被 selector 精确定位：先升级所有待命节点（`vault-active=false`），最后再升级活跃节点（`vault-active=true`），从而最大限度缩短服务中断窗口：

```shell-session
$ helm upgrade vault --set='server.image.tag=1.21.2'

$ kubectl delete pod --selector=vault-active=false \
    --selector=vault-version=1.2.3

$ kubectl delete pod --selector=vault-active=true \
    --selector=vault-version=1.2.3
```

被 `kubectl delete` 删除的 Pod 会被 `StatefulSet` 重新调度，且新调度的 Pod 会使用最新的镜像。

---

## 4. 选型与排障要点

把本节内容与第 6.6 节关于 HA 的讨论结合起来，可以形成下列几条对运维而言十分实用的"心智地图"：

1. **"是否需要 `service_registration` 块"取决于存储后端**：当存储后端是 Consul 时，无需声明该块，Vault 会自动完成注册；当存储后端是 Raft 等其它后端时，必须显式声明，否则外部系统无法获知节点状态。
2. **Consul 模式提供的是"DNS 视角"的拓扑**：通过 `active.vault.service.consul`、`standby.vault.service.consul`、`vault.service.consul` 三个 DNS 名暴露不同子集，而 sealed 节点会被 Consul 主动剔除，对客户端完全透明。
3. **Kubernetes 模式提供的是"Label 视角"的拓扑**：Vault 把状态打到 Pod label 上，由原生的 Service selector 决定"哪个 Pod 接收哪种流量"，无需额外的 DNS 系统。
4. **典型排障步骤**：先确认 `service_registration` 块本身是否被解析（启动日志会反映），再确认凭据是否充分（Consul ACL token / Kubernetes RBAC），最后确认 Vault 是否处于 HA 模式（Kubernetes 注册要求 HA 模式）。

掌握以上四点，结合 6.6 节关于 `api_addr` 与请求转发的机制，运维人员就具备了让客户端、负载均衡器或 Kubernetes Service "始终找到正确的 Vault 节点" 的完整能力。

---

## 5. 动手实验

本节配套了一个 Killercoda 实验，**同时**演示 `service_registration` 的两种官方实现。实验运行在 `kubernetes-kubeadm-1node` 环境上：前 2 步用宿主机进程演示 Consul 模式，后 2 步通过官方 `hashicorp/vault` Helm chart 把 HA Vault 部署到 K8s 演示 Kubernetes 模式。完成下列练习：

1. 启动 Consul dev agent 与 3 节点 Vault Raft 集群（`vault.hcl` 显式声明 `service_registration "consul"`），通过 Consul HTTP catalog API 看到 `vault` 服务下注册了 3 个实例；
2. 用 `dig` 分别查询 `active.vault.service.consul` / `standby.vault.service.consul` / `vault.service.consul` 三个 DNS 端点并与 `sys/leader` 交叉验证，再主动 seal 一个待命节点观察其在数秒内从两个端点中"自动隐身"；
3. 用 Helm 把 3 副本 HA Vault 部署到 K8s（chart 默认就会注入 `service_registration "kubernetes" {}`、Downward API 与 ServiceAccount RBAC），完成 init / raft join / unseal 后，通过 `kubectl get pod -L vault-active,vault-sealed,...` 直接看到 Vault 写到 Pod label 上的状态；
4. 观察 Helm chart 默认创建的 `vault-active` Service 的 endpoints 始终精确指向当前 leader Pod；主动 `kubectl delete pod` 杀掉当前 leader 触发重新选举，看到标签随之翻转、Service endpoints 自动跟随到新 leader。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch6-service-registration" title="实验：Consul DNS 服务目录与 Kubernetes Pod 标签双视角下的 service_registration" />

[consul]: https://www.consul.io/
[consul-acl]: https://developer.hashicorp.com/consul/docs/security/acl
