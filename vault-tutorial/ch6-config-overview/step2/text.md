# 第二步：启动 Vault 服务并完成初始化与解封

在后台启动 Vault，把日志写入 `/var/log/vault.log`：

```bash
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
sleep 2
```

确认进程存在，并确认 `pid_file` 已写入：

```bash
cat /tmp/vault.pid
ps -p "$(cat /tmp/vault.pid)" -o pid,cmd
```

查看状态：现在 Vault 应处于 `Initialized=false` 且 `Sealed=true`：

```bash
vault status || true
```

> 退出码非零是正常现象：sealed 状态下 `vault status` 会以非 0 退出，但仍会打印状态信息。

执行一次性初始化，使用 1/1 Shamir 分片（仅适合教学；正式环境请采用更高的阈值或自动解封）：

```bash
vault operator init -key-shares=1 -key-threshold=1 -format=json > /root/init.json
cat /root/init.json
```

把 unseal key 与 root token 提取到环境变量：

```bash
export UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' /root/init.json)
export VAULT_TOKEN=$(jq -r '.root_token' /root/init.json)
echo "VAULT_TOKEN length: ${#VAULT_TOKEN}"
```

解封：

```bash
vault operator unseal "$UNSEAL_KEY"
```

再次确认状态。`Sealed` 应该变为 `false`，`HA Mode` 应为 `active`：

```bash
vault status
```

把 root token 持久化到 shell，方便后续步骤使用：

```bash
echo "export VAULT_TOKEN=${VAULT_TOKEN}" >> /etc/profile.d/vault.sh
```

读一下 raft 节点信息，确认存储后端确实生效：

```bash
vault operator raft list-peers
```

到这里你已经验证了：**没有配置文件就无法启动，配置文件中的 `storage` 与 `listener` 块决定数据落点与 API 入口**。
