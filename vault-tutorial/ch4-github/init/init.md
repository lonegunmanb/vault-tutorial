# 实验：GitHub 认证完整动手（Prism + Nginx + 自签证书 + hosts 劫持搭"假 GitHub"）

[4.4 章](/ch4-github) 系统介绍了 Vault GitHub 认证方法实际调用的
GitHub API、`organization` TOFU、team / user 两级 policy 映射、PAT
风险模型。本实验**不要求你拥有真实 GitHub 账号**——而是在一台
Killercoda VM 上自行搭建一个让 Vault 完全无法分辨真伪的
`api.github.com`：

- **Prism 4.10.5** 按一份 OpenAPI spec 把 Vault 会调用的
  `/user`、`/user/orgs`、`/user/teams`、`/orgs/{org}` 几条端点 mock
  出来
- **Nginx** 在 `:443` 监听 TLS、把请求反向代理到本机 :4010 的 Prism
- **自签证书** CN/SAN = `api.github.com`，复制到
  `/usr/local/share/ca-certificates/` 后执行 `update-ca-certificates`，
  系统 CA 根（Vault 默认就读取此处）即刻信任该证书
- **`/etc/hosts`** 把 `api.github.com` 重定向到 `127.0.0.1`，让
  Vault 在毫无察觉的情况下走完整套真实链路

> 这种做法的好处：实验全程**不修改 `auth/github/config.base_url`**——
> Vault 始终以为自己在与真 GitHub 对话，TLS 信任、DNS 解析、几条
> REST API 都完整执行。本实验是一个**协议演示与故障注入平台**，
> 主要用来呈现 Vault 如何调用 GitHub API——**不要把它当作 GHES 生
> 产接入指南**：真实 GHES 部署应当使用 `base_url` 显式指向
> `https://<ghes>/api/v3/`、显式填写 `organization_id`、并使用合
> 法 CA 链。

- **Step 1**：生成自签证书 → 安装到系统 CA 根 → 写入 `/etc/hosts`
  → 启动 Prism mock → 启动 Nginx TLS 反向代理 → 用
  `curl https://api.github.com` 验证整条链路
- **Step 2**：`vault auth enable github` → `vault write
  auth/github/config organization=hashicorp` → 观察 Vault 实际向
  fake GitHub 发出的 `GET /orgs/hashicorp` 请求，并把
  `organization_id=761456` 学回 storage
- **Step 3**：编写 `dev-policy` → `map/teams/dev value=dev-policy`
  → `vault login -method=github token=anything`，完整执行登录链路
  上的所有 API 调用、查看签发的 token metadata
  （`username=testuser` / `org=hashicorp`）与 policy 列表
- **Step 4**：修改 mock 让用户落到另一个 org / 让 team 缺失 / 把
  org rename，观察 Vault 端的失败现场；最后通过
  `vault auth disable github` 验证级联吊销

## 实验环境预置内容

- 安装 Vault 1.19.2 并以 Dev 模式启动（root token = `root`）
- 安装 Node.js 18、`@stoplight/prism-cli@4.10.5`、Nginx、jq、openssl
- 把 4 个素材文件放到 `/root/`：`github-mock.yaml`（OpenAPI
  spec）、`openssl-san.cnf`（自签证书的 SAN 配置）、
  `nginx-fakegh.conf`（Nginx TLS 反向代理配置）、`setup-common.sh`
  （公共安装脚本）
- 持久化 `VAULT_ADDR` / `VAULT_TOKEN` 到后续所有 shell
- **不会**预生成证书、**不会**修改 `/etc/hosts`、**不会**启动
  Prism / Nginx、**不会**启用 github 认证——所有"搭建假 GitHub +
  对接 Vault"的操作均由你在各步骤中手动执行

## ℹ️ 关于 Prism 4.10.5

Prism 5.x 在 Node 18 上存在 ESM 兼容问题（`@faker-js/faker` 抛出
`ERR_REQUIRE_ESM`），因此本实验显式 pin 4.10.5——这是仍能在 stock
`apt install nodejs npm` 环境下正常运行的最后一个稳定版本。它对
静态 `example` 的支持完全满足本实验需求。

## ℹ️ 关于"为何不直接修改 base_url"

把 `auth/github/config.base_url` 改成 `http://127.0.0.1:4010/` 同
样能让 Vault 与 mock 互通——但那条路径**不演示 TLS 信任链与 DNS
解析**，对理解 Vault 如何识别 GitHub 帮助有限。本实验特意走完整的
"DNS 重定向 + 自签证书 + 系统 CA 根"链路，让你完整体验一次 Vault
的 TLS 调用路径。生产接入 GHES 的推荐路径仍然是 `base_url` + 合法
CA，**不要**把本实验中的 hosts/CA 劫持手法用于生产环境。
