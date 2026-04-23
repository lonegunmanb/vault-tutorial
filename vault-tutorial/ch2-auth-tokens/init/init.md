# Token 树、accessor、periodic 与 service vs batch

阅读 [2.4 章节文档](../ch2-auth-tokens) 之后，本实验把 Tokens 文档里
五个最关键的设计点亲手验证一遍：

- 任何 auth method 都只是 Token 工厂，最终鉴权全看 Token 自身
- Token 之间的父子树支撑了 Vault 的"按身份维度一键吊销"能力
- accessor 是一个**单向引用**——能撤销，但拿不到 token 本身
- periodic token 是除 root 之外唯一可以"无限续命"的 token
- batch token 不写磁盘、无 accessor、无子 token、不可 revoke

后台脚本会启动 Vault dev 模式（root token = `root`），并安装 `jq` 方便
后续 JSON 解析。
