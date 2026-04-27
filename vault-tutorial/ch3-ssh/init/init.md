# 实验：SSH 机密引擎完整动手

3.5 章我们梳理了 Vault SSH 引擎的两条现存路径（dynamic 已在 1.13 移除）：

- **CA 模式**：Vault 当 SSH CA 签发短期证书；目标主机只信任 CA 公钥
- **OTP 模式**：目标主机装 `vault-ssh-helper` + 改 PAM；每次登录用 Vault 颁发的一次性密码

本实验把这两条路在 5 个 step 里完整跑一遍：

- **Step 1**：启用 SSH 引擎，让 Vault 生成 CA 私钥（私钥不出 Vault），看一眼 CA 公钥长什么样
- **Step 2**：CA 模式端到端——用 docker 启一个 ubuntu sshd 容器作目标主机，挂 CA 公钥，创建签发 role，签客户端证书，ssh 进去；中途**故意先不写 `default_user` 和 `permit-pty`**，让你亲眼看到那两个出名的错误现场
- **Step 3**：Host Key Signing——给目标主机的 host key 也签一份证书，客户端 known_hosts 写一行 `@cert-authority` 后不再回答 yes/no
- **Step 4**：OTP 模式——另起一个容器，装 vault-ssh-helper、改 PAM、配 sshd_config，然后 `vault write ssh/creds/...` 拿一次性密码登录
- **Step 5**：CA vs OTP 横向对比 + 容器清理

## 全程不动宿主机的 sshd

所有 SSH 目标主机都是 docker 容器（暴露在宿主机的 `127.0.0.1:2222` 与 `127.0.0.1:2223` 上），改 sshd_config / 装 vault-ssh-helper / 改 PAM 全部发生在容器里。Killercoda 宿主机的 sshd 维持原样，实验结束 `docker rm -f` 即可彻底清干净。

## 实验环境会预先

- 安装 Vault 并以 Dev 模式启动（root token = `root`）
- 持久化 `VAULT_ADDR` / `VAULT_TOKEN`，所有终端直接 `vault` 命令
- 安装 `jq` / `sshpass`，并预拉 `ubuntu:24.04` 镜像
- 为客户端生成一对 `~/.ssh/id_rsa`（无密码），后续 step 直接拿来签证书

不会预先启动任何 SSH 容器，也不会做任何 Vault 配置——所有 enable / 签发 / 登录都由你手动执行。
