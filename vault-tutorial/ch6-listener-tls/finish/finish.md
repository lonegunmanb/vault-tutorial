# 实验完成

恭喜你完成本节实验。你已经：

- 从一份显式 `tls_disable = true` 的基线 listener 出发，启动了一个**裸 HTTP** 的 Vault；
- 用 OpenSSL 生成了自签 ECDSA 证书，把 listener 升级为带 `tls_cert_file` / `tls_key_file` 的 HTTPS，并通过 `curl --cacert` 与 `curl`（不带 cacert，预期失败）两路验证；
- 把 `tls_min_version` 设为 `"tls13"`，重启 Vault，用 `sslscan` 客观确认 listener 只剩 TLS 1.3，并用 `curl --tls-max 1.2` 反证 TLS 1.2 已被拒绝；
- 亲手验证了 SIGHUP 在 TLS 上的精确边界：协议版本变更必须重启进程才生效，而证书文件内容则可被 SIGHUP 热重载（用 `openssl s_client` 看 `notAfter` 变化作为铁证）；
- 追加了一个 `listener "unix" {...}` 子块，先用 `socket_mode = "600"` 验证非 root 用户被 connect 拒绝，再用 `socket_mode = "666"` 演示放开权限后的差异，体会"socket 文件 mode 即访问控制"的本质。

下一节将继续在配置文件深化方向前进，讲解自动化云端解封（Auto-Seal）。
