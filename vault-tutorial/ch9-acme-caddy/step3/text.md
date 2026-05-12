# 第 3 步：让 Caddy 全自动从 Vault 拿到证书并对外提供 HTTPS

本步是整个实验的高潮：第 1 步看到 Caddy 在不申请证书时的样子、第 2 步把 ACME 服务器在 Vault 一侧准备好；现在只需要给 Caddy 一份『指向 Vault ACME directory』的新配置，**什么手工证书操作都不做**，等几秒，HTTPS 应当自动通起来。

## 3.1 写一份指向 Vault ACME directory 的 Caddyfile

第 1 步那份 `auto_https off` 的配置在这里彻底废弃，换成下面这份：

```bash
rm -rf /root/caddy_data/caddy   # 清掉第 1 步残留的 Caddy 状态目录
cat > /root/caddy_config/Caddyfile <<'EOF'
caddy.local {
    tls {
        issuer acme {
            dir http://127.0.0.1:8200/v1/pki_int/acme/directory
        }
    }
    root * /usr/share/caddy
    file_server
}
EOF
cat /root/caddy_config/Caddyfile
```

与第 1 步的差别只有两处：

1. **站点名前面没有 `http://`** —— 这是 Caddy『默认即自动 HTTPS』的入口：看到一个裸域名，Caddy 就会自动启用 HTTPS；
2. **新增 `tls { issuer acme { dir ... } }` 块** —— 显式把 ACME 服务器指向我们刚搭好的 Vault `pki_int` ACME 端点。

> **为什么不能只在全局块里写 `acme_ca`？** Caddy 看到 `*.local` 这种『非公网可解析』的站点名时，会**自动跳过任何 ACME 配置**、改用内置的 `internal` 自签 CA（日志里会出现 `"issuer":"local"`）。只有在站点块里**显式声明 `issuer acme`** 才能强制它走 ACME 流程。这是初学者最容易踩的一个坑。

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
sleep 8
docker logs caddy-server 2>&1 | tail -30
```

预期能看到一行类似：

```
{"level":"info","ts":...,"logger":"tls.obtain","msg":"certificate obtained successfully","identifier":"caddy.local","issuer":"acme.../pki_int/acme/directory-..."}
```

关键是 `"issuer"` 字段里出现 `acme` / `pki_int`，**不是** `"local"`——后者代表 Caddy 又退回到了内置自签 CA。

如果一时还没看到，等几秒再 `docker logs caddy-server 2>&1 | tail -30` 一次。

## 3.3 用 curl 验证 HTTPS 已经自动通了

curl 校验证书时需要从『服务端证书 → 中间 CA → 根 CA』完整地验签到一个它信任的根。最稳妥的做法是直接问 Vault 要一份**与当前签发者完全对应**的 CA 链——`pki_int/ca_chain` 返回中间 CA 与根 CA 拼好的 PEM 包：

```bash
curl -s http://127.0.0.1:8200/v1/pki_int/ca_chain > /root/pki/ca_bundle.pem
openssl crl2pkcs7 -nocrl -certfile /root/pki/ca_bundle.pem \
  | openssl pkcs7 -print_certs -noout
curl --cacert /root/pki/ca_bundle.pem https://caddy.local/
```

预期 bundle 里能看到中间 CA（`learn.internal Intermediate Authority`）与根 CA（`learn.internal`）两张证书，类似：

```
subject=CN = learn.internal Intermediate Authority
issuer=CN = learn.internal

