# 实验说明

本实验配套 [8.2 节正文](https://lonegunmanb.github.io/vault-tutorial/ch8-audit-devices.html)：学员此时已经在概念层理解了「公共配置选项 vs 类型专属选项」「file 不做日志轮转、需 SIGHUP 配合」「syslog 单条记录可能超 UDP 包大小」「socket 三种类型可靠性差异」这套机制，本实验把其中可观察的部分变成可在终端里直接复现的现象：

1. 启用一台 `file` 审计设备，触发若干次 API 请求，亲手 `tail -f` 看到逐行 JSON、确认敏感字段以 `hmac-sha256:...` 形式落盘；
2. 在同一台 Vault 上**并行**启用 `syslog`（写本机 rsyslog）与 `socket`（写本机 Unix Socket）两台审计设备，触发同一组请求，对照三处目的地各自的产物；
3. 在新挂载的 file 设备上打开 `elide_list_responses`，看 LIST 响应里的 `keys` 字段被压缩成整数计数；最后向 vault 进程发送 `SIGHUP`，复现 file 审计设备「关闭并重新打开底层文件描述符」的轮转行为。

为完全规避真实云成本，整个实验都在单台 Killercoda 主机上完成：

- 已安装 `vault`（1.19.2）、`jq`、`curl`、`rsyslog`、`socat`；
- 已预置 `/root/vault.hcl`：单节点 raft 存储位于 `/opt/vault/data`、监听 `0.0.0.0:8200`、`tls_disable = true`；
- 已写入 `VAULT_ADDR=http://127.0.0.1:8200`；
- 已生成便捷脚本 `/root/start-vault.sh`、`/root/stop-vault.sh`；
- 已确保 `rsyslog` 服务运行（用于 syslog 设备演示）。

> 本实验全程使用明文 HTTP，目的是让 `curl` 与 `tail` 输出干净易读、便于直接观察响应；生产环境请按 6.2 节的基线启用 TLS。同样，本实验中开启 `log_raw=true` 的演示仅为对照「明文 vs HMAC」差异，绝不应在生产环境保留这一开关。
