# 恭喜完成实验！

你已经完成了 `vault policy ...` 与 `vault secrets ...` 两组命令的核心练习。

## 本实验的核心收获

| 阶段 | 你亲手验证的事实 |
| :--- | :--- |
| `secrets list/enable` | 机密引擎挂载在路径上，策略应当围绕实际路径设计 |
| `secrets tune` | 挂载点有独立配置，可以调整描述、默认 TTL 和最大 TTL |
| `secrets move` | 挂载点可以迁移到新路径，后续访问应当使用新路径 |
| `secrets disable` | 禁用挂载点会结束该机密引擎的生命周期 |
| `policy fmt/write/read/list` | 本地策略文件需要上传为服务器端命名策略后才会生效 |
| `policy delete` | 删除命名策略会影响关联该策略的 token |

## 关键心智模型

```text
vault secrets ...  管理“路径背后的机密引擎”
vault policy ...   管理“身份可以对路径做什么”
```

后续学习 Database、PKI、Transit、AWS 等机密引擎时，可以反复使用这条路径：先规划挂载路径，再启用和配置机密引擎，最后为真实身份编写最小权限策略，并用受限 token 验证访问结果。
