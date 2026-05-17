---
order: 99
title: 9.8 让无法改造的遗留应用接入 Vault：Consul-Template 与 Process Supervisor 双轨实践
group: 第 9 章：全栈架构防线升级与现代工程实战案例
group_order: 90
---

# 9.8 让无法改造的遗留应用接入 Vault：Consul-Template 与 Process Supervisor 双轨实践

> **核心结论**：当一个遗留应用既不能改源码、又必须用上 Vault 动态机密时，HashiCorp 工具链里有**两个独立的产品**都能干这件事——**Consul-Template** 和 **Vault Agent**。两者共用同一套 Consul Template 模板语言，能渲染的产物高度重叠（Vault Agent 自己就能像 Consul-Template 那样把机密写成磁盘文件）。本节**故意**用两个工具去分别演示两种典型的运维形态：用 Consul-Template 展示"独立 CLI、只做文件渲染、轻量塞进现有 systemd / Docker entrypoint"的极简路径；用 Vault Agent 的 **Process Supervisor Mode** 展示它独有的杀手锏——把 auto-auth、env 注入、子进程生命周期管理绑在一个二进制里。两条演示路径都在你不动应用一行代码的前提下，把"应用消费长效静态密码"改造成"应用消费短 TTL 动态凭据"。

参考：

