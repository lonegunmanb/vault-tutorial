# 实验说明

本实验配套 [6.9 节正文](https://lonegunmanb.github.io/vault-tutorial/ch6-user-lockout.html)：学员此时已经在概念层理解了"user lockout 默认启用、threshold/duration/counter_reset 三个参数构成状态机、配置块按 `all` / `userpass` / `ldap` / `approle` 划分作用域、`VAULT_DISABLE_USER_LOCKOUT` 处于禁用优先级链最顶端、`/sys/locked-users` 提供查询与幂等解锁"这套机制，本实验把其中可观察的部分变成可在终端里直接复现的现象：

1. 启动一个开启了 userpass 的单节点 Vault，连续输错若干次密码触发锁定，验证此后即便输入正确密码也会被立即拒绝；
2. 通过 `GET /sys/locked-users` 列出锁定用户、通过 `POST /sys/locked-users/:accessor/unlock/:alias` 主动解锁，并对一个**未被锁定**的用户再次调用解锁端点，验证其幂等性；
3. 用 `VAULT_DISABLE_USER_LOCKOUT=true` 重启 Vault 进程，验证连续失败登录不再触发锁定，且任何配置文件中的 `user_lockout` 块都被无视。

为完全规避真实云成本，整个实验都在单台 Killercoda 主机上完成，并把课堂友好的小数值预置进配置文件：

- 已安装 `vault`（1.19.2）与 `jq`、`curl`；
- 已预置 `/root/vault.hcl`，其中：
  - 单节点 raft 存储位于 `/opt/vault/data`；
  - listener 绑定 `0.0.0.0:8200`、`tls_disable = true`；
  - `user_lockout "userpass"` 设为 `lockout_threshold = "3"`、`lockout_duration = "1m"`、`lockout_counter_reset = "1m"`，便于在数十秒内完成完整的锁定与解锁流程；
- 已写入 `VAULT_ADDR=http://127.0.0.1:8200`；
- 已生成便捷脚本 `/root/start-vault.sh`、`/root/stop-vault.sh`。

> 本实验全程使用明文 HTTP，目的是让 `curl` 输出干净易读、便于直接观察响应；生产环境请按 6.2 节的基线启用 TLS。同样，正文已提示 user lockout 在请求处理早期触发、可能向外部观察者泄露用户名是否真实存在；本实验仅用于教学复现，不应在生产环境使用如此短的 lockout_duration。
