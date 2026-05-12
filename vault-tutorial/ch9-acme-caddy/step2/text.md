# 第 2 步：在 Vault 上搭两级 PKI 并启用 ACME

本步要在 Vault 里完成两件事：

1. **建立两级 PKI**：根 CA 挂载在 `pki/`、中间 CA 挂载在 `pki_int/`；根 CA 自签一张根证书，中间 CA 用根 CA 签一张中间证书。这一步与 [3.7 节](/ch3-pki) 已经讲过的搭建套路完全一致，可以理解为『先把传统 PKI 摆好』。
2. **在中间 CA 上启用 ACME**：让 `pki_int/` 这个挂载点对外暴露符合 RFC 8555 的 ACME 协议接口。这是本节的重头戏。

## 2.1 用一键脚本把两级 PKI 摆好

预置脚本 `/root/pki/enable_engines.sh` 把第 1 件事所有命令一次跑完。先在编辑器里打开它浏览一遍（`/root/pki/enable_engines.sh`）；如果想在终端里直接看：

```bash
sed -n '1,80p' /root/pki/enable_engines.sh
```

脚本里值得留意的关键命令有 7 段，逐句解释：

| 段号 | 命令骨架 | 作用 |
| --- | --- | --- |
| 1 | `vault secrets enable pki` + `tune -max-lease-ttl=87600h` | 在 `pki/` 挂载根 CA 引擎，把它的最大签发期延到 10 年（根证书需要长寿命） |
| 2 | `vault write pki/root/generate/internal common_name="learn.internal" issuer_name="root-2024"` | 让根 CA **自签一张根证书**；`-field=certificate` 把证书 PEM 重定向到 `root_2024_ca.crt`，下一步 curl 会用 `--cacert` 指它 |
| 3 | `vault write pki/config/cluster path=...` | 配置根 CA 的 `cluster path`，影响之后 AIA / CRL / OCSP URL 模板 |
| 4 | `vault write pki/roles/2024-servers allow_any_name=true` | 在根 CA 上建一个签发角色（本实验里其实用不上，留作演示） |
| 5 | `vault secrets enable -path=pki_int pki` + 中间 CA 生成 CSR + 根 CA 签名 + 把签好的中间证书写回 | 标准的两级 PKI 搭法；学员若做过 3.7 节实验会对这套指令组合非常熟悉 |
| 6 | `vault write pki_int/config/cluster path=http://127.0.0.1:8200/v1/pki_int` | **关键**——ACME directory 里所有 `newAccount` / `newOrder` / `newNonce` URL 都会以这里的 `path` 为前缀；客户端必须能通过这个 URL 访问到 Vault |
| 7 | `vault write pki_int/roles/learn allow_any_name=true max_ttl=720h` | 在中间 CA 上建签发角色 `learn`，`max_ttl=720h`（30 天）——配合 ACME 的自动续期，TTL 越短，泄露窗口越窄 |

> **为什么 `pki_int/config/cluster` 那么重要？** ACME 协议要求服务器返回一份 `directory` JSON 文档，里面是『下单走哪个 URL、申请新 nonce 走哪个 URL……』的总目录，且这些 URL **必须是绝对 URL**。Vault 在生成这份文档时直接把 `cluster.path` 作为前缀拼上去——如果这里写错了（例如写成了客户端无法访问的内部 IP），客户端拿到 directory 之后就会卡在第一步。

执行脚本：

```bash
cd /root/pki
./enable_engines.sh 2>&1 | tail -10
```

脚本结尾会打印 `✅ 两级 PKI 已就绪`。验收一下：

```bash
vault secrets list | grep '^pki'
ls -l /root/pki/root_2024_ca.crt
```

预期：

```
pki/          pki        pki_xxxxxxxx        n/a
pki_int/      pki        pki_yyyyyyyy        n/a
-rw-r--r-- 1 root root  1xxx ... /root/pki/root_2024_ca.crt
```

## 2.2 在中间 CA 上打开 ACME

ACME 是单独的 3 条命令——之所以单独拿出来讲，是因为这 3 条是本节真正『从普通 PKI 升级为 ACME 服务器』的关键。

