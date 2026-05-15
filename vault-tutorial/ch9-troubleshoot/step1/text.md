# 第一步：服务器启动失败 — 从 journalctl 反推 `cluster_addr` 缺失

## 1.1 用"坏"配置直接启动 Vault

`/root/vault-broken.hcl` 这份配置**故意只设置了 `api_addr`、漏掉了 `cluster_addr`**，但存储后端选用的是 `raft`。这是一个生产环境最常见的低级错误：管理员从教程拷贝配置时只看到 `api_addr` 一行就直接照抄。先用它直接启动：

```bash
./start-vault.sh /root/vault-broken.hcl
sleep 2
```

## 1.2 观察服务器进程已挂

`start-vault.sh` 用 nohup 把 Vault 拉起后立刻返回，但 Vault 进程实际上**会在初始化阶段直接退出**。检查进程是否还活着：

```bash
pgrep -af "vault server" || echo "vault 进程不在运行 — 启动失败"
```

预期输出：`vault 进程不在运行 — 启动失败`。这就是 9.5 节正文情景一所讲"`systemctl` 报一句没有细节的失败提示，根因藏在日志里"在 `nohup` 模式下的等价场景——`systemctl` 在我们这台 Killercoda 主机上没有为 Vault 注册 unit 文件，因此用 `/var/log/vault.log` 模拟 journal 日志的角色。

## 1.3 取证：从日志里读出根因

按 9.5 节"先取证"原则，去看 Vault 自己的运行日志：

```bash
cat /var/log/vault.log
```

预期日志末尾会出现这样一行（节选）：

```text
Cluster address must be set when using raft storage
```

这行错误就是教程中给出的、**与官方 troubleshoot tutorial 完全一致**的根因信息——存储后端选 `raft` 时，`cluster_addr` 是必填项。

> 如果在生产环境用 systemd 管理 Vault，等价的取证命令是 `sudo journalctl -u vault.service`；本实验为简化环境直接用 nohup + 文件日志。

## 1.4 修复并重启

`/root/vault-fixed.hcl` 已经在原配置基础上补上了 `cluster_addr = "http://127.0.0.1:8201"`。可以先快速对照一下修补后的关键片段（与"坏"配置的唯一差异就是多了 `cluster_addr` 这一行）：

```hcl
ui            = false
disable_mlock = true
cluster_name  = "vault-troubleshoot-classroom"
log_level     = "info"
pid_file      = "/tmp/vault.pid"

api_addr      = "http://127.0.0.1:8200"
cluster_addr  = "http://127.0.0.1:8201"   # ← 新增的这一行修复了根因

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "node-1"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}
```

如果想亲自确认一下 broken 与 fixed 两份配置的差异，可以执行：

```bash
diff /root/vault-broken.hcl /root/vault-fixed.hcl
```

预期只会看到 `cluster_addr = "http://127.0.0.1:8201"` 这一行被新增。

接下来先停掉当前的失败进程（虽然它已经死了，但要清理 raft 数据目录避免脏状态），再用"好"配置重启：

```bash
./stop-vault.sh
./start-vault.sh /root/vault-fixed.hcl
sleep 3
```

## 1.5 验证修复后服务正常

```bash
vault status
```

预期输出会显示 `Initialized false` `Sealed true`（因为还没初始化），但**至少能正常返回 seal-status 而不是连接失败或进程缺失**——这就证明配置已修复、服务已正常监听。

```bash
pgrep -af "vault server"
```

预期能看到 vault server 的活跃进程行，PID 可见。

## 1.6 这一步的核心闭环

学员已经完整经历了一次"`systemctl`/启动脚本只给概要、必须主动到日志里取证、根据日志定位的关键字反推根因、修配置后重启验证"的标准排障流程。这是 9.5 节正文第 7 节情景一的逐步复现。
