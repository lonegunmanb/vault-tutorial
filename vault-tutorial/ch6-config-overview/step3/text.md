# 第三步：用 SIGHUP 热加载日志级别

第 6.1 节强调：在 Vault 进程上发送 `SIGHUP` 信号后，如果配置文件中给出的 `log_level` 合法，Vault 会**就地更新**日志级别，并且会同时覆盖命令行参数与环境变量给出的值。本步骤亲手验证这一点。

先看当前日志中最后几行（应是 `info` 级别）：

```bash
tail -n 20 /var/log/vault.log
```

把配置中的 `log_level` 改成 `debug`：

```bash
sed -i 's/^log_level.*/log_level     = "debug"/' /root/vault.hcl
grep '^log_level' /root/vault.hcl
```

发送 SIGHUP（注意：**不是** SIGTERM；进程不会重启）：

```bash
kill -HUP "$(cat /tmp/vault.pid)"
sleep 1
```

确认进程仍是同一个 PID：

```bash
ps -p "$(cat /tmp/vault.pid)" -o pid,etime,cmd
```

触发一次 API 请求，让 Vault 写入更详细的日志：

```bash
vault read sys/health || true
vault token lookup
```

观察日志，应能看到包含 `[DEBUG]` 标签的行；如果没有，可以再多调用几次 API：

```bash
tail -n 30 /var/log/vault.log
grep -c '\[DEBUG\]' /var/log/vault.log
```

把日志级别改回 `info` 并再次 SIGHUP，让后续步骤的日志保持简洁：

```bash
sed -i 's/^log_level.*/log_level     = "info"/' /root/vault.hcl
kill -HUP "$(cat /tmp/vault.pid)"
```

到这里你已经验证：**SIGHUP 不重启进程，但能让 Vault 重新读取部分配置项（如 `log_level` 与 listener 的 TLS）。**
