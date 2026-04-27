# 恭喜完成 TOTP 机密引擎实验！🎉

## 你亲手验证了什么

| 步骤 | 已验证 |
| --- | --- |
| **Step 1** | RFC 6238 算法肌肉记忆：30 秒一个窗口、同 secret 同时间 → 同码 |
| **Step 2 Generator** | Vault 自己持 secret 并出码；与 `oathtool` 同 secret 算出的码完全一致；不能被 `vault write code=` 校验 |
| **Step 3 Provider** | 调用者写入 secret；外部生码 + Vault 校验；不能被 `vault read code/` 读出 |
| **Step 4 锁死与容忍** | `exported=false` 永久锁死 secret；`skew` 控制 ±窗口数；过期码被拒；**Vault 不防重放** |

## 两种角色一图速记

```
            Generator 模式                 Provider 模式
       (vault read totp/code/...)    (vault write totp/code/... code=)
              │                              │
              ▼                              ▼
        Vault 是 Authenticator         Vault 是 Verifier
        secret 放在 Vault 里           secret 由调用者提供
        外部系统拿码去登入             用户输码 → Vault 校验
              │                              │
        典型场景：                     典型场景：
        ► 老旧 SSH 跳板加 MFA          ► 自家 Web 站加 MFA 后端
        ► 集中托管 MFA 种子            ► 替代 Google Auth Server
```

## 三个最容易踩的坑

1. **Policy 写错操作动词**：Generator 给 `read`、Provider 给 `update`。混了就 403。
2. **`exported=false` 后无法导出 backup**：删了重建是唯一恢复路径。涉及金融场景务必先评估。
3. **TOTP 引擎不防重放**：业务侧必须自维护"近期已用码"集合，否则攻击者截获一次码后可在 skew 窗口内重放。

## 与下一节的衔接

- [3.13 Transit 引擎](/ch3-transit) 同样是"无业务数据，纯密码学服务"——TOTP 是"时间一次性密码"，Transit 是"对称/非对称加解密+签名"。两章合起来构成 Vault 的"密码学即服务"双子星。
- 未来的 **MFA 章节**会展示如何把本节的 Provider 模式接入 Vault 自己的 Login Step-up 流程，做到"用 Vault 校验自己 Vault 的二次因子"。

**返回文档**：[3.12 TOTP 机密引擎](/ch3-totp)
