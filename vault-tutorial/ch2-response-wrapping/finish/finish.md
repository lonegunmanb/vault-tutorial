# 恭喜完成实验！🎉

你已经亲手验证了 Vault Response Wrapping 文档里五个最核心的机制：

| 主题 | 一句话总结 |
| --- | --- |
| 基础包装与一次性拆封 | 任何 API 加 `-wrap-ttl` 就能包装响应；unwrap 只能拆一次，第二次必报错 |
| lookup 与 creation_path 验证 | 拆封前先 lookup 检查来源路径——中间人用 `sys/wrapping/wrap` 重新包装会暴露 `creation_path` 不匹配 |
| TTL 过期与 rewrap | 过期 = token + cubbyhole 一起销毁，root 也恢复不了；rewrap 可以不拆封换新 token |
| Policy 强制 wrapping | `min_wrapping_ttl` > 0 等于强制必须 wrap；TTL 不在 [min, max] 区间 → 403 |
| AppRole SecretID 安全交付 | 调度方只看到 wrapping token，runner 拆封登录，SecretID 明文从不出现在传输链上 |

## 下一步

- **2.8 集群 HA**：wrapping token 存储在 Raft 复制的状态机上，HA 切换
  后 unwrap 仍然可用
- **第 6 章 身份治理**：AppRole 的 RoleID + wrapped SecretID 交付管线
  是"第零号机密"缓解的标准方案，WIF 章节会讲如何彻底消灭它
- **第 7 章 应用自动化接入**：Vault Agent 的 Auto-auth 模块原生支持
  wrapped SecretID 输入；VSO 更是完全不需要 SecretID
- **第 9 章 生产加固**：审计日志会记录 wrap / unwrap 事件，但 HMAC
  加密后 wrapping token 本身不会泄露
