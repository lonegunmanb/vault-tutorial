# ACL Policy 与 Password Policy 编写实战

阅读 [2.6 章节文档](../ch2-policies) 之后，本实验把 Policies 文档里
五个关键设计点亲手验证一遍：

- 用 `-output-policy` 反推任何命令需要的最小 capabilities
- 同一 path 多条规则匹配时按"最具体优先"，`deny` 一票否决
- `allowed_parameters` / `denied_parameters` 卡参数级别
- Templated policy 用 `{{identity.entity.id}}` 让一份 policy 服务全员
- Password Policy 与 ACL Policy 完全无关，是密码生成规则

后台脚本会启动 Vault dev 模式（root token = `root`），并安装 `jq`
方便后续 JSON 解析。
