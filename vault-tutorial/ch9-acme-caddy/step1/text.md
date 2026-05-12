# 第 1 步：先把 Caddy 以纯 HTTP 跑一遍——建立对照基线

本步先不碰 Vault PKI，也不碰 ACME，先把 Caddy 以最朴素的 HTTP 配置跑起来，让学员形成『没有 ACME 时 Caddy 长什么样』的对照基线。后两步打开 ACME 之后，对照才会显得清晰。

---

## 1.1 检查后台已经准备好的环境

先确认 Vault 已经在后台跑起来：

```bash
vault status | head -7
```

预期至少看到 `Initialized = true`、`Sealed = false`、`Version = 1.19.2`。

确认 `caddy.local` 这个虚拟域名已经被解析到本机：

```bash
getent hosts caddy.local
```

预期输出：

```
127.0.0.1       caddy.local
```

确认 Caddy 镜像已经在本地：

```bash
docker images caddy:2.8 --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}'
```

预期会列出一行 `caddy 2.8 ...`。如果列表为空，说明后台预拉取失败，请运行 `docker pull caddy:2.8` 手动拉一次。

## 1.2 准备一份只服务 HTTP 的 Caddyfile

为本步专门准备一份『纯 HTTP、不启用自动 HTTPS』的最小配置：

```bash
mkdir -p /root/caddy_config /root/caddy_data
echo "hello world" > /root/index.html

cat > /root/caddy_config/Caddyfile <<'EOF'
{
    auto_https off
}

http://caddy.local {
    root * /usr/share/caddy
    file_server
}
EOF
cat /root/caddy_config/Caddyfile
```

这份配置告诉 Caddy：

- 顶层 `auto_https off` —— **彻底关掉自动 HTTPS**，不要去找任何 ACME 服务器；
- 站点名前面显式写 `http://` —— Caddy 看到这里就知道只在 :80 上服务这个站点，不去申请证书。

## 1.3 启动 Caddy（host 网络模式）

```bash
docker rm -f caddy-server 2>/dev/null
docker run -d \
  --name caddy-server \
  --network host \
  --volume /root/caddy_config/Caddyfile:/etc/caddy/Caddyfile \
  --volume /root/index.html:/usr/share/caddy/index.html \
  --volume /root/caddy_data:/data \
  --rm \
  caddy:2.8
sleep 2
docker ps -f name=caddy-server --format 'table {{.Names}}\t{{.Status}}'
```

预期最后一行类似 `caddy-server   Up 2 seconds`。

> **为什么用 `--network host`？** 这样 Caddy 容器与 Vault（host 进程）共享同一个网络栈与同一份 `/etc/hosts`：Caddy 容器里执行 `curl http://127.0.0.1:8200` 就是在访问 Vault；下一步 Vault 反过来对 `http://caddy.local` 发起 ACME HTTP-01 回访也能直接命中本机 :80。这避开了官方教程中需要新建 docker bridge + 固定 IP + `--add-host` 的繁琐配置，让学员把注意力集中在 ACME 流程本身。

## 1.4 用 curl 验证 HTTP 通、HTTPS 断

先访问 HTTP：

```bash
curl http://caddy.local/
```

预期输出：

```
hello world
```

再尝试 HTTPS：

```bash
curl -sv https://caddy.local/ 2>&1 | grep -Ei 'connect|refused|trying'
```

预期会立即看到类似：

```
*   Trying 127.0.0.1:443...
* connect to 127.0.0.1 port 443 failed: Connection refused
* Failed to connect to caddy.local port 443 after 0 ms: Couldn't connect to server
* Closing connection
```

这是预期内的失败：本步的 Caddy 配置里已经显式 `auto_https off`，所以它根本没在 :443 监听任何东西——更不用说去申请证书了。

## 1.5 停掉本步的 Caddy，进入下一步

```bash
docker stop caddy-server
```

> Caddy 容器是用 `--rm` 启动的，`docker stop` 之后会自动被删掉，不需要再 `docker rm`。`/root/caddy_data` 目录里只有空目录，对下一步没有干扰。

---

## ✅ 验收

- [ ] `vault status` 显示 `Initialized = true`、`Sealed = false`
- [ ] `getent hosts caddy.local` 返回 `127.0.0.1   caddy.local`
- [ ] `curl http://caddy.local/` 输出 `hello world`
- [ ] `curl https://caddy.local/` 失败，错误是 `Connection refused`（不是其它 TLS 错误）
- [ ] `docker stop caddy-server` 之后 `docker ps -f name=caddy-server` 列表为空

下一步将在 Vault 上搭好两级 PKI 并打开 ACME 开关。这是整个实验中唯一一段需要执行多条 `vault` 写命令的部分，所有命令都已经预置在脚本 `/root/pki/enable_engines.sh` 里，正文会逐句解释。
