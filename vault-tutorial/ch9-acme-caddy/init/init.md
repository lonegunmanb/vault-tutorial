# 实验说明

本实验配套 [9.4 节正文](https://lonegunmanb.github.io/vault-tutorial/ch9-acme-caddy.html)：学员此时已经在概念层理解了 **ACME 协议** 的四个角色（ACME 服务器 / 客户端 / 域名 / 挑战路径）与三步对话（下单 / 挑战 / 结单），也理解了为什么要让 Vault 的 PKI 引擎扮演内网的 ACME 服务器、让 Caddy 充当 ACME 客户端。本实验把这套思想落到一台 Killercoda 主机上：

- **ACME 服务器**：Vault 1.19.2，dev 模式，监听 `127.0.0.1:8200`；下面会启用一套两级 PKI（根 CA `pki/` + 中间 CA `pki_int/`），并在中间 CA 上打开 ACME 开关；
- **ACME 客户端**：Caddy 2.8 容器，`--network host` 直接共享主机网络栈，监听 `:80`（用于 HTTP-01 挑战）与 `:443`（对外提供 HTTPS）；
- **要保护的域名**：一个虚拟主机名 `caddy.local`，已经写入 `/etc/hosts` 解析到 `127.0.0.1`，让 Vault 与 curl 都能找到 Caddy。

实验分三步：

1. **第一步**：检查后台已经替你准备好的环境；以**纯 HTTP** 配置启动 Caddy；用 `curl` 验证 `http://caddy.local/` 能拿到 hello world、`https://caddy.local/` 失败——建立一个清晰的对照基线，然后停掉 Caddy 进入下一步。
2. **第二步**：执行预置脚本 `/root/pki/enable_engines.sh`，把根 CA + 中间 CA 一次配齐；逐句解释脚本里每条命令；然后用三条额外命令在中间 CA 上打开 ACME（`secrets tune` 放开必需的 HTTP 头、`config/acme enabled=true`、`vault read pki_int/config/acme` 验证）。
3. **第三步**：用一份指向 Vault ACME directory 的 Caddyfile 重启 Caddy；什么手工证书操作都不做，等几秒；用 `curl --cacert /root/pki/root_2024_ca.crt https://caddy.local/` 拿到 hello world；用 `openssl s_client` / `openssl x509` 看到证书的 Issuer 是 `learn.internal Intermediate Authority`、有效期只有 30 天——亲眼看到内部 PKI 的 ACME 流水线已经在静默运行。

为完全规避真实云成本，整个实验都在单台 Killercoda 主机上完成：

- 已安装 vault（1.19.2，dev 模式后台运行）、jq、curl、openssl；
- 已写入 `VAULT_ADDR=http://127.0.0.1:8200`、`VAULT_TOKEN=root`；
- 已把 `caddy.local` 写入 `/etc/hosts` 解析到 `127.0.0.1`；
- 已 `docker pull caddy:2.8` 把镜像拉好，避免课堂上等待网络；
- 已在 `/root/pki/enable_engines.sh` 准备好『一键搭好两级 PKI』的脚本（与官方 [pki-acme-caddy 教程](https://developer.hashicorp.com/vault/tutorials/pki/pki-acme-caddy) 中的同名脚本逻辑一致，只把 issuer 名换成 `root-2024`、把 cluster 路径换成 `127.0.0.1:8200`）。

> 本实验全程使用明文 HTTP 与 Vault 交互（Vault 监听 `:8200`），目的是让 `curl` 与 ACME 通信都干净易读、便于直接观察请求与响应；生产环境应当按 [6.2 节](/ch6-listener-tls) 给 Vault 自身配上 TLS。同样，dev 模式 Vault 用 `root` Token、把数据保存在内存里，绝不能用于任何真实业务。
