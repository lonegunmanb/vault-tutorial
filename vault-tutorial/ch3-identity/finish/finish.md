# 恭喜完成 Identity 引擎实验！🎉

这一节你把 `identity/` 这个特殊内置引擎从"挂载层面"到"OIDC IdP
端到端"再到"1.19+ dedup 激活"全部亲手跑了一遍。

## 本实验的核心收获

| 阶段 | 你亲手验证的事实 |
| :--- | :--- |
| **默认挂载 + 四不允许** | `identity/` 与 `cubbyhole/` 同属"内置不可拆"家族——`disable` / `move` / 二次 `enable` / `tune` 全部硬拒 |
| **Entity / Alias / Group CRUD** | Alias 必须用 `mount_accessor`（不是 path）；同一 Entity 跨 mount 的归并要**显式**做；internal vs external group 的成员模型截然不同 |
| **Identity Tokens 三件套** | `key`（带 `rotation_period` / `verification_ttl`） + `role`（带 template / ttl / client_id / key 引用） + `token`（只能为请求者自己的 Entity 签）= OIDC 规范的 JWT |
| **双重验证姿势** | JWKS / Discovery 完全脱离 Vault；introspect 能感知 Entity 撤销但要 Vault Token——绝大多数场景用前者 |
| **OIDC Provider 端到端** | 默认 provider + 默认 key 已经在；缺的两步是 client + assignments；assignments 默认空 = 全拒 |
| **dedup 激活的不可逆** | `force-identity-deduplication` 是 one-way flag；激活后每次 unseal 都跑去重校验；激活前的重复不会自动 merge |

## 一张图总结四步因果链

```
Step 1: identity/ 是 Vault 的身份对象 CRUD 中枢
            │
            ▼
Step 2: 在它的子路径 oidc/key + oidc/role + oidc/token 上
        把"Entity 元数据 → 标准 OIDC JWT"这条链路搭起来
            │
            ▼
Step 3: 再在外层加 oidc/provider + oidc/client + oidc/assignment
        三件套，把 Vault 反向变成下游应用的 OIDC IdP
            │
            ▼
Step 4: 1.19+ 引入 force-identity-deduplication 一次性闸门，
        保证"同一个身份永远只对应一个 Entity"在底层得到强制
```

## 最容易踩的三个坑

1. **Alias 没绑 `mount_accessor` 就写 entity-alias** → Vault 直接拒
   绝。永远记得：alias 绑 accessor，**不是** mount path（这也是
   [5.7 Mount Migration](/ch5-mount-migration) 之所以能不打断身份归
   并的原因）。
2. **建好 OIDC client 就以为能用了** → `assignments` 默认是空数组、
   等于全拒；或者忘了把 client_id 加到 provider 的 `allowed_client_ids`
   ——这两个白名单**都要配齐**才能登录成功。
3. **看到 `DUPLICATES DETECTED` 就直接激活 force-identity-deduplication**
   → **大坑**。激活前已存在的重复不会自动 merge，要先按官方文档第
   2-3 步手工清，再激活。一旦激活就再也回不去。

## 与下一节的衔接

`identity/` 引擎这一节讲的是"基础设施层面的身份发证 + IdP 能力"。
具体把它接到一个真实 RP（Boundary、Consul、自研管理后台）实现端到端
SSO 的实战，是 [7.11 / 7.12](/) 的内容——本节给的是那两节的全部底
层支撑。

把 [3.4 Cubbyhole](/ch3-cubbyhole) + 本节合在一起，你就完整掌握了
Vault 里**两个**特殊的内置引擎——其它所有引擎（KV、AWS、SSH、PKI...）
都是普通的"挂载即用、用完即拆"模型，没有这两位的挂载层硬约束。
