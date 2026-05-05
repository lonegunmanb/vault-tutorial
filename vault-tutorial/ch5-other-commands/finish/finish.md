# 恭喜完成实验！

你已经完成了 `lease`、`unwrap`、`ssh` 与 `path-help` 四组重要命令的核心练习。

## 本实验的核心收获

| 阶段 | 你亲手验证的事实 |
| :--- | :--- |
| `path-help` | Vault 可以从当前路由表返回后端路径和参数帮助 |
| `lease lookup` | 动态机密的 lease 可以通过完整 lease ID 查询 |
| `lease renew` | 续期延长的是凭据有效时间，不改变凭据内容 |
| `lease revoke` | 撤销 lease 会使底层动态机密失效 |
| `lease revoke -prefix -sync` | 可以按路径前缀同步批量回收租约 |
| `unwrap` | response wrapping token 可以取出封装响应 |
| `vault ssh -no-exec` | SSH 命令可以只生成凭据而不真正建立连接 |

## 关键心智模型

```text
path-help  先问路径支持什么
lease      管理动态机密能活多久
unwrap     取出一次性封装响应
ssh        让 SSH 登录凭据由 Vault 签发
```

后续学习 Database、SSH、Cubbyhole、Response Wrapping 和生产故障排查时，可以反复使用这四组命令：先用 `path-help` 确认路径，再用 `lease` 管理动态凭据生命周期，用 `unwrap` 安全交接一次性响应，用 `vault ssh` 把 SSH 机密引擎的能力落实到登录流程中。