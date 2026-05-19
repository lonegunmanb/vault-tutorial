import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'Vault 交互式教程',
  description: '基于 Killercoda 的零成本交互式 HashiCorp Vault 教程',
  base: '/vault-tutorial/',
  lang: 'zh-CN',
  sitemap: {
    hostname: 'https://lonegunmanb.github.io/vault-tutorial/'
  },

  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><text y=".9em" font-size="90">🔐</text></svg>' }],
  ],

  themeConfig: {
    nav: [
      { text: '首页', link: '/' },
      { text: '开始学习', link: '/intro' },
    ],

    // @auto-sidebar-start
    sidebar: [
      {
        text: '教程章节',
        items: [
         { text: '课程介绍', link: '/intro' },
         { text: '什么是现代意义上的 Vault', link: '/what-is-vault' },
         {
           text: '第 2 章：核心机制与高级状态机概念',
           collapsed: false,
           items: [
             { text: '2.1 "Dev" 开发模式的适用边界与安全风险预警', link: '/ch2-dev-mode' },
             { text: '2.2 封印与解封（Seal/Unseal）机制的密码学底层原理', link: '/ch2-seal-unseal' },
             { text: '2.3 租约（Lease）、无感续期与强制撤销的生命周期管理', link: '/ch2-lease' },
             { text: '2.4 认证（Authentication）与令牌（Tokens）树状层级关系本质', link: '/ch2-auth-tokens' },
             { text: '2.5 身份实体（Identity Entity）：打通多维度认证源的元数据中心', link: '/ch2-identity-entity' },
             { text: '2.6 细粒度策略（Policies）与合规性密码策略（Password Policies）编写指南', link: '/ch2-policies' },
             { text: '2.7 响应封装（Response Wrapping）与防篡改一次性数据传递', link: '/ch2-response-wrapping' }
           ]
         },
         {
           text: '第 3 章：核心机密引擎管理体系 (Secret Engines)',
           collapsed: false,
           items: [
             { text: '3.1 机密引擎概览：路由、生命周期与 Barrier View', link: '/ch3-secrets-engines' },
             { text: '3.2 Key/Value (KV v2) 引擎：版本控制的现代静态机密存储', link: '/ch3-kv-v2' },
             { text: '3.3 AWS 机密引擎：动态 IAM 凭据与租约即生命周期', link: '/ch3-aws' },
             { text: '3.4 Cubbyhole 机密引擎：每个 Token 一个私人储物柜', link: '/ch3-cubbyhole' },
             { text: '3.5 SSH 机密引擎：从静态密钥到 CA 签发与一次性密码', link: '/ch3-ssh' },
             { text: '3.6 Identity 机密引擎：Vault 的身份中枢与 OIDC 提供商', link: '/ch3-identity' },
             { text: '3.10 LDAP 机密引擎：托管目录账号的密码轮转、动态创建与借出归还', link: '/ch3-ldap' },
             { text: '3.11 Kubernetes 机密引擎：让 Vault 为 K8s 集群签发动态 ServiceAccount Token', link: '/ch3-k8s' },
             { text: '3.12 PKI 机密引擎：让 Vault 成为你的证书颁发机构', link: '/ch3-pki' },
             { text: '3.12 TOTP 机密引擎：让 Vault 同时充当生成器与校验端', link: '/ch3-totp' },
             { text: '3.13 Transit 机密引擎：加密即服务 (Encryption as a Service)', link: '/ch3-transit' },
             { text: '3.14 PostgreSQL 数据库机密引擎：动态账号、静态轮转与连接接管', link: '/ch3-postgres' },
             { text: '3.15 MySQL/MariaDB 数据库机密引擎：动态账号、通配授权与云 IAM', link: '/ch3-mysql' }
           ]
         },
         {
           text: '第 4 章：认证方法体系 (Auth Methods)',
           collapsed: false,
           items: [
             { text: '4.1 认证方法（Auth Methods）总览：身份的入口', link: '/ch4-auth-basic' },
             { text: '4.2 AppRole 认证：机器登录 Vault 的"用户名/密码"', link: '/ch4-app-role' },
             { text: '4.3 AWS 认证：用云平台身份直接登录 Vault', link: '/ch4-aws' },
             { text: '4.4 Kubernetes 认证：让 Pod 用 ServiceAccount 身份登录 Vault', link: '/ch4-k8s' },
             { text: '4.5 GitHub 认证：用个人访问令牌登录 Vault', link: '/ch4-github' },
             { text: '4.6 LDAP 认证：让目录用户用账号密码登录 Vault', link: '/ch4-ldap' },
             { text: '4.7 TLS 证书认证：用客户端证书登录 Vault', link: '/ch4-cert' },
             { text: '4.8 Userpass 认证：Vault 内置用户名密码登录', link: '/ch4-userpass' },
             { text: '4.9 JWT/OIDC 认证：用签名令牌登录 Vault', link: '/ch4-jwt' }
           ]
         },
         {
           text: '第 5 章：现代命令行工具与高级管理实战 (CLI)',
           collapsed: false,
           items: [
             { text: '5.1 核心 CRUD 交互指令：read, write, delete, list, patch 深度应用', link: '/ch5-crud-commands' },
             { text: '5.2 认证与生命周期管控：login, auth, token 复杂参数体系', link: '/ch5-auth-token-lifecycle' },
             { text: '5.3 访问策略与底层引擎挂载管理：policy, secrets 生命周期运维', link: '/ch5-policy-secrets' },
             { text: '5.4 静态 KV 引擎专属高级指令：get, put, metadata 管理与历史版本 rollback', link: '/ch5-kv-commands' },
             { text: '5.5 另一些重要命令：lease / unwrap / ssh / path-help', link: '/ch5-other-commands' },
             { text: '5.6 轻量级代理服务指令：vault proxy 的配置文件解析与进程调试', link: '/ch5-vault-proxy' },
             { text: '5.7 集群底层运维手术刀：operator 指令簇全解', link: '/ch5-operator-commands' },
             { text: '5.8 底层引擎挂载点无损热迁移（Mount Migration）技术剖析', link: '/ch5-mount-migration' }
           ]
         },
         {
           text: '第 6 章：集群配置文件调优与高可用自动化运维',
           collapsed: false,
           items: [
             { text: '6.1 配置文件架构纵览与现代 HCL 语法规范', link: '/ch6-config-overview' },
             { text: '6.2 网络监听器（Listener）与最高级别 TLS 协议族强化配置', link: '/ch6-listener-tls' },
             { text: '6.3 自动化云端解封（Auto-Seal）机制对接（AWS KMS, Azure Key Vault, Transit 代理）', link: '/ch6-auto-seal' },
             { text: '6.4 现代存储引擎的绝对基石：Integrated Storage (Raft) 协议与自动化运维', link: '/ch6-integrated-storage' },
             { text: '6.5 其他存储后端：Consul / DynamoDB / Filesystem / In-Memory / PostgreSQL / S3', link: '/ch6-other-storage' },
             { text: '6.6 集群高可用模式（HA）的设计哲学及其数据一致性保障', link: '/ch6-ha' },
             { text: '6.7 分布式服务注册与发现（K8s 原生发现机制与 Consul 集成模式）', link: '/ch6-service-registration' },
             { text: '6.8 核心指标遥测（Telemetry）暴露与可视化 UI 界面底层配置', link: '/ch6-telemetry-ui' },
             { text: '6.9 User Lockout：内核级防暴力破解机制', link: '/ch6-user-lockout' }
           ]
         },
         {
           text: '第 7 章：应用自动化接入与 Kubernetes 云原生集成',
           collapsed: false,
           items: [
             { text: '7.1 章节导览与三种接入形态选型', link: '/ch7-overview' },
             { text: '7.2 Vault Agent：本机模板渲染、令牌托管与进程供给', link: '/ch7-agent' },
             { text: '7.3 Vault Proxy：API 代理、缓存与应用身份边界', link: '/ch7-vault-proxy' },
             { text: '7.4 Kubernetes 集成模式之一：Vault Agent Sidecar Injector（vault-k8s）', link: '/ch7-agent-injector' },
             { text: '7.5 Kubernetes 集成模式之二：Secrets Store CSI Driver + Vault Provider', link: '/ch7-csi' },
             { text: '7.6 Kubernetes 集成模式之三：Vault Secrets Operator (VSO) 控制器与 CRD 模型', link: '/ch7-vso' },
             { text: '7.7 三种 Kubernetes 集成模式选型与本章小结', link: '/ch7-k8s-selection' }
           ]
         },
         {
           text: '第 8 章：安全合规审计与系统观测',
           collapsed: false,
           items: [
             { text: '8.1 审计日志综述', link: '/ch8-audit-overview' },
             { text: '8.2 三种内置审计设备配置详解（File / Syslog / Socket）', link: '/ch8-audit-devices' },
             { text: '8.3 审计日志最佳实践（含 CVE-2025-6000 安全加固指导）', link: '/ch8-audit-best-practices' }
           ]
         },
         {
           text: '第 9 章：全栈架构防线升级与现代工程实战案例',
           collapsed: false,
           items: [
             { text: '9.1 上线前的安全加固清单与请求速率限流配额', link: '/ch9-production-hardening' },
             { text: '9.2 加密即服务（EaaS）：让一个 Go Web 应用『不再保管密钥』', link: '/ch9-eaas-transit' },
             { text: '9.3 用 Vault Agent 缓存为高频读请求降压：动态租约复用与 token 续期托管', link: '/ch9-agent-cache' },
             { text: '9.4 ACME 协议自动化 TLS 证书签发：让 Vault PKI 与 Caddy 自动协商并续期', link: '/ch9-acme-caddy' },
             { text: '9.5 端到端案例：用 Vault 接管 OpenLDAP 用户口令的轮转生命周期', link: '/ch9-ldap-rotation' },
             { text: '9.5 Vault 故障排查方法论：从可观测性数据反推根因', link: '/ch9-troubleshoot' },
             { text: '9.6 Vault 作为身份代理（Identity Broker）：把 AWS IAM 与 K8s ServiceAccount 联邦到 PostgreSQL 动态账号', link: '/ch9-identity-broker-postgres' },
             { text: '9.7 Terraform 与 Vault Provider：用动态 AWS 凭据运行基础设施变更', link: '/ch9-terraform-vault-aws' },
             { text: '9.8 让无法改造的遗留应用接入 Vault：Consul-Template 与 Process Supervisor 双轨实践', link: '/ch9-legacy-agent' },
             { text: '9.9 把 Vault 当成网站的 LDAP + TOTP 登录网关：两阶段登录与首次绑定', link: '/ch9-ldap-mfa-gateway' }
           ]
         }
        ],
      },
    ],
    // @auto-sidebar-end

    socialLinks: [
      { icon: 'github', link: 'https://github.com/lonegunmanb/vault-tutorial' },
    ],

    outline: { label: '本页目录' },
    docFooter: { prev: '上一章', next: '下一章' },
    darkModeSwitchLabel: '主题',
    sidebarMenuLabel: '菜单',
    returnToTopLabel: '回到顶部',
  },
})
