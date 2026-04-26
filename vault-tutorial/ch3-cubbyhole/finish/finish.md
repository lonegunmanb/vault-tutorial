# 恭喜完成 Cubbyhole 实验！🎉

这一节你把 Cubbyhole 引擎区别于其它一切引擎的关键性质都亲手跑了一遍。

## 本实验的核心收获

| 阶段 | 你亲手验证的事实 |
| :--- | :--- |
| **默认挂载** | Vault 启动时 `cubbyhole/` 已经在那儿，不用 enable |
| **三不允许 + tune 也不行** | `disable` / `move` / 二次 `enable` / `tune` 全部硬拒，错误信息分别是 `cannot unmount` / `cannot remount` / `is not mountable` / `cannot tune` |
| **Token 隔离** | 同名路径 `cubbyhole/hello`，root 和子 token 各写一份，互相完全看不见——root 也不行 |
| **Token 寿命即数据寿命** | TTL 到期或被 revoke 时，cubbyhole 数据被原子销毁；父 token 被 revoke 时连子 token 的 cubbyhole 也跟着没 |
| **没有"管理员视图"** | Vault 没有任何受支持的 API 能让 root 跨 token 读对方的 cubbyhole |
| **Response Wrapping = Cubbyhole 的应用** | `cubbyhole/response` 字面就是 wrapping token 私有命名空间下的那条响应；unwrap = 读 + revoke + cubbyhole 物理销毁 |

## 一张图总结四步因果链

```
Step 1: cubbyhole 是单例、生命周期被锁
            │
            ▼
Step 2: 因为它的"可见性单位 = Token"在底层就是单实现
            │
            ▼
Step 3: 因为 Token 死的时候它必须能跟着死（实现级联清空）
            │
            ▼
Step 4: 这两条性质合在一起 → Response Wrapping 的安全性保证
        - 机密性：root 都看不见 → Step 2 的字面应用
        - 一次性：revoke 即销毁 → Step 3 的字面应用
```

## 最容易踩的两个坑

1. **把它当 KV 用**：`cubbyhole` 没版本、没跨 Token 共享、Token 灭即
   灭——拿来存"业务持续要用的密码"几乎一定会出现"那个写入的 Token
   过期了，所有人都读不到了"的事故。要存全局共享的机密，请用
   [3.2 KV v2](/ch3-kv-v2)。
2. **直接读 `cubbyhole/response` 当 unwrap 用**：Step 4 那条命令是
   为了揭示原理，**生产里请用 `vault unwrap` / `sys/wrapping/unwrap`**
   ——Vault 1.19+ 会在直读时点亮 deprecation 警告就是这个意思。

## 与下一节的衔接

Cubbyhole 是 [3.1 章](/ch3-secrets-engines)那个"挂载 = 插件"通用心
智模型的**唯一例外**——记住这一个例外比记住通用规则更重要，因为它
影响着 Vault 一系列基础机制（Response Wrapping、Token 派生等）的安
全保证。

后续小节会继续在"机密引擎光谱"里挑选有代表性的引擎深入。每遇到一个
新引擎都可以用这两个问题对照本节内容来理解它：

- 它的**可见性单位**是什么？（Cubbyhole 是 Token；KV 是 Path + Policy；
  Database 是 Role + Lease；……）
- 它的**生命周期**绑定到什么？（Cubbyhole 绑 Token；KV 永久；动态机
  密绑 Lease；……）

把这两个维度看清楚，"机密引擎"这个抽象词就不会再是黑箱。
