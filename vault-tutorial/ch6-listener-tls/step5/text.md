# 第五步：追加 Unix listener 并体验文件权限隔离

教程 6.2 节第 17 节介绍了 Vault 支持的另一种 listener 类型——Unix domain socket。它的最大优势是天然附带文件系统权限控制：用 `socket_mode` / `socket_user` / `socket_group` 三个字段就能让本机非 Vault 用户进程"根本无法连上 Vault 的 API"。

## 5.1 在配置文件中追加一个 Unix listener

让 TCP listener 与 Unix listener 共存——TCP 暴露给远程客户端（仍然 TLS 1.3），Unix socket 仅供本机自动化使用：

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

> 把 `tls_min_version` 改回 `"tls13"` 是为了让 TCP listener 回到第 3 步收紧后的状态；本步骤只新增 Unix listener，不放松 TCP。

## 5.2 重启 Vault

新增 / 删除 listener 块属于结构性变更，必须重启：

```bash
kill "$(cat /tmp/vault.pid)" 2>/dev/null || true
sleep 1
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
sleep 2
vault operator unseal "$UNSEAL_KEY"
vault status
```

确认 Unix socket 文件已经按指定权限创建：

```bash
ls -l /run/vault.sock
stat -c '%A  owner=%U  group=%G  mode=%a' /run/vault.sock
```

应当看到模式 `600`、属主与属组都是 `root`。

## 5.3 用 curl 通过 Unix socket 直连 Vault API

`curl --unix-socket` 让 HTTP 请求走 Unix socket 而不是网络栈。注意：因为 Unix listener 不参与 TLS 协商，URL scheme 写 `http://` 即可（host 部分被忽略）：

```bash
curl -s --unix-socket /run/vault.sock \
  http://localhost/v1/sys/health | jq .
```

也可以让 `vault` CLI 直接走 Unix socket。Vault CLI 的官方约定是：把 `VAULT_ADDR` 设为 `unix:///path/to/socket` 即可：

```bash
VAULT_ADDR='unix:///run/vault.sock' \
  vault status
```

> 上面的命令故意没有带 `VAULT_CACERT`，因为 Unix socket 上不存在 TLS 协商。

## 5.4 验证文件系统权限确实生效

新建一个非 root 用户，让它尝试通过 Unix socket 访问 Vault：

```bash
useradd -m -s /bin/bash tester 2>/dev/null || true

# tester 没有读取 /run/vault.sock 的权限（mode=600, owner=root），
# 因此 curl 会直接因为 connect() 失败而退出。
sudo -u tester -i bash -c '
  set +e
  curl -s -o /dev/null -w "HTTP %{http_code}\n" \
    --unix-socket /run/vault.sock http://localhost/v1/sys/health
  echo "上一行 HTTP 000 即代表本地 connect() 被拒绝（mode=600 + owner=root 起效）"
'
```

把 `socket_mode` 改成 `666` 看看放开后会怎样：

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

现在 `tester` 也能调用 Vault 了。这正是 Unix listener 的"权限即访问控制"特性：**socket 文件的 owner / group / mode 直接决定了哪些本机进程可以连上 Vault API**。

把权限收回 `600` 完成本节实验：

```bash
sed -i 's|socket_mode  = "666"|socket_mode  = "600"|' /root/vault.hcl
kill "$(cat /tmp/vault.pid)" 2>/dev/null || true
sleep 1
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
sleep 2
vault operator unseal "$UNSEAL_KEY"
vault status
```

到这里你已经把 6.2 节的所有关键配置项亲手实践了一遍：从默认 HTTP 启动，一步步升级到 TLS 1.3 唯一可用，理解了 SIGHUP 在 TLS 上的精确边界，最后让 TCP 与 Unix listener 共存，并用 socket 文件权限完成本机进程级的访问隔离。
