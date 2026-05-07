# 第五步：追加 Unix listener 并体验文件权限隔离

教程 6.2 节第 17 节介绍了 Vault 支持的另一种 listener 类型——Unix domain socket。其最大优势在于天然附带文件系统层面的访问控制：通过 `socket_mode` / `socket_user` / `socket_group` 三个字段，即可让本机非 Vault 用户进程"根本无法连上 Vault 的 API"。

## 5.1 在配置文件中追加一个 Unix listener

让 TCP listener 与 Unix listener 共存——TCP 暴露给远程客户端（仍仅允许 TLS 1.3），Unix socket 仅供本机自动化使用：

```bash
sed -i 's|tls_min_version = "tls12"|tls_min_version = "tls13"|' /root/vault.hcl

cat >> /root/vault.hcl <<'EOF'

listener "unix" {
  address      = "/run/vault.sock"
  socket_mode  = "600"
  socket_user  = "root"
  socket_group = "root"
}
EOF

cat /root/vault.hcl
```

> 将 `tls_min_version` 改回 `"tls13"` 旨在让 TCP listener 回到第 3 步收紧后的状态；本步骤仅新增 Unix listener，不会放松 TCP 的 TLS 强度。

## 5.2 重启 Vault

新增 / 删除 listener 块属于结构性变更，必须重启进程：

```bash
kill "$(cat /tmp/vault.pid)" 2>/dev/null || true
sleep 1
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
sleep 2
vault operator unseal "$UNSEAL_KEY"
vault status
```

确认 Unix socket 文件已按指定权限创建：

```bash
ls -l /run/vault.sock
stat -c '%A  owner=%U  group=%G  mode=%a' /run/vault.sock
```

应可观察到模式 `600`、属主与属组均为 `root`。

## 5.3 通过 curl 经由 Unix socket 直连 Vault API

`curl --unix-socket` 可让 HTTP 请求经由 Unix socket 而非网络栈传递。需注意：由于 Unix listener 不参与 TLS 协商，URL scheme 使用 `http://` 即可（host 部分会被忽略）：

```bash
curl -s --unix-socket /run/vault.sock \
  http://localhost/v1/sys/health | jq .
```

亦可让 `vault` CLI 直接经由 Unix socket 通信。Vault CLI 的官方约定是：将 `VAULT_ADDR` 设为 `unix:///path/to/socket` 即可：

```bash
VAULT_ADDR='unix:///run/vault.sock' \
  vault status
```

> 上述命令刻意未携带 `VAULT_CACERT`，因为 Unix socket 上不存在 TLS 协商。

## 5.4 验证文件系统权限确实生效

新建一个非 root 用户，由其尝试通过 Unix socket 访问 Vault：

```bash
useradd -m -s /bin/bash tester 2>/dev/null || true

# tester 用户对 /run/vault.sock 不具备读取权限（mode=600, owner=root），
# 因此 curl 将因 connect() 失败而直接退出。
sudo -u tester -i bash -c '
  set +e
  curl -s -o /dev/null -w "HTTP %{http_code}\n" \
    --unix-socket /run/vault.sock http://localhost/v1/sys/health
  echo "上一条命令输出 HTTP 000 即代表本地 connect() 被拒绝（mode=600 + owner=root 已生效）"
'
```

将 `socket_mode` 修改为 `666`，观察放开权限后的行为差异：

```bash
sed -i 's|socket_mode  = "600"|socket_mode  = "666"|' /root/vault.hcl
kill "$(cat /tmp/vault.pid)" 2>/dev/null || true
sleep 1
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
sleep 2
vault operator unseal "$UNSEAL_KEY"
ls -l /run/vault.sock

sudo -u tester -i bash -c '
  curl -s --unix-socket /run/vault.sock \
    http://localhost/v1/sys/health | jq .
'
```

此时 `tester` 用户已可调用 Vault。这恰好体现了 Unix listener 的"权限即访问控制"特性：**socket 文件的 owner / group / mode 直接决定了哪些本机进程能够连上 Vault API**。

将权限恢复为 `600`，以完成本节实验：

```bash
sed -i 's|socket_mode  = "666"|socket_mode  = "600"|' /root/vault.hcl
kill "$(cat /tmp/vault.pid)" 2>/dev/null || true
sleep 1
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
sleep 2
vault operator unseal "$UNSEAL_KEY"
vault status
```

至此，你已通过实际操作完整实践了 6.2 节涉及的全部关键配置项：从默认 HTTP 启动，逐步升级至 TLS 1.3 唯一可用，理解了 SIGHUP 在 TLS 上的精确边界，最终让 TCP 与 Unix listener 共存，并通过 socket 文件权限实现了本机进程级的访问隔离。