- [Consul-Template — HashiCorp Repository](https://github.com/hashicorp/consul-template)
- [Configuring Consul Template — consul-template/docs/configuration.md](https://github.com/hashicorp/consul-template/blob/main/docs/configuration.md)
- [Run Vault Agent in process supervisor mode — Vault Docs](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/process-supervisor)
- [Use Vault Agent templates — Vault Docs](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/template)
- [Database secrets engine — PostgreSQL Vault Docs](https://developer.hashicorp.com/vault/docs/secrets/databases/postgresql)
- 已学衔接：[7.2 Vault Agent](/ch7-agent)、[3.10 PostgreSQL 机密引擎](/ch3-postgres)（动态 DB 凭据与 lease）、[2.3 租约（Lease）](/ch2-lease)、[9.3 Vault Agent Caching](/ch9-agent-cache)

---

## 1. 这一节解决的问题：拿不到源码的应用怎么消费动态机密

在生产里我们经常遇到这样一类应用：它仍然在跑、还承载着真实业务流量，但代码已经没法再改。常见原因有几类：原始代码仓库丢失或没人能找回构建链路；外部供应商交付的二进制只允许接配置文件、不允许做侵入式集成；合规要求"任何对该模块的修改都要重新做安全评审"，团队权衡之后宁愿不动它。

这类应用的认证方式几乎都一样：**从某个本地配置文件（或环境变量）读一行长效静态密码**。前几章已经讲过这种长效静态密码暴露面有多大——一旦被偶然拷贝走，攻击者在你下一次手动轮换之前可以一直用。

理想做法当然是改造代码、让它直接用 Vault SDK 取一份动态凭据。但既然现在前提就是"应用不能改"，那么唯一可行的路径就是：

> **在不动应用的前提下，把它原本读的那份长效静态密码，替换成由某个本地组件持续刷新、由 Vault 后台轮转的短 TTL 动态凭据。**

HashiCorp 工具链里能担当这个"本地组件"的，其实是**两个不同的产品**——Consul-Template 与 Vault Agent。它们能力高度重叠：模板语言一样、能渲染文件、能在凭据变化时跑命令，连续期 Vault token 这件事也都内建。本节要做的，是先把"两个工具各自的定位"和"我们为什么挑这两种典型形态去对照演示"讲清楚，再用同一个"无法改造的 Go 应用 + PostgreSQL 动态机密引擎"作为公共背景分别跑通一遍。

---

## 2. 我们演示两种工具：Consul-Template 与 Vault Agent Process Supervisor

先把两个工具各自是什么摆清楚：

第一个是 **Consul-Template**：HashiCorp 维护的一个**独立命令行工具**。它最早是为 Consul KV 而生，后来扩展到 Vault 与 Nomad，用一套通用的"Consul Template"模板语言把外部数据源渲染成本地文本文件，并可以在每次模板变化时执行一条命令。在 Vault 场景下，它就是"拿一枚 token、周期性地去 Vault 取机密、把模板结果写到磁盘文件上"的那个轻量 CLI。

第二个是 **Vault Agent**——也就是第 7.2 节那个 Agent。Agent 本身就**完整内嵌了同一套 Consul Template 引擎**：你既可以用 `template` 块让它把机密渲染成磁盘文件（行为与 Consul-Template 几乎对等），也可以用 `env_template` + `exec` 块进入它的 **Process Supervisor Mode**——Agent 启动时先等所有 `env_template` 至少渲染一次，再 fork 出 `exec.command` 指定的子进程，并按 `restart_on_secret_changes` 在凭据轮转时给子进程发信号、整体重启。Consul-Template 这一侧也有一个对位的 **Exec Mode**（顶层 `exec` 块，能 `command` + `reload_signal` + `kill_signal` 地 fork 并监督子进程），所以"托管子进程"本身两边都有；真正只在 Vault Agent 这一侧的是 `env_template`（把模板渲染结果作为子进程环境变量注入）与内置 `auto_auth` 的同壳组合。

**所以"渲染成文件"并不是 Consul-Template 的专属，"托管子进程"也不是 Vault Agent 的专属。** 那本节为什么还要把两个都讲一遍？因为它们各自的"长相"恰好能凸显两个完全不同的运维模式：

- **Consul-Template** 是一个**不和 Vault Agent 共生**的独立二进制——可以直接塞进任何一个早就在跑的 systemd 单元、Docker entrypoint、旧 init 脚本里，最常见的用法就是"文件渲染器"。这种"我只是个轻量 CLI"的形态很适合那些**不想引入完整 Agent**、只想换掉那一行配置里的密码字段的场景。
- **Vault Agent 的 Process Supervisor Mode** 在"模板渲染 + 子进程托管"这两件事上和 Consul-Template 的 **Exec Mode** 大面积重叠——CT 顶层 `exec` 块也能 `command` + `reload_signal` + `kill_signal` / `kill_timeout` 地 fork 并监督子进程。Vault Agent 在这条路上**真正不可替代**的是两件事捆在同一个二进制里：**`env_template` 把模板渲染结果直接注入子进程的环境变量**（CT 的 `exec.env.custom` 只接受静态 `"KEY=VAL"` 列表，没法把 `{{ with secret "database/creds/readonly" }}` 的渲染结果挂成子进程 env），以及**内置 `auto_auth`** 让 token 的拿取和续期不再需要外部喂进来。

本节是**故意**用两个工具去分别演示这两种形态，而不是因为某个工具不能干另一个工具的事。下表把这层"我们为什么这么挑"的设计意图明确出来：

| 维度 | 路径 A：Consul-Template 渲染文件（本节演示） | 路径 B：Vault Agent Process Supervisor 注入环境变量（本节演示） |
| --- | --- | --- |
| 工具角色 | 独立 CLI，最常见的用法是模板渲染 | Vault Agent 的内置模式 |
| 这个工具是否还能干另一种 | ✅ CT 也有 Exec Mode（顶层 `exec` 块）能 fork 并监督子进程，但 `exec.env.custom` 只接受**静态** env，没法把模板渲染结果作为子进程环境变量注入 | ✅ Vault Agent 也能用 `template` 块写文件（见 7.2 节），但与 `env_template + exec` 在同一份配置里**互斥**（见 §5.1） |
| 本节挑它演示这一面的原因 | 展示"只要个文件渲染器、不引入 Agent"的极简形态 | 展示 Agent 独有的"`env_template` + `auto_auth` 同壳" |
| Vault token 由谁管 | Consul-Template 自己（`renew_token = true`，需要外部先喂一枚 token 进来） | Vault Agent 的 Auto-auth（内置拿取与续期） |
| 凭据变化时应用怎么感知 | 应用要么定时重读文件、要么由 `template.exec` 触发 reload；走 CT Exec Mode 时还可由 `reload_signal` 直接信号化子进程 | Agent 按 `restart_on_secret_changes` 整体重启子进程 |
| 与传统 init 系统的关系 | 子进程崩溃不会被自动拉起，仍需 systemd / 容器编排兜底 | 同上；官方原文是 "Vault Agent will exit when the child process exits on its own with the same exit code"——不会替你重启崩溃的子进程 |

换句话说：你完全可以**只用 Vault Agent 这一个产品**走完所有路径——文件渲染走 `template`、环境变量注入走 `env_template + exec`。但要注意这两条路在 Agent 这一侧**不能写在同一份配置里**（process supervisor 模式与文件型 `template` 条目互斥，详见 §5.1），意味着你得起**两个 Agent 进程 / 两份配置**。本节把第一条路交给 Consul-Template，纯粹是为了把"独立 CLI 的极简形态"和"Agent 的进程托管形态"两种生产里都常见的部署形状一次性给你看到。

> 提醒：如果是已经在 Kubernetes 中运行的工作负载，官方文档在 process supervisor 这一页明确建议先评估 **Vault Secrets Operator** 与 **Vault Agent Sidecar Injector** 两条 Kubernetes 原生路径。本节的两个工具主要面向裸机 / VM / 普通容器以及"还来不及上 K8s"的旧应用形态。

---

## 3. 共同基底：用 PostgreSQL 动态凭据替换那一行长效密码

本节实验用两种工具搭配同一份 Vault 配置作为基底：dev 模式 Vault + 一个本地 PostgreSQL + 一个签发短 TTL 动态用户的 database 机密引擎 role。

PostgreSQL 实例用 docker 起一个 `root / rootpassword` 的 superuser，然后预先创建一个名为 `ro` 的只读 role 作为动态用户的权限"模具"——所有由 Vault 创建的动态用户都通过 `GRANT ro TO <动态用户名>` 拿到读取业务表的权限。Vault 这边的配置同样照搬经典教程：启用 `database` 机密引擎，写入 PostgreSQL 连接信息，再定义一个名为 `readonly` 的 role，把它的 `default_ttl` 主动调短到 30 秒，方便交互式实验中观察租约到期与轮转。

之所以选短 TTL（实验里 `default_ttl=30s, max_ttl=2m`），是为了在课堂节奏内**亲眼看到**两件事：
- 同一个本地组件（Consul-Template 或 Vault Agent）会替你把行将到期的动态凭据**先续期、续不动了再换成新的**；
- 应用读到的"机密"在这次轮转中确实变了，但应用的二进制完全没有被改动。

本节会把同一份 TOML 文件交给一个**故意写成"无法改造"**的 Go 二进制去消费，然后在第二幕用 Process Supervisor 把同一份机密改成环境变量交给另一个版本的同一个二进制。

模拟"遗留应用"的 Go 程序非常窄：它启动时读 `/etc/legacy-app/config.toml`（或同名的环境变量 `DB_USER` / `DB_PASSWORD`），用拿到的用户名密码连 Postgres，每隔几秒打印一次"当前以 \<username\> 连接，跑 `SELECT current_user, now()` 的结果是 …"。它不知道 Vault 存在，也不知道凭据来自哪里——这正是"无法改造的旧应用"在被改造前后能保持的稳定行为。

---

## 4. 第一条路：Consul-Template 把动态凭据渲染成 TOML 配置文件

第一条路里 Consul-Template 充当"配置文件维护工"，整条链路是这样的：

```text
┌──────────────────────┐    1. 周期取                ┌──────────────┐
│                      │ ──── database/creds ─────▶ │              │
│   consul-template    │                            │   Vault      │
│                      │ ◀── username / password ── │              │
└─────────┬────────────┘                            └──────┬───────┘
          │                                                │
          │ 2. 渲染 config.toml                              │ 3. 在 Postgres
          ▼                                                 │    创建短 TTL 用户
   ┌─────────────────┐         4. 应用启动 / 重读              │
   │ /etc/legacy-app │ ──────────────────────────────▶ ┌──────▼───────┐
   │ /config.toml    │                                │  PostgreSQL  │
   └─────────────────┘                                └──────────────┘
                    ▲                                         ▲
                    │                                         │
                    └────── legacy Go binary 读文件并连库 ───────┘
```

### 4.1 模板内容

模板文件 `config.toml.tplt` 用最朴素的写法把 Vault 里的字段填进 TOML：

```toml
[database]
host = "localhost"
port = 5432
{{ with secret "database/creds/readonly" }}
username = "{{ .Data.username }}"
password = "{{ .Data.password }}"
{{ end }}
```

`{{ with secret "database/creds/readonly" }} ... {{ end }}` 这一段是 Consul-Template 模板语法。`secret` 函数对应 Vault 的 `database/creds/<role>` 端点，每次调用都会让 Vault 在 PostgreSQL 上新建一个动态用户并返回一份带 `lease_id` 的响应；模板用 `.Data.username` 与 `.Data.password` 两个字段去填配置文件。

### 4.2 Consul-Template 自己的配置：把自动续期写在脸上

Consul-Template 的运行时配置文件 `ct_config.hcl` 直接把和续期相关的几个开关都显式列出来，方便和官方 configuration.md 一一对照：

```hcl
vault {
  address                 = "http://127.0.0.1:8200"
  renew_token             = true   # 自动续期 Vault token（其实是默认值，写出来更显眼）
  default_lease_duration  = "60s"  # 没有 lease duration 的机密用这个值做兜底
  lease_renewal_threshold = 0.5    # 不可续期机密的重取阈值；可续期的不走这里
}
```

Consul-Template 在 Vault 这一侧的"自动续期"其实是**两条并行的自动机制**，要分开看：

1. **Vault token 自动续期**——由 `renew_token` 控制（**默认即为 `true`**），把它写出来纯粹是为了在配置里一眼能看到。官方文档明确写着"will automatically renew the token at half the lease duration of the token"。本节实验在 dev 模式里 token 是 root token 永不过期，但生产里 AppRole / Userpass 拿到的 token 都依赖这一行帮你续；
2. **租约（lease）自动续期**——Consul-Template 在内部为**每一份可续期**的 secret 启动一个 renewer goroutine，**默认就开**，没有专门的开关。本节的 `database/creds/readonly` 就是可续期 lease（PostgreSQL database 引擎默认产生 renewable lease），因此一旦 CT 拿到第一份凭据，它就会在 lease 走完一半时调 Vault 的 renew 接口把 lease 续到下一段；只有当 lease 接近 `max_ttl`、Vault 拒绝再续时，CT 才会**重新申请**一份全新的凭据。

`lease_renewal_threshold = 0.5` 这一行只对**不可续期**的 lease（典型如 KV v2 里被用 `secret` 函数拉过来的版本号）生效——意思是"走过 50% 时间后去重取一次"。它对本节的 `database/creds` 没有直接影响，但写在这里方便讲解。

`address` 是 Vault leader 地址，协议头部 `http(s)://` 必填。

### 4.3 启动方式与产物观察

启动命令是最朴素的形态：

```bash
consul-template \
  -template "config.toml.tplt:/etc/legacy-app/config.toml" \
  -config "ct_config.hcl"
```

`-template` 的语法是 `<源模板>:<目标文件>`；如果再加上第三个冒号分隔字段，consul-template 还能在每次模板内容变化时执行一条命令，例如 `nginx -s reload`。本实验暂时不需要让旧应用感知文件变化——它只是周期性自己重读文件，所以不接 exec 钩子。

第一次启动后，`/etc/legacy-app/config.toml` 立刻会出现完整的 TOML 内容；如果在 Vault 这一侧执行 `vault list sys/leases/lookup/database/creds/readonly`，能看到 Consul-Template 刚刚替你拉出来的那条租约。

结合上一节那两条自动机制，可观察到的现象会分成两个阶段：

- **续期阶段**：在 `max_ttl` 还没到之前，CT 会每隔约 `default_ttl / 2`（也就是约 15 秒）静默地把同一份 lease 续到下一段——`username` **不会变**，但在 Postgres 里 `pg_user` 表上那行的 `valuntil` 会被不断往后推；
- **重取阶段**：当 lease 累计存活时间逼近 `max_ttl`（实验里设为 2 分钟）时，Vault 拒绝再续，CT 立刻去 `database/creds/readonly` 申请一份全新凭据，把 `config.toml` 重写一遍——这时 `username` 才会换成新的随机串，旧用户名被 Vault 在 PostgreSQL 里 `DROP ROLE` 掉。

这两个阶段都不需要你额外动手——它们就是"自动续期"在两端时间尺度上的自然延伸。

> 这里有一个需要诚实交待的边界：`/etc/legacy-app/config.toml` 在哪个时刻被旧应用真正读到，取决于旧应用自己什么时候去读。如果应用只在启动时读一次配置（很多旧 Go 程序都是这样），那么 Consul-Template 把文件写新一遍并不会立刻让应用换上新凭据——除非你借助 `template.exec` 在每次渲染后给应用发一个 reload 信号，或者用 9.7 节那种"上游连接拒绝时即时重连"的 Process Supervisor 重启策略来兜底。本节实验里特意让旧应用每隔 10 秒重读一次文件，避免这个边界把演示叙事打断；生产里通常应该明确选一种刷新机制并写进运行手册。

---

## 5. 第二条路：Vault Agent Process Supervisor 把同一份凭据塞进环境变量

把同一份 PostgreSQL 动态凭据改用 Vault Agent 的 Process Supervisor Mode 喂给旧应用，整条链路里 Vault 与 Postgres 那一段保持不动，只是中间替换了组件：

```text
┌──────────────────────┐                               ┌──────────────┐
│                      │ ─── auto_auth (AppRole) ───▶ │              │
│  vault agent         │                               │              │
│  (process            │ ─── database/creds ──────────▶│   Vault      │
│   supervisor)        │ ◀── username / password ──── │              │
└─────────┬────────────┘                               └──────┬───────┘
          │ 1. env_template 渲染:                              │
          │     DB_USER, DB_PASSWORD                          │ 2. 创建短 TTL
          │ 2. exec.command 启动子进程                          │    动态用户
          │ 3. restart_on_secret_changes=always                │
          ▼                                                    │
   ┌─────────────────┐                                ┌────────▼─────┐
   │ legacy Go bin   │ ── DB_USER / DB_PASSWORD ──▶  │  PostgreSQL  │
   │ (从环境变量读)   │                                └──────────────┘
   └─────────────────┘
```

### 5.1 Agent 配置骨架

配置文件 `vault-agent.hcl` 的骨架严格按照官方 process supervisor 页面给出的示例：

```hcl
auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path                   = "/root/agent-role-id"
      secret_id_file_path                 = "/root/agent-secret-id"
      remove_secret_id_file_after_reading = false
    }
  }
}

template_config {
  static_secret_render_interval = "5m"
  exit_on_retry_failure         = true
}

vault {
  address = "http://127.0.0.1:8200"
}

env_template "DB_USER" {
  contents             = "{{ with secret \"database/creds/readonly\" }}{{ .Data.username }}{{ end }}"
  error_on_missing_key = true
}

env_template "DB_PASSWORD" {
  contents             = "{{ with secret \"database/creds/readonly\" }}{{ .Data.password }}{{ end }}"
  error_on_missing_key = true
}

exec {
  command                   = ["/usr/local/bin/legacy-app"]
  restart_on_secret_changes = "always"
  restart_stop_signal       = "SIGTERM"
}
```

这个配置里需要被反复对照官方文档读懂的有三件事：

1. **`env_template` 的语义**：它使用与文件型模板一样的 Consul Template 语言，但只允许一个**子集**的 template 配置参数——典型如 `contents`、`source`、`error_on_missing_key`、`left_delimiter`、`right_delimiter`；环境变量名来自 stanza 的标题（也就是 `env_template "DB_USER"` 这一行里的 `DB_USER`）。如果你曾经在 7.2 节里写过 `template { destination = ... contents = ... }` 这种文件模板，这里只是把 destination 换成了"环境变量名"。

2. **`exec` 块的硬约束**：process supervisor 模式**要求**至少有一个 `env_template` 块 **以及恰好一个**顶层 `exec` 块，而且这套模式与常规的文件型 `template` 条目**不兼容**。这意味着同一份 Agent 配置文件**不能**既渲染文件又同时跑 process supervisor；两条主线在 Agent 这一侧是互斥的。

3. **`restart_on_secret_changes` 的取值与重启信号**：取值只有两个，`always`（默认）与 `never`；`restart_stop_signal` 默认 `SIGTERM`，Agent 在发出这个信号后给子进程 30 秒退出窗口，到时间仍未退出会发 `SIGKILL`。设成 `never` 时凭据变化不会触发子进程重启，这适合那种"短 TTL 但应用自己有 SDK 级重连兜底"的特殊场景，但对真正的遗留应用通常不合适。

### 5.2 启动方式与产物观察

启动命令就是普通的 `vault agent -config=...`：

```bash
vault agent -config=/etc/vault/vault-agent.hcl
```

Agent 启动后会做四件事：
1. 用 AppRole 完成 auto-auth，把 token 留在内存里持续续期；
2. 渲染 `DB_USER` 与 `DB_PASSWORD` 两个 env template，每个 template 都会触发一次 `database/creds/readonly` 请求；
3. 等到所有 env template 都渲染成功后，再 fork `/usr/local/bin/legacy-app` 子进程，把两个变量塞进它的 environ；
4. 把子进程的 `stdin`、`stdout`、`stderr` 转发出来，并在子进程退出时以**相同的退出码**自己也退出。

观察租约轮转的实验方法与第一条路一致：`vault list sys/leases/lookup/database/creds/readonly` 会看到由 Agent 拉出来的租约；当动态机密接近过期、Agent 在内存里重新触发 env_template 渲染时，子进程会被 `SIGTERM` 终止再以新环境变量启动一遍。这个"整体重启"行为在交互式实验里很容易看到：旧应用打印的 `current_user` 在某一刻从 `v-approle-readonly-AAA…` 跳变成 `v-approle-readonly-BBB…`，连接断了又重连。

### 5.3 两个常被踩的坑

**第一**：env template 的双引号必须转义。Process supervisor 模式下 `contents` 是 HCL 字符串字面量，模板里出现的 `"` 必须写成 `\"`——这一点和官方示例完全一致。

**第二**：`error_on_missing_key = true` 几乎应该总是打开。默认行为是把访问不存在字段的结果渲染成字符串 `<no value>`，这会让旧应用拿着字符串 `<no value>` 去连数据库，错误信息非常难排查。官方文档明确推荐"It is highly recommended you set this to 'true'"。

> 同时打开顶层 `template_config.exit_on_retry_failure = true` 可以让 Agent 在重试失败后直接退出，而不是继续假装一切正常。这两个开关一起开，遗留应用拿到错凭据的概率会被显著压低。

---

## 6. 两条路的边界与选型小结

把"工具" × "形态"摊开看，文件渲染这一面 Consul-Template 与 Vault Agent 几乎打平——两个工具都能写文件、都能在模板变化时执行命令、都能续期 token。真正的不可替代点出现在**工具本身的部署形状**与**Process Supervisor Mode 那一面**。

**Consul-Template 真正不可替代的地方**：不是"能渲染文件"（Vault Agent 也能），而是它**作为独立 CLI 的部署形状**——

- 不需要长跑的 Agent 进程，可以用 `-once` 模式一次性渲染、退出，把"刷新一次配置文件"塞进任意一段已有的部署脚本；
- 部署管道里不引入新的常驻服务，对那些"已经把 systemd 单元 / Docker entrypoint 调得很稳"的环境来说，是最轻的接入方式；
- 凭据来源不必走 Vault Agent 的 auto-auth 抽象——你可以直接给它一枚通过别的渠道（CI、wrapped token、SSH 远程注入）拿到的 Vault token，灵活性更高。

**Vault Agent Process Supervisor Mode 真正不可替代的地方**：把 **`env_template`（模板渲染结果直接注入子进程环境变量）** 与**内置 `auto_auth`** 绑在同一个二进制里——

- **`env_template` 才是这条路独有的能力**：Consul-Template 的 Exec Mode 虽然也能 fork 并按 `reload_signal` / `kill_signal` 托管子进程，但 `exec.env.custom` 只接受**静态** `"KEY=VAL"` 列表，没法把 `{{ with secret "database/creds/readonly" }}` 的渲染结果直接挂成子进程 env，要凑出来必须先渲染到磁盘文件再包一层 shell；
- Agent 自己 fork 出来的子进程，凭据轮转时它能精确地按 `restart_stop_signal` → 30 秒退出窗口 → `SIGKILL` 这套语义把子进程换掉（CT Exec Mode 的 `kill_signal` + `kill_timeout` 语义近似，但默认值与触发时机不同）；
- `template_config.exit_on_retry_failure = true` + "子进程退出 Agent 也退出" 这一对开关组合，让"凭据拿不到时不要继续假装一切正常"成为可强制保证的运行时约束；
- auto-auth + 模板渲染 + 子进程托管在同一份配置文件里描述，运维只用维护一个 Vault Agent 进程而不再额外有 Consul-Template（CT 这一侧没有 auto-auth，token 必须靠外部渠道喂进来）。

**两者都不要承担的角色**：把 Vault Agent 或 Consul-Template 当成 init system / 进程监督器。Vault Agent 在 process supervisor 这一页的措辞已经写得非常克制——它"在很多方面会镜像子进程"，但**子进程自己退出时 Agent 也会以相同退出码退出**。所以 Agent 不是一个会替你"反复重启 crash 应用直到稳定"的看门狗；如果旧应用本身会高频崩溃，你仍然需要 systemd、Docker restart policy、Kubernetes liveness probe 这类传统进程供给者来兜底。

把上面所有要点合起来，遗留应用接入 Vault 的现代决策树可以简化成下面这张表：

| 旧应用读取机密的 IO 口 | 推荐路径 | 凭据变化时的应用行为 |
| --- | --- | --- |
| 本地配置文件 | Consul-Template **或** Vault Agent `template` 块（7.2 节）；选哪个取决于你想不想多跑一个 Agent | 写文件 + 可选 `exec` 命令触发 reload |
| 仅环境变量 | Vault Agent Process Supervisor Mode（`env_template` + `exec`） | Agent 按 `restart_stop_signal` 重启子进程 |
| 既不读文件也不读环境变量（例如等待外部连接推送配置） | 本节两个工具都不合适 | 转向 7.4 / 7.5 / 7.6 节的 Kubernetes 平台路径，或为应用补一层网络代理 |

---

## 7. 本节小结

把这一节压成一份可以贴在运行手册扉页上的认知清单：

1. **遗留应用接入 Vault 的关键是"不动应用"**：策略不是改源码，而是在它本来已经会读的 IO 口上"换一份内容";
2. **本节是"两种工具 × 两种形态"的对照演示**：Consul-Template 与 Vault Agent 能力高度重叠（两者都能把机密渲染成文件），但形态不同——前者是独立 CLI、适合塞进现成的 init / entrypoint，后者把 auto-auth + 模板渲染 + 子进程托管绑成一个二进制；本节故意各挑一面演示；
3. **租约的轮转最好交给本机组件，而不是应用自己**：Consul-Template 的 `renew_token` / `lease_renewal_threshold` 与 Vault Agent 的 secret renewer，都是为了在应用感知不到的层面把 lease 续起来；
4. **Process Supervisor 的硬约束要记牢**：至少一个 `env_template` + 恰好一个 `exec` + 与同一份配置里的文件型 `template` 互斥；
5. **它们都不是 init system**：crash / 长期监控 / 健康检查仍然要交给 systemd 或容器编排器。

至此，从"应用有源码、可改代码消费动态机密"到"应用没有源码、必须从外部注入动态机密"的这一公里已经被两条独立路径走通了。下一章会切到审计与观测一侧，去看这些动态机密、动态租约、动态用户怎么在审计设备里留下完整的取证证据。

---

## 8. 动手实验

本节配套了一个 Killercoda 实验：学员将在单台 Killercoda 主机上启动 dev 模式 Vault、PostgreSQL 容器，以及一个**故意写成"无法改造"**的 Go 程序（既能从 `/etc/legacy-app/config.toml` 读用户名密码，也能从环境变量 `DB_USER` / `DB_PASSWORD` 读，并每隔 10 秒做一次 `SELECT current_user, now()` 打印到 stdout）。然后依次完成两幕：

1. **第一幕：Consul-Template 渲染配置文件**：用一份显式开启 `renew_token` 的 `ct_config.hcl` + 简单 TOML 模板，让 Consul-Template 把 PostgreSQL 动态用户（`default_ttl=30s, max_ttl=2m`）写进 `/etc/legacy-app/config.toml`；先观察 CT 在 lease 半程时自动**续期**同一个用户，再观察 `max_ttl` 到点后 CT **重新申请**一个新用户、`pg_user` 里旧用户被 Vault 销毁；
2. **第二幕：Vault Agent Process Supervisor 注入环境变量**：复用同一份 Vault 配置与同一个 Go 二进制，写一份 `vault-agent.hcl`（含 `auto_auth` + 两个 `env_template` + 一个 `exec`），用 AppRole 完成 auto-auth；观察 Agent 在凭据接近到期时按 `restart_on_secret_changes = "always"` 整体重启子进程，旧应用打印的 `current_user` 在不动一行代码的前提下自动换名。

<KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/ch9-legacy-agent" title="实验：用 Consul-Template 与 Vault Agent Process Supervisor 让旧 Go 应用消费动态 Postgres 凭据" />
