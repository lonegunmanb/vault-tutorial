# 第五步：CA vs OTP 选型对比与清理

跑完 Step 1–4，两种模式的全链路都在你眼前发生过一次。这一步把
[3.5 章 §7](/ch3-ssh) 的对比表"用你刚才看到的事实"再过一遍，确保选
型直觉立得住，然后把容器和挂载都清干净。

## 5.1 用刚才看到的事实回顾对比

| 维度 | CA 模式（Step 1–3） | OTP 模式（Step 4） |
| :--- | :--- | :--- |
| **目标主机改造** | sshd_config 加一行 `TrustedUserCAKeys` + 挂入 CA 公钥 | 装 vault-ssh-helper 二进制 + 改 `/etc/pam.d/sshd` + 改 sshd_config |
| **登录瞬间是否需要 Vault 在线** | ❌ 不需要——sshd 用本地 CA 公钥就能验签 | ✅ 必须在线——helper 每次都要回调 `ssh/verify` |
| **客户端是否需要 SSH 私钥** | ✅ 需要 id_rsa | ❌ 不需要，纯密码 |
| **审计记录在哪发生** | 证书签发那一刻在 Vault | 每次 SSH 登录都在 Vault |
| **TTL 含义** | 证书有效期（5min 起） | OTP 用一次即焚 |
| **新增主机成本** | 分发同一个 CA 公钥，sshd_config 一行 | 每台都要 install + PAM + cidr_list |
| **撤权速度** | 等当前最大证书 TTL | 立即（下一次登录就被拒） |

亲手验证过的关键事实：

- **Step 2.7** 容器里 `~ubuntu/.ssh/authorized_keys` 是不存在的——
  CA 模式下目标主机零账户态
- **Step 4.5** 同一 OTP 第二次用立刻被拒——OTP 一次性不是文档承诺，
  是 Vault 在 storage 里物理删除
- **Step 4.6** `cidr_list` 在 Vault 一侧就拦下了 OTP 申请，根本到不
  了 sshd

## 5.2 一句话结论

```
服务器 > 10 台         →  CA 模式
密码-only / 老设备     →  OTP 模式
两者都不行             →  在前面架 Bastion，bastion 用 CA 接进来
```

## 5.3 清理实验资源（可选）

容器一删干净，宿主机就回到完全没动过的状态：

```bash
docker rm -f ssh-target-ca ssh-target-otp 2>/dev/null
docker ps -a | grep -E "ssh-target" || echo "✓ 无残留容器"
```

Vault 里的两个挂载也可以禁掉（Dev 模式重启就没了，但手动禁也成）：

```bash
vault secrets disable ssh-client-signer
vault secrets disable ssh-host-signer
vault secrets disable ssh
vault secrets list | grep -E "ssh" || echo "✓ 无残留挂载"
```

宿主机上签出的几个工件可以一并清掉：

```bash
rm -f /root/trusted-user-ca-keys.pem \
      /root/host-trusted-ca.pem \
      /root/ssh_host_rsa_key.pub \
      /root/ssh_host_rsa_key-cert.pub \
      /root/.ssh/id_rsa-cert.pub
```

> `/root/.ssh/id_rsa` 本身是实验环境创建的客户端密钥，留着或删掉都
> 行——它跟任何真实身份无关。

## 5.4 留个思考题

实验全部用容器作目标主机，宿主机的 sshd 完全没动。如果换一个真实
的多机环境（10 台 Linux 服务器），把 Step 1–3 那套搬过去，**唯一需
要在每台机器上做的运维动作**是什么？请回到 [3.5 章 §3](/ch3-ssh)
那张架构图思考一下，然后看下方 finish 给的答案。
