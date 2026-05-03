---
order: 40
title: 4.1 认证方法（Auth Methods）总览：身份的入口
group: 第 4 章：认证方法体系 (Auth Methods)
group_order: 40
---

# 4.1 认证方法（Auth Methods）总览：身份的入口

> **核心结论**：**Auth Method（认证方法）** 是 Vault 用来回答"你是谁"的
> 插件。它接收外部凭据（用户名密码、云平台签名、Kubernetes ServiceAccount
> JWT、OIDC ID Token、LDAP Bind …），验证通过后**签发一个 Vault Token**，
> 并把这枚 Token 绑定到对应的 **Identity Entity** 与一组 **Policy** 上。
> 之后所有对机密引擎的访问，都使用这枚 Token 进行鉴权。换言之：
> **Auth Method 负责"进门"，Secret Engine 负责"取东西"**。

参考：
- [Auth Methods — Vault Docs](https://developer.hashicorp.com/vault/docs/auth)
- [Authentication Concepts](https://developer.hashicorp.com/vault/docs/concepts/auth)
- [vault auth enable](https://developer.hashicorp.com/vault/docs/commands/auth/enable)

---

## 1. 什么是 Auth Method

官方定义非常直白：

> Auth methods are the components in Vault that perform authentication and
> are responsible for assigning identity and a set of policies to a user.

![Auth Method 与 Secret Engine 的区别：开门 vs 开箱](/images/ch4-auth-basic/auth-vs-secret.png)

拆开来看，一个 Auth Method 在一次登录流程里要完成三件事：

1. **验证外部凭据**：把调用方提交的凭据（密码 / 签名 / JWT / 证书 …）
   交给对应的后端校验，必要时回调外部系统（GitHub、AWS STS、Kubernetes
   TokenReview、OIDC Provider 等）。
2. **解析身份**：把校验结果映射成 Vault 内部的 **Entity / Alias**
   （详见 [2.5 Identity Entity](./ch2-identity-entity.md)），让"同一个人
   通过不同方式登录"在 Vault 看来仍然是同一个身份。
3. **签发 Token 并附加 Policy**：根据 Role / 配置给这枚 Token 绑定一组
   策略与 TTL，调用方拿着它去访问机密引擎。

> Vault 自身只信任 **Token** 一种东西。所有 Auth Method 的本质，都是
> "把一种外部凭据 *换* 成一枚 Vault Token"。

## 2. 它在 Vault 里以什么形式存在

Auth Method 和 Secret Engine 一样，都是**挂载到 Mount Table 上的插件**，
路径前缀统一是 `auth/`：

```shell-session
$ vault auth enable userpass
# 默认挂载到 auth/userpass/

$ vault auth enable -path=corp-ad ldap
# 自定义挂载到 auth/corp-ad/

$ vault auth disable corp-ad
# 禁用后，所有通过该方法登录的 Token 会被立即吊销
```

由此可得几个直接推论：

- 同一种类型的 Auth Method 可以**多次挂载**到不同路径，分别配置（例如
  公司内网 LDAP 与子公司 LDAP 各挂一份）。
- 禁用一个 Auth Method = **批量登出**所有通过它登录的用户。
- Auth Method 也支持 `tune`（调 TTL、审计日志、描述等），机制与机密引擎一致。

## 3. 内置类别速览（开源版）

按"凭据来源"可粗略分成四类，后续小节会逐个动手实验：

| 类别                   | 代表方法                              | 典型场景                               |
| ---------------------- | ------------------------------------- | -------------------------------------- |
| 用户/口令型            | `userpass`、`ldap`、`okta`、`radius` | 人类用户、传统目录服务                 |
| 平台/工作负载身份型    | `kubernetes`、`aws`、`gcp`、`azure`、`alicloud`、`jwt` | 容器、云上 VM、CI/CD 流水线          |
| 联邦/SSO 型            | `oidc`、`jwt`、`saml`(企业)、`github`| 浏览器登录、与 IdP 集成                |
| 凭据型 / 自举型        | `token`、`approle`、`cert`、`tls`     | 服务到服务、机器引导（Secret Zero）   |

> 本章后续小节会聚焦在开源版仍受支持、且现代架构中真正在用的方法
> （`userpass`、`approle`、`kubernetes`、`jwt/oidc`、`cert` …）。已废弃
> 或被边缘化的旧后端（如内置 `app-id`）不再涉及。

## 4. 与 Secret Engine 的关系：进门 vs 取东西

这是初学者最常混的两个概念，一句话总结：

> **Auth Method 决定你能不能拿到 Token；Secret Engine 决定这枚 Token
> 能取出什么机密。** 两者都是挂载式插件，都走同一套 Router / Policy /
> Audit 管道，只是职责不同：

| 维度       | Auth Method (`auth/...`)                    | Secret Engine (`secret/`、`pki/`、`database/`...) |
| ---------- | ------------------------------------------- | -------------------------------------------------- |
| 回答的问题 | "你是谁？" (AuthN)                          | "你能取/生成什么数据？"                            |
| 输入       | 外部凭据（密码、JWT、签名 …）               | 已携带 Token 的 API 请求                           |
| 输出       | 一枚 Vault Token + 绑定的 Identity & Policy | 机密值 / 动态凭据 / 加解密结果                    |
| 挂载前缀   | 必须在 `auth/` 下                           | 任意路径（默认按类型，如 `pki/`、`database/`）    |
| 何时调用   | **登录**时一次（以及续期/重认证）           | **每次**读写机密时                                 |

一次完整的访问链路因此是：

```
外部凭据 ──▶ Auth Method ──▶ Vault Token (+ Policy + Entity)
                                  │
                                  ▼
                          Secret Engine ──▶ 机密 / 动态凭据
```

理解这条链路后，本章后续的 `userpass`、`approle`、`kubernetes`、
`jwt/oidc` 等小节就只是在替换链条最左边那一段而已，右半截的机密引擎
完全复用第 3 章学过的内容。

---

## 5. 本节小结

- Auth Method 是 Vault 中**唯一**用来"认人/认机器"的组件，输出物永远
  是一枚 Token。
- 它和 Secret Engine 同构（都挂在 Mount Table 上、都走 Router / Policy /
  Audit），但职责正交：**一个管进门，一个管取物**。
- 实际生产里通常会**同时启用多个** Auth Method：人用 OIDC，CI 用
  AppRole，集群里的 Pod 用 Kubernetes，云上 VM 用云平台原生身份——它们
  最终都通过 Identity Entity 汇聚成同一个"人/服务"的视图。
- 本节是纯概念课，不配套实验；下一节起会逐个 Auth Method 动手演练。
