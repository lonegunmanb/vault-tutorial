# 恭喜完成 LDAP 机密引擎实验！🎉

## 你亲手验证了什么

| 步骤 | 已验证的事实 |
| --- | --- |
| **Step 1** | Vault 凭 `binddn` 操作 LDAP，写入 `ldap/config` 后即可在 OpenLDAP 上看见所有预置账号 |
| **Step 2 Static** | 创建 role 时立即首次轮转 → 原始密码失效；按 `rotation_period` 周期再轮；旧密码登 LDAP 总是失败 |
| **Step 3 Dynamic** | `creation_ldif` 现场创建临时账号 + Lease；revoke 或 TTL 过期时按 `deletion_ldif` 自动销毁 |
| **Step 4 Library** | 借出瞬间换密、归还瞬间再换密；同一账号借两次得到不同密码；池子借空再借会失败 |

## 三种模式同图速记

```
                   Vault LDAP 机密引擎的三种模式
        ┌──────────────┬────────────────┬─────────────────────┐
        │   Static     │    Dynamic     │      Library        │
        ├──────────────┼────────────────┼─────────────────────┤
账号    │ 长寿命       │ 短寿命         │ 长寿命              │
密码    │ 周期轮转     │ 创建时一次     │ 借/还瞬间各换一次   │
谁建    │ LDAP 管理员  │ Vault          │ LDAP 管理员         │
谁删    │ 不删         │ Vault (Lease)  │ 不删                │
有 Lease│ 否           │ 是             │ 是 (持借出关系)     │
适合    │ 老旧应用     │ 一次性消费     │ Break-Glass / SRE   │
        └──────────────┴────────────────┴─────────────────────┘
```

## 三个最容易踩的坑

1. **多行 LDIF 必须用 `@file` 或 base64**——直接粘到命令行换行会被吃，导致 `creation_ldif` 解析失败。

2. **Active Directory 必须 LDAPS**——AD 的 `unicodePwd` 改密只能走加密通道。本实验用 OpenLDAP
   的明文 LDAP；切到 AD 时必须改 `url=ldaps://...` 并提供 CA。

3. **`disable_check_in_enforcement` 默认 false**——只有"借的人"能还。多人协作时如果允许同事代还，
   要显式设为 true，但要承担"失去借用人追踪"的代价。

## 与下一节的衔接

本节是 "Vault 管理 LDAP 账号"。如果你想反过来——让 LDAP 用户用自己的目录账号**登录 Vault**——
那是 **未来 7.X LDAP 认证方法** 的内容。两节搭配：

```
本节 (3.10):  Vault → LDAP   (改密 / 建账号)
未来 (7.X):  LDAP user → Vault (登录拿 Token)
```

**返回文档**：[3.10 LDAP 机密引擎](/ch3-ldap)
