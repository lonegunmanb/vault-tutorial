# 租约（Lease）边界条件实战

阅读 [2.3 章节文档](../ch2-lease) 之后，本实验将带你亲手验证里面四个最反
直觉的设计：

- `lease_id` 是按路径前缀组织的，并且 `sys/leases` 是一棵树
- `max_lease_ttl` 是任何续约都越不过去的天花板
- `renew -increment=N` 不是"在当前 TTL 后再加 N"，而是"从现在算 N"——
  应用可以主动缩短租约
- `vault token revoke` 会级联吊销该 Token 签出的**所有**动态机密
- `vault lease revoke -prefix` 是事故响应时的"核按钮"

后台脚本已经为你启动了 Vault + Postgres，并完成了 database 引擎的全部
配置（参见 vault-basics step4），你进入实验时直接进入"取凭据 / 玩租约"
环节。
