# 恭喜完成 SSH 实验！🎉

这一节你把 Vault SSH 引擎现存的两条路径完整跑了一遍，并且**全程不动
宿主机的 sshd**——所有目标主机都是 docker 容器里的 sshd，实验完
`docker rm -f` 即可彻底清干净。

## 本实验的核心收获

| 阶段 | 你亲手验证的事实 |
| :--- | :--- |
| **CA 信任根** | Vault 生成的 CA 私钥永远不出 Vault；公钥就是要分发到目标主机的 `TrustedUserCAKeys` |
| **CA 签发流程** | role 控制 principals / extensions / TTL；证书一签出来 15 分钟就过期 |
| **典型故障 1** | role 漏 `default_user` → 证书没 principal → sshd 报 "name is not a listed principal" |
| **典型故障 2** | role 漏 `default_extensions={permit-pty:""}` → 命令能跑，交互式 shell 起不来 |
| **零账户态** | 目标主机 `~ubuntu/.ssh/authorized_keys` 完全不存在——CA 模式下目标机器对"谁能登"一无所知 |
| **Host Key Signing** | `@cert-authority` 一行替代每台主机的 known_hosts 指纹，规模化集群必备 |
| **OTP 模式** | helper + PAM 把 SSH 密码托管给 Vault；Vault 离线 = SSH 登录立刻失败 |
| **OTP 一次性** | 同一密码第二次登录被拒——Vault 在 storage 物理删除该 OTP |
| **CIDR 限制** | OTP 模式 role 的 `cidr_list` 在 Vault 端就把不合规 IP 拦掉 |
| **三种模式现状** | dynamic 已在 1.13 移除；现代选项就 CA 与 OTP 两条 |

## 5.4 思考题答案

> 如果在 10 台真实 Linux 服务器上推 CA 模式，**每台机器上唯一需要做
> 的运维动作**是什么？

**只有两件事，且只做一次**：

1. 把 Vault 给的 CA 公钥写入每台 `/etc/ssh/trusted-user-ca-keys.pem`
2. 在每台 `/etc/ssh/sshd_config` 加一行 `TrustedUserCAKeys
   /etc/ssh/trusted-user-ca-keys.pem`，重启 sshd

**之后**：

- 加新用户？**不用碰任何机器**——Vault 里给他一个能调签发 role 的
  Policy 即可
- 撤旧用户？**不用碰任何机器**——删 Policy / revoke token 即可，最
  迟等当前证书 TTL（5min）就彻底失效
- 换 CA？只这一次需要重新分发新 CA 公钥到每台机器

这就是 [3.5 章 §3](/ch3-ssh) 说的"加机器零成本"在工程实践中的字面
意义。

## 一张图总结整章

```
            ┌────────────────────────────────────────────┐
            │         Vault SSH 机密引擎                 │
            └─────────────────┬──────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              │                               │
       CA 模式 (Step 1-3)              OTP 模式 (Step 4)
       key_type=ca                     key_type=otp
              │                               │
       ┌──────┴──────┐                ┌───────┴───────┐
       │             │                │               │
   user cert     host cert         vault-ssh-helper  PAM 替换
   client签       host签            装到目标主机     auth 阶段
       │             │                │               │
       └──────┬──────┘                └───────┬───────┘
              │                                │
       sshd 本地用 CA 公钥验签         helper 每次回调 Vault 验证 OTP
       Vault 离线 → 登录仍可继续       Vault 离线 → 全部 SSH 失败
              │                                │
       规模友好 / 无在线依赖           老设备 / 密码-only 链路兜底
```

## 接下来去哪儿

回到 [3.5 章正文](/ch3-ssh)：§7 那张选型对比表现在每一格背后都有你
亲手验证过的事实；§8 那张 troubleshooting 速查表里 "name is not a
listed principal" 与 PTY 缺失你都现场撞过。

下一章预告：第 4 章身份认证方法。
