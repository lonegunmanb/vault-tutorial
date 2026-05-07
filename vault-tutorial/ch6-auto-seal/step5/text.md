# 第五步：停掉 LocalStack 复现 KMS 不可达故障路径

[6.3 节 §4](/ch6-auto-seal) 的论断之二："开源版只用 KMS 解封根密钥，KMS 的可用性窗口仅限于 Vault 启动这一瞬间。一旦 Vault 解封成功，根密钥就驻留进程内存，KMS 短暂宕机不会立刻让正在运行的 Vault 拒绝服务；只有当 Vault 进程**重启**且此时 KMS 不可达，才会卡在 sealed 状态无法启动。"本步把这两半都演示一遍。

## 5.1 半场 A：KMS 宕机但 Vault 进程还在跑——业务不受影响

先确认 Vault 当前在跑且 unsealed：

```bash
vault status | grep -E '^(Initialized|Sealed)'
```

往一个临时挂载的 KV 引擎写一条数据，作为后续的可读探针：

```bash
vault secrets enable -path=kv kv-v2 || true
vault kv put kv/canary value=before-localstack-down
```

现在把 LocalStack 容器**直接停掉**：

```bash
docker stop localstack
docker ps -a --filter name=localstack --format '{{.Names}} {{.Status}}'
```

LocalStack 应当处于 `Exited` 状态，`:4566` 端口不再 LISTEN：

```bash
ss -lntp | grep ':4566' || echo "no longer listening on 4566 (expected)"
```

此时 Vault 进程**仍然在跑**——根密钥早已驻留在 Vault 进程内存里，KMS 宕机不会立刻让正在运行的 Vault 拒绝服务。验证：

```bash
vault status | grep -E '^(Sealed)'
vault kv get kv/canary
```

`Sealed: false`，且 KV 读取返回 `value: before-localstack-down`——业务读写完全不受 KMS 宕机影响。这就是 §4 中"KMS 的可用性窗口仅限于启动这一瞬间"在开源版上的具体含义。

## 5.2 半场 B：Vault 重启 + KMS 仍不可达 → 启动失败

继续保持 LocalStack 处于停止状态，把 Vault 进程也 kill 掉：

```bash
kill "$(cat /tmp/vault.pid)" 2>/dev/null || true
sleep 1
ss -lntp | grep ':8200' || echo "vault no longer listening on 8200 (expected)"
```

再次启动 Vault：

```bash
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
sleep 3
```

观察 Vault 日志：

```bash
tail -50 /var/log/vault.log
```

你会看到 Vault 进程在反复尝试调 KMS 但失败——日志中会出现连接被拒绝（`connection refused`）、初始化 seal 失败一类的错误信息。Vault 进程要么已经退出，要么虽然还活着但停留在 sealed / 未初始化状态。

```bash
vault status || true
```

CLI 端要么直接报"server is not yet ready"一类的错误（如果 Vault 进程已退出），要么显示 `Sealed: true` —— 与 [Step 4.4](#) 的 `Sealed: false` 形成鲜明对比。

> 这个对照实验直观地刻画了 **KMS 在 Vault 启动那一瞬间的强依赖性质**：auto-unseal 是把"信任根的可用性"委托给 KMS；只要 Vault 进程有重启需求，KMS 就必须可达。生产部署中应据此为 KMS 设置高可用架构，并把 KMS 的 SLO 纳入 Vault 自身可用性 SLO 的依赖项。

## 5.3 复原现场：把 LocalStack 重新拉起来

为后续可能的复盘，把 LocalStack 重新启动并再次启动 Vault：

```bash
docker start localstack
sleep 3
curl -s http://127.0.0.1:4566/_localstack/health | jq '.services.kms'
```

KMS 子服务再次 `available` 后，重启 Vault：

```bash
kill "$(cat /tmp/vault.pid)" 2>/dev/null || true
sleep 1
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
sleep 3
vault status | grep -E '^(Initialized|Sealed|Seal Type)'
```

应回到 `Initialized=true`、`Sealed=false`、`Seal Type=awskms`——Vault 又一次完成了 auto-unseal。

> LocalStack 容器停止时 KMS 中的密钥 / alias **会丢失**——容器是无状态的本地模拟。但本实验没有 `docker rm` 容器（仅 `docker stop` + `docker start`），所以密钥 / alias 在容器存活期间保持持久；如果你执行了 `docker rm localstack`，则需要回 Step 1 重建。

## 5.4 这一步的核心闭环

KMS 宕机时正在运行的 Vault 不受影响（开源版语义），但一旦 Vault 重启且 KMS 仍不可达就会卡 sealed 启动失败。这两半合起来给出 §4 中那条边界结论的完整验证。
