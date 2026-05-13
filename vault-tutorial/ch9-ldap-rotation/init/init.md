# 实验说明

本实验配套 [9.5 节正文](https://lonegunmanb.github.io/vault-tutorial/ch9-ldap-rotation.html)：学员在正文里已经把『LDAP 是什么』『DN 与 bind 是什么』『Static Role 为什么不签发 Lease』『为什么写完 ldap/config 就要立刻 rotate-root』这几件事过了一遍。本实验把这些概念落到一台 Killercoda 主机上，**全程使用开源版 Vault（1.19.2，dev 模式）与开源 OpenLDAP（osixia/openldap:1.5.0 容器）**，不依赖任何商业组件、不依赖任何云资源。

## 已经为你准备好的环境

| 组件 | 用途 | 凭据 |
| --- | --- | --- |
| Vault 1.19.2，dev 模式 | LDAP 机密引擎 | `VAULT_ADDR=http://127.0.0.1:8200`、`VAULT_TOKEN=root`（已写入环境变量） |
| OpenLDAP（osixia/openldap:1.5.0） | 目标目录 | 监听 `127.0.0.1:389`；admin = `cn=admin,dc=learn,dc=example` / `2LearnVault` |
| 预置用户 | 剧本主角 | `cn=alice,ou=users,dc=learn,dc=example`，初始口令 `1LearnedVault` |
| 命令行工具 | 操作三方 | `vault`、`ldapsearch`、`ldapadd`、`jq`、`docker` |

## 实验四步

1. **第一步**：以『此时还没接入 Vault』的姿态用 `ldapsearch -D cn=alice... -w 1LearnedVault` bind 一次，亲眼看到目前 alice 的口令是**人工管理**的；
2. **第二步**：`vault secrets enable ldap` + `vault write ldap/config ...` 把 Vault 接到 OpenLDAP 上，然后**立刻** `vault write -f ldap/rotate-root`，验证旧的 `2LearnVault` 已经在 LDAP 端失效；
3. **第三步**：`vault write ldap/static-role/learn ...` 让 Vault 接管 alice 的口令，`vault read ldap/static-cred/learn` 拿到 Vault 当下持有的口令并 bind 成功；用旧的 `1LearnedVault` bind 失败；手动 `vault write -f ldap/rotate-role/learn` 再轮转一次，前一份口令也立即失败；
4. **第四步**：写一段**最小 bash 应用脚本**，模拟『某个外部服务每次启动都从 Vault 取一次口令再 bind LDAP』；前后两次运行之间手动触发一次轮转，看到两次的口令字符串不同但都 bind 成功。

> 全程使用明文 HTTP 与 Vault 交互（Vault 监听 `127.0.0.1:8200`）、明文 LDAP 与 OpenLDAP 交互（容器监听 `127.0.0.1:389`），是为了让学员能用 `tcpdump` / `strace` 等工具直接看清协议；生产环境应当按 [6.2 节](/ch6-listener-tls) 给 Vault 配上 TLS、按 [3.10 §2.1](/ch3-ldap) 把 LDAP 端切到 `ldaps://` 或开启 StartTLS。dev 模式 Vault 把数据保存在内存里、用 `root` Token，**绝对不能用于任何真实业务**。
