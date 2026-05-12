# 第 3 步：让 Caddy 全自动从 Vault 拿到证书并对外提供 HTTPS

本步是整个实验的高潮：第 1 步看到 Caddy 在不申请证书时的样子、第 2 步把 ACME 服务器在 Vault 一侧准备好；现在只需要给 Caddy 一份『指向 Vault ACME directory』的新配置，**什么手工证书操作都不做**，等几秒，HTTPS 应当自动通起来。

## 3.1 写一份指向 Vault ACME directory 的 Caddyfile

第 1 步那份 `auto_https off` 的配置在这里彻底废弃，换成下面这份：

```bash
rm -rf /root/caddy_data/caddy   # 清掉第 1 步残留的 Caddy 状态目录
cat > /root/caddy_config/Caddyfile <<'EOF'
{
    acme_ca http://127.0.0.1:8200/v1/pki_int/acme/directory
}

caddy.local {
    root * /usr/share/caddy
    file_server
}
EOF
cat /root/caddy_config/Caddyfile
```

与第 1 步的差别只有两处：

1. **顶层全局块**多了一行 `acme_ca http://127.0.0.1:8200/v1/pki_int/acme/directory` —— 把 Caddy 默认的 ACME 服务器从 Let's Encrypt 改为我们刚搭好的 Vault `pki_int` ACME 端点；
2. **站点名**前面**没有** `http://` —— 这就是 Caddy『默认即自动 HTTPS』的入口：看到一个裸域名，Caddy 就会自动对它启用 HTTPS、自动找 ACME 服务器申请证书。

## 3.2 启动 Caddy，等它把第一张证书拿下来

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
```

证书签发是异步的：Caddy 启动后会先在 `:80` 准备好挑战路径、向 Vault 下单、应答挑战、拿到证书、再监听 `:443`。整个过程通常在 5 秒内完成。耐心等一下并观察日志：

```bash
sleep 5
docker logs caddy-server 2>&1 | grep -E 'certificate obtained|serving initial configuration|tls' | head -10
```

预期能看到一行类似：

```
{"level":"info","ts":...,"logger":"tls.obtain","msg":"certificate obtained successfully","identifier":"caddy.local"}
```

如果一时还没看到，等几秒再 `docker logs caddy-server | tail -30` 一次。

## 3.3 用 curl 验证 HTTPS 已经自动通了

curl 校验证书时需要从『服务端证书 → 中间 CA → 根 CA』完整地验签到一个它信任的根。Vault 通过 ACME 颁发的证书链里通常已经带了中间 CA，但为了让 curl 在任何情况下都能验通，**显式把『根 + 中间』两张 CA 拼成一个 bundle** 给它最稳妥：

```bash
cat /root/pki/intermediate.cert.pem /root/pki/root_2024_ca.crt \
  > /root/pki/ca_bundle.pem
curl --cacert /root/pki/ca_bundle.pem https://caddy.local/
```

预期输出：

```
hello world
```

回想第 1 步那次 `Connection refused`——这是同一台机器、同一个 Caddy 镜像、同一个域名 `caddy.local`，**唯一的差异**是 Caddyfile 多了一行 `acme_ca` 与少了一句 `auto_https off`。整条『生成 CSR / 与 ACME 服务器对话 / 监听 :443』的链路完全自动化。

> **`--cacert` 这个选项做了什么？** curl 默认会校验服务器证书是否由系统信任的根 CA 签发；本实验里证书的颁发者是『一个我们自己刚刚在 Vault 里建的中间 CA』，curl 默认当然不信。`--cacert /root/pki/ca_bundle.pem` 显式告诉 curl：『把这两张自建 CA 也临时加入信任』。生产环境里，应当把根 CA 一次性下发到所有公司设备的系统信任链里（例如 Linux 的 `/etc/pki/ca-trust/source/anchors/`、Windows 的『受信任的根证书颁发机构』），之后所有服务的证书无需再带 `--cacert`。

## 3.4 用 openssl 看清这张证书到底是谁签的

```bash
echo | openssl s_client -connect caddy.local:443 -servername caddy.local 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates -ext subjectAltName
```

预期输出形如：

```
issuer=CN = learn.internal Intermediate Authority
subject=CN = caddy.local
notBefore=... GMT
notAfter=... GMT  (约 30 天后)
X509v3 Subject Alternative Name:
    DNS:caddy.local
```

三个关键观察：

1. **issuer = `learn.internal Intermediate Authority`** —— 这正是第 2.1 节那张中间 CA 的 `common_name`；证明这张证书是 Vault 的 `pki_int/` 签出来的，不是 Caddy 自签的、也不是 Let's Encrypt 签的；
2. **notBefore → notAfter** 之间约 **30 天** —— 与第 2.1 节中 `pki_int/roles/learn` 配置的 `max_ttl=720h` 相符；ACME 客户端会在剩余寿命走过约 2/3 时静默续期；
3. **SAN 含有 `DNS:caddy.local`** —— Caddy 自动把站点名作为证书的主体备用名（SAN）申请下来。

## 3.5 看一眼 Caddy 把证书藏在哪里

ACME 客户端会自己管理私钥与证书的存储，运维全程**从未亲手碰过任何 PEM 文件**。Caddy 把它们放在挂载到容器 `/data` 的目录里：

```bash
find /root/caddy_data/caddy/certificates -type f | sort
```

预期会列出 4 个文件，类似：

```
/root/caddy_data/caddy/certificates/.../caddy.local/caddy.local.crt
/root/caddy_data/caddy/certificates/.../caddy.local/caddy.local.key
/root/caddy_data/caddy/certificates/.../caddy.local/caddy.local.json
... (Caddy 内部账号信息)
```

`caddy.local.crt` 是这张证书本身，`caddy.local.key` 是 Caddy 自己生成的私钥（**它从未离开过这台机器**）。再过约 20 天 ACME 客户端会自动续期、覆盖这两个文件——而**整个流程不需要任何人插手**。

## 3.6 复盘：刚才到底发生了什么

回顾本步实际做的事（按时间顺序）：

1. 改了一份 Caddyfile（去掉 `auto_https off`、加一行 `acme_ca`）；
2. `docker run` 重启 Caddy；
3. `curl` 验证 HTTPS。

**没有做** 的事：

- 没有用 `openssl genrsa` 生成私钥；
- 没有用 `openssl req` 生成 CSR；
- 没有用 `vault write pki_int/sign/learn ...` 签证书；
- 没有把 PEM 通过 `scp`、IM 截图、或工单系统传来传去；
- 没有写任何『证书快过期了请运维续期』的告警与日历提醒。

这就是 ACME 协议在内部 PKI 上带来的全部价值——把 9.3 节正文里那段『**人肉**』流程整体交给两个进程按标准对话来跑。

---

## ✅ 验收

- [ ] `docker logs caddy-server` 中能看到 `certificate obtained successfully` 字样且 `identifier` 是 `caddy.local`
- [ ] `curl --cacert /root/pki/ca_bundle.pem https://caddy.local/` 输出 `hello world`
- [ ] `openssl s_client -connect caddy.local:443 -servername caddy.local` 拿到的证书 issuer = `learn.internal Intermediate Authority`、SAN 含 `DNS:caddy.local`、有效期约 30 天
- [ ] `/root/caddy_data/caddy/certificates/...` 下能看到 `caddy.local.crt` 与 `caddy.local.key`

至此完成本实验全部三步：从『纯 HTTP 反例』到『PKI + ACME 一次性配齐』再到『Caddy 全自动从 Vault 拿到证书』，9.3 节正文中所有关键论断都已在终端里得到亲手验证。