subject=CN = learn.internal
issuer=CN = learn.internal
```

最后一行 `curl` 输出：

```
hello world
```

回想第 1 步那次 `Connection refused`——这是同一台机器、同一个 Caddy 镜像、同一个域名 `caddy.local`，**唯一的差异**是 Caddyfile 多了 `tls { issuer acme { dir ... } }` 与少了一句 `auto_https off`。整条『生成 CSR / 与 ACME 服务器对话 / 监听 :443』的链路完全自动化。

> **`--cacert` 这个选项做了什么？** curl 默认会校验服务器证书是否由系统信任的根 CA 签发；本实验里证书的颁发者是『一个我们自己刚刚在 Vault 里建的中间 CA』，curl 默认当然不信。`--cacert /root/pki/ca_bundle.pem` 显式告诉 curl：『把这两张自建 CA 也临时加入信任』。生产环境里，应当把根 CA 一次性下发到所有公司设备的系统信任链里（例如 Linux 的 `/etc/pki/ca-trust/source/anchors/`、Windows 的『受信任的根证书颁发机构』），之后所有服务的证书无需再带 `--cacert`。

> **为什么不直接拼 `intermediate.cert.pem` + `root_2024_ca.crt`？** 那两个文件是 2.1 节脚本运行时落盘的快照；如果脚本被多次运行、或 Vault 后续轮换了中间 CA 的 issuer，落盘文件里的中间 CA 就可能与 ACME 实际签发用的中间 CA 对不上，导致 curl 报 `unable to get local issuer certificate`。直接从 `pki_int/ca_chain` 拉，永远拿到的是『当前正在用』的链，最不容易出错。

## 3.4 用 openssl 看清这张证书到底是谁签的

```bash
echo | openssl s_client -connect caddy.local:443 -servername caddy.local 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates -ext subjectAltName
```

预期输出形如：

```
issuer=CN = learn.internal Intermediate Authority
subject=
notBefore=... GMT
notAfter=... GMT  (约 30 天后)
X509v3 Subject Alternative Name: critical
    DNS:caddy.local
```

三个关键观察：

1. **issuer = `learn.internal Intermediate Authority`** —— 这正是第 2.1 节那张中间 CA 的 `common_name`；证明这张证书是 Vault 的 `pki_int/` 签出来的，不是 Caddy 自签的、也不是 Let's Encrypt 签的；
2. **notBefore → notAfter** 之间约 **30 天** —— 与第 2.1 节中 `pki_int/roles/learn` 配置的 `max_ttl=720h` 相符；ACME 客户端会在剩余寿命走过约 2/3 时静默续期；
3. **`subject=` 为空、SAN 是 `critical` 且含 `DNS:caddy.local`** —— ACME 协议下 Caddy 申请的证书**完全靠 SAN 标识身份**，故意不把域名塞进 CN（这是 RFC 5280 与现代浏览器/Go 的推荐做法）。`critical` 标记意味着任何 TLS 实现都**必须**校验 SAN，不能退回到 CN。

## 3.5 看一眼 Caddy 把证书藏在哪里

ACME 客户端会自己管理私钥与证书的存储，运维全程**从未亲手碰过任何 PEM 文件**。Caddy 把它们放在挂载到容器 `/data` 的目录里：

```bash
find /root/caddy_data/caddy/certificates -type f | sort
```

预期会列出 3 个文件，类似：

```
/root/caddy_data/caddy/certificates/127.0.0.1-8200-v1-pki_int-acme-directory/caddy.local/caddy.local.crt
/root/caddy_data/caddy/certificates/127.0.0.1-8200-v1-pki_int-acme-directory/caddy.local/caddy.local.json
/root/caddy_data/caddy/certificates/127.0.0.1-8200-v1-pki_int-acme-directory/caddy.local/caddy.local.key
```

注意中间那段路径 `127.0.0.1-8200-v1-pki_int-acme-directory` —— Caddy 把 ACME directory URL 转义后作为 issuer 子目录名，**实证了证书确实是从 Vault 这个 ACME 端点拿来的**，不是内置自签 CA（那种情况下子目录会叫 `local`）。

`caddy.local.crt` 是这张证书本身，`caddy.local.key` 是 Caddy 自己生成的私钥（**它从未离开过这台机器**），`caddy.local.json` 是 Caddy 记录这张证书所属 issuer / 续期元信息的小账本。再过约 20 天 ACME 客户端会自动续期、覆盖这三个文件——而**整个流程不需要任何人插手**。

## 3.6 复盘：刚才到底发生了什么

回顾本步实际做的事（按时间顺序）：

1. 改了一份 Caddyfile（去掉 `auto_https off`、加一段 `tls { issuer acme { dir ... } }`）；
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
- [ ] `openssl s_client -connect caddy.local:443 -servername caddy.local` 拿到的证书 issuer = `learn.internal Intermediate Authority`、SAN（critical）含 `DNS:caddy.local`、有效期约 30 天
- [ ] `/root/caddy_data/caddy/certificates/...` 下能看到 `caddy.local.crt` 与 `caddy.local.key`

至此完成本实验全部三步：从『纯 HTTP 反例』到『PKI + ACME 一次性配齐』再到『Caddy 全自动从 Vault 拿到证书』，9.3 节正文中所有关键论断都已在终端里得到亲手验证。
