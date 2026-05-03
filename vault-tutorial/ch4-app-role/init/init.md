# 实验：AppRole 认证完整动手

[4.2 章](/ch4-app-role) 把 AppRole 的概念、字段、推荐使用范式与反模
式都梳理了一遍。本实验在 5 个 step 里把这些纸面规则**亲手跑一次**：

- **Step 1**：按 [官方 Configuration → Via the CLI](https://developer.hashicorp.com/vault/docs/auth/approle#via-the-cli)
  的最小步骤启用 approle、创建 role、取 RoleID + SecretID、用两半凭据登录拿到 token——**Pull 模式的最小可用闭环**
- **Step 2**：把约束字段一个一个加上去——`bind_secret_id`、
  `secret_id_num_uses=1`——并触发"SecretID 用完第二次再用就被拒"的
  现场
- **Step 3**：`secret_id_bound_cidrs` + `token_bound_cidrs`——用**故
  意把客户端 IP 排除在外**的方式触发 Vault 端拒收，看清 CIDR 约束在
  哪一层生效
- **Step 4**：Response Wrapping 完整 trusted-broker 演练——给 worker
  发一枚带 `min_wrapping_ttl` / `max_wrapping_ttl` 的策略 token，让它
  只能取 wrapped SecretID；再演一次 **双重 unwrap 立刻失败**——这
  就是审计层用来识破"中途偷看"的根因
- **Step 5**：把第 4.2 章 §8 的三种反模式与推荐范式并排敲一遍命令对
  比；最后清理

## 实验环境会预先

- 安装 Vault 并以 Dev 模式启动（root token = `root`）
- 持久化 `VAULT_ADDR` / `VAULT_TOKEN`，所有终端直接 `vault` 命令
- 安装 `jq`
- **不会**预先 enable approle、不会预先创建任何 policy / role——所有
  这些动作都由你在 step 里手敲

不会启动任何容器——AppRole 是纯 Vault 内的认证方法，不像 SSH / LDAP
那样需要外部目标主机。
