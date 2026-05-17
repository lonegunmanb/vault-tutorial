# 第二步：Consul-Template 把动态凭据渲染成配置文件

第一条路径：让 Consul-Template 充当"配置文件维护工"——它去 Vault 拿 `database/creds/readonly` 的动态凭据，把模板渲染进 `/etc/legacy-app/config.toml`，**先在 lease 半程时自动续期同一份凭据**，等到 `max_ttl`（实验里设为 2 分钟）逼近时再去申请一份全新的。`legacy-app` 仍然只懂"读配置文件"。

## 2.1 看一眼模板与配置

```bash
cat /root/legacy-lab/config.toml.tplt
echo '---'
cat /root/legacy-lab/ct_config.hcl
```{{exec}}

要点：

- 模板用 `{{ with secret "database/creds/readonly" }}` 包裹；`secret` 函数对应 Vault 的 `database/creds/<role>` 端点，这类 lease **默认是可续期的**；
- `ct_config.hcl` 里 `renew_token = true` 显式开启 **Vault token 自动续期**（默认即为 true，写出来是为了让"自动续期"看得见）；
- 对**可续期** lease（如本节的 `database/creds`），Consul-Template 内部会**自动**给每一份 secret 启动一个 renewer goroutine，在 lease 走完一半时调 Vault 的 renew 接口续期，**没有专门的开关**；
- `lease_renewal_threshold = 0.5` 只对**不可续期**的 lease 生效；本节 `database/creds` 不会走它，但保留下来方便对照官方文档。

## 2.2 后台启动 `legacy-app`，让它一直对着配置文件循环

```bash
mkdir -p /var/log/legacy-app
nohup /usr/local/bin/legacy-app > /var/log/legacy-app/app.log 2>&1 &
echo $! > /var/run/legacy-app.pid
sleep 2
tail -n 5 /var/log/legacy-app/app.log
```{{exec}}

此时 `legacy-app` 已经在后台轮询 Postgres 了，但配置文件里还是第一步那条 30 秒就要过期的凭据——很快会看到日志里出现 `FAIL`。

## 2.3 启动 Consul-Template

打开第二个独立的"轨道"，让 Consul-Template 接管这份配置文件：

```bash
nohup consul-template \
  -config=/root/legacy-lab/ct_config.hcl \
  -template="/root/legacy-lab/config.toml.tplt:/etc/legacy-app/config.toml" \
  -vault-renew-token=true \
  -log-level=info \
  > /var/log/consul-template.log 2>&1 &
echo $! > /var/run/consul-template.pid
sleep 3
tail -n 15 /var/log/consul-template.log
```{{exec}}

`-vault-renew-token=true` 在命令行再显式声明一次 token 续期；`-template` 的格式是 `源:目标`。Consul-Template 启动时 `VAULT_ADDR` / `VAULT_TOKEN` 直接从环境继承（root token，dev 模式下足够）。

## 2.4 阶段一：观察"续期"——同一个用户名，被反复续命

启动后立刻抓一次快照：

```bash
echo '--- T0：config.toml ---'
cat /etc/legacy-app/config.toml
echo '--- T0：pg_user 中由 Vault 创建的临时用户 ---'
docker exec -i learn-postgres psql -U root -d postgres -c "SELECT usename, valuntil FROM pg_user WHERE usename LIKE 'v-token-readonly%' ORDER BY valuntil;"
sleep 40
echo
echo '--- T0 + 40s：config.toml ---'
cat /etc/legacy-app/config.toml
echo '--- T0 + 40s：pg_user ---'
docker exec -i learn-postgres psql -U root -d postgres -c "SELECT usename, valuntil FROM pg_user WHERE usename LIKE 'v-token-readonly%' ORDER BY valuntil;"
```{{exec}}

预期：两次快照的 `username` **完全一样**，但 `valuntil` 已经往后推了。这就是 Consul-Template 的 secret renewer 在帮你做的事——同一条 lease 被静默续期，应用甚至感知不到。

可以再去 Consul-Template 的日志里印证：

```bash
grep -E 'renewed secret|renewer' /var/log/consul-template.log | tail -n 10
```{{exec}}

会看到一条条 `renewed secret(... database/creds/readonly)` 记录。

## 2.5 阶段二：观察"重取"——max_ttl 到点后 CT 申请新凭据

等到 lease 累计存活逼近 `max_ttl=2m` 时，Vault 会拒绝再续，CT 必须重新申请：

```bash
echo '--- 现在再等 90 秒，让 max_ttl 到点 ---'
sleep 90
echo '--- T0 + 130s：config.toml ---'
cat /etc/legacy-app/config.toml
echo '--- T0 + 130s：pg_user ---'
docker exec -i learn-postgres psql -U root -d postgres -c "SELECT usename, valuntil FROM pg_user WHERE usename LIKE 'v-token-readonly%' ORDER BY valuntil;"
```{{exec}}

预期：`username` **变了**，是一个全新的 `v-token-readonly-…` 串；`pg_user` 里短暂可能同时出现新旧两个用户（旧的接下来会被 Vault `DROP ROLE` 掉）。再看 CT 日志：

```bash
grep -E 'received new secret|received empty' /var/log/consul-template.log | tail -n 10
```{{exec}}

会看到一条 `received new secret(... database/creds/readonly)`——这就是 CT "续不动了、改去重取"的那一刻。

## 2.6 看 `legacy-app` 的日志

```bash
tail -n 20 /var/log/legacy-app/app.log
```{{exec}}

预期看到一段"FAIL（用第一步过期的旧凭据）→ OK（CT 写盘后下次 10 秒轮询读到新凭据）→ 一长串 OK（续期阶段，username 不变）→ 短暂 FAIL（轮转瞬间应用还在用旧 username）→ OK（应用下次轮询读到新 username）"。

> 这是 Consul-Template 路径的**固有节奏**：续期阶段应用完全无感、零故障；只有在 `max_ttl` 到点的那次重取时，应用如果不是"立即重读配置文件 / 凭据失败就立即重连"，就会有一小段窗口期用着已被 Vault 撤销的旧用户。本节 `legacy-app` 每 10 秒重读一次 + 凭据失败立刻报错，所以这个窗口非常短；对**完全没有重读机制**的旧二进制，第三步就要换条路。

继续前先把这条轨道关掉，避免和下一步抢资源：

```bash
kill "$(cat /var/run/consul-template.pid)" 2>/dev/null || true
kill "$(cat /var/run/legacy-app.pid)" 2>/dev/null || true
sleep 2
pgrep -a consul-template || echo 'consul-template stopped'
pgrep -a legacy-app || echo 'legacy-app stopped'
```{{exec}}
