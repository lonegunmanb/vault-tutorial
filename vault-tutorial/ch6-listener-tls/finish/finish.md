# 实验完成

恭喜你完成本节实验。在本实验中，你已经：

- 从一份显式 `tls_disable = true` 的基线 listener 出发，启动了一个**明文 HTTP** 的 Vault；
- 使用 OpenSSL 生成了自签 ECDSA 证书，将 listener 升级为附带 `tls_cert_file` / `tls_key_file` 的 HTTPS，并通过 `curl --cacert` 与未携带 cacert 的 `curl`（预期失败）进行了两路交叉验证；
- 将 `tls_min_version` 设为 `"tls13"`，重启 Vault，通过 `sslscan` 客观确认 listener 仅保留 TLS 1.3，并以 `curl --tls-max 1.2` 反向验证 TLS 1.2 已被拒绝；
- 通过实际操作验证了 SIGHUP 在 TLS 上的精确边界：协议版本变更必须重启进程才能生效，而证书文件内容则可被 SIGHUP 热重载（以 `openssl s_client` 观察 `notAfter` 变化作为确凿证据）；
- 追加了一个 `listener "unix" {...}` 子块，先以 `socket_mode = "600"` 验证非 root 用户被 connect 拒绝，再以 `socket_mode = "666"` 演示放开权限后的行为差异，体会"socket 文件 mode 即访问控制"的设计本质。

下一节将继续在配置文件深化方向上前进，讲解自动化云端解封（Auto-Seal）。
