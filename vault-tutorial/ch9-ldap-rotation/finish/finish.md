# 恭喜完成端到端 LDAP 口令轮转实验！🎉

## 你亲手验证了什么

| 步骤 | 已验证 |
| --- | --- |
| **Step 1** | 在没有 Vault 的世界里，alice 的口令就是一段明文 `1LearnedVault`；任何知道这一串字符的人都能以 alice 身份 bind |
| **Step 2** | `vault write ldap/config`（用专为 Vault 准备的最小权限服务账号 `cn=vault,ou=services,...`）+ 立刻 `vault write -f ldap/rotate-root`：`2VaultBootstrap` 在 LDAP 端立即失效，只有 Vault 持有当下生效的服务账号口令；rootdn `cn=admin` 留作运维 break-glass，不交给 Vault |
| **Step 3** | `vault write ldap/static-role/learn ...` 这一条命令本身就会触发首次轮转——`1LearnedVault` 立即失效；手动 `rotate-role` 一次后，前一份 Vault 口令也立即失效 |
| **Step 4** | 一段最小 bash 脚本『每次启动都向 Vault 取最新口令』；前后两次运行之间手动轮一次，两次的口令字符串不同但**两次都 bind 成功**——消费代码对轮转无感 |

## 核心心智速记

```
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│      接入 Vault 之前                  接入 Vault 之后（本实验终态）       │
│   ─────────────────────       ──────────────────────────────────────────  │
│                                                                          │
│   alice 的口令 = "1LearnedVault"     alice 的口令 = <Vault 当下持有的随机串>│
│                                                                          │
│   谁知道这串字符 → 谁能动 alice      谁能调 vault read static-cred/learn  │
│                                       → 谁能动 alice                     │
│                                                                          │
│   口令轮转 = 全员加班、改配置        口令轮转 = vault write -f rotate-role │
│              重启服务、人工通报                  /learn （应用零感知）    │
│                                                                          │
│   万一外泄 = 紧急吊销、改密、         万一外泄 = 一条 rotate-role 命令    │
│              通知所有可能持有的人               立即让外泄的那一份失效    │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

## 把这套思路放回真实工程

- **怎么不再用 root token？** 把 [4.1 AppRole](/ch4-app-role)（最常见的应用静态接入方式）或 [4.4 K8s 认证](/ch4-k8s)（在容器编排里）配出来，让 step4 里那段 bash 应用在启动时先去拿一个**只绑 `consumer-policy.hcl`** 的短寿 Token，再去读 `ldap/static-cred/learn`——这就是 9.4 节正文第 5 节给出的那两条最小策略的真实落地形态。
- **怎么把『应用每次启动都读 Vault』升级成『应用持续运行、Vault 自动同步』？** [7.2 Vault Agent](/ch7-agent) 的 template 渲染机制就是为这件事生的——把口令渲染到 `/etc/myapp/ldap.conf`，应用直接读那个文件即可；Agent 在后台与 Vault 保持心跳、轮转一发生立刻把新值刷进去。
- **怎么让 LDAP 这一端的连接也走加密信道？** 把 `ldap/config` 的 `url` 改成 `ldaps://...:636`，或者保留 `ldap://...:389` 同时加上 `starttls=true`——具体见 [3.10 §2.1](/ch3-ldap)。生产里**永远不要**让 admin 凭据走明文链路。
- **想让 LDAP 用户能反过来登 Vault？** 那是另一个方向——**LDAP 认证方法**，对应 [4.7 节](/ch4-ldap)；本节的 `ldap/` 是机密引擎，向 LDAP 那侧**写**口令；认证方法是从 LDAP 那侧**读**用户身份再发 Vault Token。两件事走的代码路径完全不一样，请按 [3.10 §1](/ch3-ldap) 的『单选题』决定接哪个。
- **想要『用完即删』而不是『轮转固定账号』？** 那是 Dynamic Role —— [3.10 §4](/ch3-ldap) 已经讲过；本节专注于 Static Role 是因为它最贴近『接管一个目录里**已经存在**的真实账号』这种最常见的迁移场景。

## 清理

实验环境会随 Killercoda 容器一起销毁，无需手动清理。如果你想在本机重置：

```bash
docker stop vault-openldap 2>/dev/null
vault secrets disable ldap
```