**第 1 条**：先确认 `pki_int/config/cluster` 已经设好（脚本里已经做了，这里只是『再读一次确认』）：

```bash
vault read pki_int/config/cluster
```

预期：

```
Key         Value
---         -----
aia_path    http://127.0.0.1:8200/v1/pki_int
path        http://127.0.0.1:8200/v1/pki_int
```

**第 2 条**：通过 `secrets tune` 让 `pki_int/` 这个挂载点放行 ACME 协议必需的 HTTP 头：

```bash
vault secrets tune \
  -passthrough-request-headers=If-Modified-Since \
  -allowed-response-headers=Last-Modified \
  -allowed-response-headers=Location \
  -allowed-response-headers=Replay-Nonce \
  -allowed-response-headers=Link \
  pki_int
```

预期输出：

```
Success! Tuned the secrets engine at: pki_int/
```

> **为什么要单独 tune 头？** Vault 默认会过滤掉绝大多数请求 / 响应 HTTP 头以减少攻击面。ACME 协议恰恰要在 HTTP 头里塞 `Replay-Nonce`、`Link`、`Location` 等关键信息——不显式放行，客户端就读不到这些头、整个协议立即崩溃。这是 ACME 启用过程里最容易被漏掉的一步。

**第 3 条**：在 `pki_int/` 上启用 ACME：

```bash
vault write pki_int/config/acme enabled=true
```

预期输出至少包含 `enabled    true`：

```
Key                         Value
---                         -----
allowed_issuers             [*]
allowed_roles               [*]
default_directory_policy    sign-verbatim
dns_resolver                n/a
eab_policy                  not-required
enabled                     true
...
```

## 2.3 验证 ACME directory 已经在线

ACME 客户端（Caddy）连接 ACME 服务器的第一件事就是 GET 一个叫 `directory` 的 URL，拿到全部协议端点的总目录。可以用 curl 模拟一下，确认 Vault 这一侧已经准备好：

```bash
curl -s http://127.0.0.1:8200/v1/pki_int/acme/directory | jq .
```

预期输出形如：

```json
{
  "keyChange": "http://127.0.0.1:8200/v1/pki_int/acme/key-change",
  "meta": {
    "externalAccountRequired": false
  },
  "newAccount": "http://127.0.0.1:8200/v1/pki_int/acme/new-account",
  "newNonce": "http://127.0.0.1:8200/v1/pki_int/acme/new-nonce",
  "newOrder": "http://127.0.0.1:8200/v1/pki_int/acme/new-order",
  "revokeCert": "http://127.0.0.1:8200/v1/pki_int/acme/revoke-cert"
}
```

其中 5 个 URL 字段对应 RFC 8555 规定的 5 个协议端点；`meta.externalAccountRequired = false` 表示本服务器不要求 EAB（External Account Binding，参见 finish 页『把这套思路放回真实工程』一节）。注意每个 URL 都是以 `http://127.0.0.1:8200/v1/pki_int` 为前缀的绝对 URL——这正是 2.1 节里 `pki_int/config/cluster` 的 `path` 字段决定的。如果这里看到的 URL 前缀不对，下一步 Caddy 一定连不上，请回到 2.1 节检查。

---

## ✅ 验收

- [ ] `./enable_engines.sh` 顺利结束，最后一行是 `✅ 两级 PKI 已就绪`
- [ ] `/root/pki/root_2024_ca.crt` 文件存在且非空
- [ ] `vault read pki_int/config/cluster` 的 `path` 字段是 `http://127.0.0.1:8200/v1/pki_int`
- [ ] `vault write pki_int/config/acme enabled=true` 返回的输出里 `enabled` 字段为 `true`
- [ ] `curl http://127.0.0.1:8200/v1/pki_int/acme/directory` 返回的 JSON 含有 `newOrder` / `newNonce` / `newAccount` 三个绝对 URL

下一步将用一份指向 Vault ACME directory 的 Caddyfile 重启 Caddy，**什么手工证书操作都不做**，等几秒，然后用 curl 与 openssl 验证：HTTPS 自动通了、证书的 Issuer 就是我们刚搭起来的 `learn.internal Intermediate Authority`。
