# 恭喜完成 KV v2 实验！🎉

这一节你把 KV v2 区别于 v1 的所有关键机制都亲手跑了一遍。

## 本实验的核心收获

| 阶段 | 你亲手验证的事实 |
| :--- | :--- |
| **`data/` vs `metadata/`** | CLI 自动拼接，但 `vault read` / Policy / HTTP API 必须显式写出 |
| **JSON envelope 双层 `data`** | `data.data` 是业务字段，`data.metadata` 是版本元数据 |
| **版本历史** | `put` 永不覆盖，每次 `+1`，`get -version=N` 任意回读 |
| **`patch` vs `put`** | `put` 全量覆盖（缺字段会丢），`patch` 字段级合并 |
| **CAS 写并发** | `cas_required=true` 后所有写必须带匹配的 `-cas=N`，过时即拒绝 |
| **`max_versions` 自动回收** | 超出阈值的最早版本被自动 destroy，metadata 仍标记 |
| **删除三态** | `delete`（可逆）→ `destroy`（数据擦除）→ `metadata delete`（连元数据清空） |
| **Policy 必须按动作分段** | `data/`、`metadata/`、`delete/`、`undelete/`、`destroy/` 各自单独授权 |

## 最容易踩的两个坑

1. **Policy 写成 v1 风格**：`path "kv/app/*" { ... }` 在 KV v2 上**完全不命中**——必须写成 `path "kv/data/app/*"`、`path "kv/metadata/app/*"` 等。本实验 §4.1–4.4 把这个坑实地踩了一次。
2. **`put` 覆盖了没列出的字段**：每次 `put` 都是新快照的全部内容，缺字段就是字段消失。要安全地"只改一项"得用 `vault kv patch`。

## 删除三态的设计意图速查

```
                     可恢复 ←────────── 不可恢复
                                                 
   ┌────────────┐   ┌───────────┐   ┌─────────────┐   ┌─────────────────────┐
   │  正常状态   │ → │  vault    │ → │  vault kv   │ → │ vault kv metadata   │
   │            │   │  kv delete│   │  destroy    │   │ delete              │
   └────────────┘   └───────────┘   └─────────────┘   └─────────────────────┘
                          │              │                     │
                     deletion_time     destroyed=true      整条 key 消失
                     可 undelete       数据已擦除          数据 + 元数据全没
                                       元数据仍在
```

设计 Policy 时把可恢复 / 不可恢复两类分开授权——日常运维只给 `delete/undelete`，把 `destroy/metadata delete` 留给安全管理员。

## 下一步

后续小节会继续按"机密引擎光谱"挑选有代表性的引擎深入：

- **3.x（待选）** Database 动态凭据：让 Vault 收到读请求时**实时**生成临时数据库账号
- **3.x（待选）** Transit：加密即服务（EaaS），不存数据，只对外加解密
- **3.x（待选）** PKI + ACME：让内部 X.509 证书自动签发与续期

每一种引擎都遵循 3.1 章建立的**路由 + 生命周期 + Barrier View**模型——而本节学到的"路径段必须精确写到 Policy 里"是 v2 这种"多面孔"引擎的特殊纪律。后续遇到 Database 引擎的 `creds/`、PKI 引擎的 `issue/`、`sign/` 时，回想 KV v2 的 `data/` 与 `metadata/`——你会发现它们都是同一种设计哲学。
