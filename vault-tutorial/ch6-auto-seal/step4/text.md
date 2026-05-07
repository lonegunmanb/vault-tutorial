# 第四步：重启 Vault 验证 auto-unseal 真正工作

[6.3 节 §4](/ch6-auto-seal) 与 §6 都强调过：auto-unseal 与 Shamir 最直观的运维差异，发生在**Vault 进程重启**的那一刻——Shamir 模式下需要操作员到场重新输入分片，auto-unseal 模式下 Vault 自己调一次 KMS 就能恢复 unsealed 状态。本步通过实际操作把这一差异可视化。

## 4.1 重启前先记录当前状态

```bash
vault status | grep -E '^(Initialized|Sealed|Seal Type)'
ps -p "$(cat /tmp/vault.pid)" -o pid,cmd | head
```

应看到 `Initialized=true`、`Sealed=false`、`Seal Type=awskms`，且 Vault 进程在跑。

## 4.2 kill Vault 进程

```bash
kill "$(cat /tmp/vault.pid)"
sleep 1
ss -lntp | grep ':8200' || echo "vault no longer listening on 8200 (expected)"
```

`8200` 端口应当不再被任何进程占用。

## 4.3 再次启动 Vault，**完全不输入任何解封分片**

```bash
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
sleep 2
cat /tmp/vault.pid
```

> Shamir 模式下，到这一刻必须再执行三次 `vault operator unseal $KEY` 才能让 Vault 回到 unsealed 状态；本步**故意完全跳过**这一步。

## 4.4 直接看状态——它应当已经解封

```bash
vault status
```

预期输出：

```
Key                      Value
---                      -----
Seal Type                awskms
Recovery Seal Type       shamir
Initialized              true
Sealed                   false
HA Enabled               true
HA Cluster               https://127.0.0.1:8201
HA Mode                  active
```

`Sealed: false`——Vault 在自己启动的过程中调了一次 KMS 的 Decrypt API，把根密钥取了回来，整个解封过程**完全免人值守**。

## 4.5 旁证：从 LocalStack 一侧再次确认 KMS Decrypt 被调用

```bash
docker logs localstack 2>&1 | grep -iE 'decrypt' | tail -5
```

应能看到本次重启对应的 `Decrypt` 调用。如果用日志时间戳与刚才的 Vault 启动时间对照，会更直观。

## 4.6 反向验证：root token 仍然有效

虽然进程重启了，root token 依然写在 `/etc/profile.d/vault.sh` 中，自动加载到当前 shell。直接过滤出 `policies` 行：

```bash
vault token lookup | grep -E '^(policies|type|ttl)\b'
```

应能看到：

```
policies          [root]
ttl               0s
type              service
```

`policies` 仍是 `[root]`——根密钥成功解密了存储后端中保存的 token 元数据。

## 4.7 这一步的核心闭环

Vault 进程已被强行 kill 并重启；**没有人按过任何 unseal 命令**；Vault 自己通过 KMS 取回根密钥并完成解封。这就是 auto-unseal 在运维层面的核心价值——也是 [6.3 节 §6](/ch6-auto-seal) 中所述"运维成本视角下应优先选择 auto-unseal"的真实演示。下一步反过来：故意把 KMS 弄不可达，观察 Vault 启动失败的故障路径。
