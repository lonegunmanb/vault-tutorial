# 第一步：搭建"假 GitHub"——自签证书 + hosts 劫持 + Prism + Nginx TLS

[4.4 章 §9](/ch4-github) 介绍过两种 mock 方案的权衡：本实验采用
"完整模拟真实链路"的方式——**不修改 `auth/github/config.base_url`**，
让 Vault 默认仍然访问 `https://api.github.com/`，然后在系统层把
DNS、TLS、HTTP 三层逐一替换。本步将这套"假 GitHub"完整搭建起来，
**用 `curl https://api.github.com` 验证**它能在 curl 不携带任何特殊
参数的情况下正常返回 JSON。

> 本步骤所有命令均以 root 身份执行（Killercoda 默认即为 root），
> 无需 sudo。

## 1.1 查看素材文件

```bash
ls -1 /root/{github-mock.yaml,openssl-san.cnf,nginx-fakegh.conf}
```

- **`github-mock.yaml`**：一份手写的 OpenAPI 3 spec，仅覆盖 Vault
  实际调用的 GitHub API（`/user`、`/user/orgs`、`/user/teams`、
  `/orgs/{org}`）。每条响应同时声明
  `application/vnd.github.v3+json` 与 `application/json` 两个
  content-type；`/user/teams` 还额外提供
  `application/vnd.github.hellcat-preview+json`——这正是
  [4.4 章 §2](/ch4-github) 中"`go-github` 对 teams API 仍发送
  hellcat-preview"那条规则的实际落地，缺少这一条 Prism 会以 406
  拒绝请求。
- **`openssl-san.cnf`**：自签证书的 SAN 配置——CN=`api.github.com`，
  SAN 包含 `api.github.com` / `github.com` / `www.github.com`。
- **`nginx-fakegh.conf`**：Nginx 配置——`:443` 监听 TLS、使用上述
  证书、把请求反向代理到本机 `:4010`（Prism）。

简单浏览一下 spec 与 nginx 配置：

```bash
head -25 /root/github-mock.yaml
echo '---'
cat /root/nginx-fakegh.conf
```

## 1.2 生成自签证书并安装到系统 CA 根

本节是整套链路的关键环节——Vault 内部使用 Go 的 `crypto/tls` 默认
SystemCertPool 加载根 CA，**Linux 上对应的就是
`/etc/ssl/certs/ca-certificates.crt`**。把自签 CA 写入
`/usr/local/share/ca-certificates/` 后执行 `update-ca-certificates`，
新启动的 Vault 进程便会将其视为合法 CA：

```bash
mkdir -p /etc/ssl/fakegh
openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout /etc/ssl/fakegh/api.github.com.key \
    -out    /etc/ssl/fakegh/api.github.com.crt \
    -config /root/openssl-san.cnf \
    -extensions v3_req
```

确认 SAN 已正确写入：

```bash
openssl x509 -in /etc/ssl/fakegh/api.github.com.crt -noout \
    -subject -issuer -ext subjectAltName
```

应看到：

```
subject=C = US, ST = CA, L = San Francisco, O = FakeGitHub, CN = api.github.com
issuer=C = US, ST = CA, L = San Francisco, O = FakeGitHub, CN = api.github.com
X509v3 Subject Alternative Name:
    DNS:api.github.com, DNS:github.com, DNS:www.github.com
```

> Subject 与 Issuer 一致即为"自签"——既是叶证书也是 CA 根。Go 的
> `crypto/tls` 在验证服务器证书时会按 hostname 匹配 SAN（SAN 必须
> 包含 `api.github.com`），再到 root pool 中查找信任链——自签证书
> 既在链上又是 root，匹配即通过。

复制到系统 CA 根目录并刷新：

```bash
cp /etc/ssl/fakegh/api.github.com.crt \
   /usr/local/share/ca-certificates/fakegh-api.github.com.crt
update-ca-certificates
```

应看到 `1 added, 0 removed`。`/etc/ssl/certs/ca-certificates.crt`
此时已经包含了这张证书。

## 1.3 把 `api.github.com` 重定向到 127.0.0.1

```bash
grep -v 'github\.com' /etc/hosts > /tmp/hosts.new || true
echo "127.0.0.1 api.github.com github.com www.github.com" >> /tmp/hosts.new
cat /tmp/hosts.new > /etc/hosts
grep github /etc/hosts
```

