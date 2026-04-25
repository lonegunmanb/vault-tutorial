# 响应封装（Response Wrapping）防篡改一次性数据传递

阅读 [2.7 章节文档](../ch2-response-wrapping) 之后，本实验把 Response
Wrapping 文档里五个核心操作亲手验证一遍：

- 用 `-wrap-ttl` 包装任意 API 响应，验证 unwrap 只能拆一次
- 拆封前用 lookup 检查 wrapping token 的 `creation_path`
- 极短 TTL 过期后自动销毁，及 rewrap 续命
- policy 的 `min_wrapping_ttl` / `max_wrapping_ttl` 强制 wrapping
- 完整场景：AppRole SecretID 通过 response wrapping 安全交付

后台脚本会启动 Vault dev 模式（root token = `root`）并安装 `jq`。
