# 实验完成

恭喜完成 8.2 节的动手实验。回顾本实验复现的几条核心规律：

1. **三类设备共用启用语法**——`vault audit enable [-path=...] <type> key=value...`，公共选项与类型专属选项以同样的 `key=value` 形式追加。
2. **同一份审计记录会被扇出到所有启用中的设备**——通过 `request.id` 在 file / syslog / socket 三处完全一致的现象亲眼证实。
3. **file 设备本身不做轮转**——必须由外部工具（logrotate）配合，重命名旧日志后再向 vault 进程发送 `SIGHUP` 才能让 file 设备平滑切换到新文件。
4. **`elide_list_responses=true` 把 LIST 响应里的 `keys` 字段替换为整数计数**——以可控代价显著降低单条记录的体积，避免下游审计设备被「噎住」。
5. **「至少一台设备成功写入」是 Vault 业务可用性的硬性条件**——只要还有任意一台启用中的审计设备能继续写日志，Vault 就照常处理 API 请求；本实验中通过故意杀掉 socat 但保留 file 与 syslog 即得到了正向验证。

下一步建议：

- 在生产环境绝不开启 `log_raw=true`，且对 `prefix` 这类看似无害的字段也要明确审计动机；
- 优先把 `socket` 设备落到本机 Unix Socket，避免 UDP 静默丢包与 TCP 长时间不可达对 Vault 业务的反向拖累；
- 如选用 `syslog` 设备，务必确认本机 syslog 守护进程使用 TCP 监听器，或者并行挂一台 `file` 设备做兜底，以应对单条审计记录超 UDP 包大小的极端情况。