> 这里**不使用 `sed -i`**——/etc/hosts 在容器化环境中通常是 bind
> mount，`sed -i` 的 rename 操作会失败。先写到 /tmp，再用 `cat
> > /etc/hosts` 这种 in-place truncate-and-write 的方式覆盖最为
> 稳妥。

验证 DNS 重定向已生效：

```bash
getent hosts api.github.com
```

应看到 `127.0.0.1 api.github.com`。

## 1.4 启动 Prism mock

```bash
nohup prism mock -h 127.0.0.1 -p 4010 /root/github-mock.yaml \
    > /var/log/prism.log 2>&1 &
echo "prism pid=$!"
```

等待 3 秒让其就绪，然后逐一调用各端点验证：

```bash
sleep 3
echo '--- /user ---'
curl -s http://127.0.0.1:4010/user | jq .
echo '--- /orgs/hashicorp ---'
curl -s http://127.0.0.1:4010/orgs/hashicorp | jq '.login, .id'
echo '--- /user/orgs ---'
curl -s http://127.0.0.1:4010/user/orgs | jq '.[].login'
echo '--- /user/teams (使用 hellcat-preview accept) ---'
curl -s -H "Accept: application/vnd.github.hellcat-preview+json" \
     http://127.0.0.1:4010/user/teams | jq '.[].slug'
```

应分别看到 `testuser`、`"hashicorp" / 761456`、`"hashicorp"`、
`"dev" / "ops"`。Prism 出现异常时执行 `tail -50 /var/log/prism.log`
排查。

## 1.5 启动 Nginx TLS 反向代理

```bash
cp /root/nginx-fakegh.conf /etc/nginx/nginx.conf
nginx -t
nginx
```

`nginx -t` 应输出 `syntax is ok ... test is successful`；执行
`nginx` 后没有任何输出即说明 daemon 已启动。

## 1.6 端到端验证：执行 `curl https://api.github.com/...`

本节是整步的**重点**——`curl` **不传递任何 `--cacert` 或 `-k`**，
完全依赖系统 CA 根和写入的 hosts 解析：

```bash
echo '=== curl https://api.github.com/user ==='
curl -sS --max-time 5 https://api.github.com/user | jq .

echo
echo '=== curl https://api.github.com/orgs/hashicorp ==='
curl -sS --max-time 5 https://api.github.com/orgs/hashicorp | jq '{login, id}'

echo
echo '=== 使用 verbose 模式查看 TLS 证书链 ==='
curl -v --max-time 5 https://api.github.com/user 2>&1 | \
    grep -E 'subject:|issuer:|verify|SSL connection'
```

应看到：

- `/user` 返回 `{"login": "testuser", ...}`
- `/orgs/hashicorp` 返回 `{"login":"hashicorp","id":761456}`
- verbose 输出中包含 `subject: CN=api.github.com`、
  `issuer: CN=api.github.com`、`SSL certificate verify ok`

如果 `curl` 直接返回了 JSON 且**未给出任何关于自签证书的警告**，
说明：

1. DNS 重定向已生效——curl 并未访问公网 GitHub，而是回到了 127.0.0.1
2. 系统 CA 根已信任自签证书——TLS 握手通过、证书验签通过
3. Nginx 收到请求后正确反向代理给了 Prism、Prism 按 spec 返回了 JSON

> **此时若执行
> `curl https://api.github.com/repos/hashicorp/vault`**（mock 未覆
> 盖此路径），会返回 404 或 500——Prism spec 中没有这条端点。这是
> 预期行为——本实验只 mock Vault 实际会调用的几条 API。

## 1.7 查看 Nginx 的访问日志

`nginx-fakegh.conf` 配置了一个自定义 log_format `hdr`，会记录每个
请求的 `Accept` 与 `User-Agent`——下一步将用它来观察 Vault 实际
发送的 header：

```bash
tail -10 /var/log/nginx/access.log
```

应能看到几条 `accept="*/*" ua="curl/..."` 的记录。

## 1.8 本步骤的核心闭环

至此"假 GitHub"已经搭建完毕——Prism 提供 JSON、Nginx 提供 TLS、
hosts 提供 DNS、系统 CA 根提供信任。任何调用方（包括下一步的
Vault）只要访问 `https://api.github.com/...`，**完全不需要知道背
后是 mock**。下一步将让 Vault 介入这套链路。
