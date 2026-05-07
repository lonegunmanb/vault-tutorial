# 第一步：阅读基线 vault.hcl 并启动一个 HTTP 监听

先看一下预置的配置文件：

```bash
cat /root/vault.hcl
```

请重点关注 `listener "tcp"` 块。本步骤中它仍然是教学用的最弱配置——`tls_disable = true` 把默认启用的 TLS 显式关掉，让本节后续步骤可以从一个"裸 HTTP"基线一步步把 TLS 收紧到生产强度。

> 6.2 节正文已强调：Vault 的 TCP listener 默认就启用 TLS 1.2/1.3，必须显式 `tls_disable = true` 才会回退为 HTTP；正式环境绝对不应这样配置。

启动 Vault（后台模式，日志写到 `/var/log/vault.log`）：

```bash
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
sleep 2
cat /tmp/vault.pid
```

确认监听端口已经处于 LISTEN 状态：

```bash
ss -lntp | grep ':8200' || true
```

完成初始化与解封（教学用 1/1 Shamir，正式环境请使用更高阈值或 auto-unseal）：

```bash
vault operator init -key-shares=1 -key-threshold=1 -format=json > /root/init.json
export UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' /root/init.json)
export VAULT_TOKEN=$(jq -r '.root_token' /root/init.json)
vault operator unseal "$UNSEAL_KEY"
echo "export VAULT_TOKEN=${VAULT_TOKEN}" >> /etc/profile.d/vault.sh
```

确认 Vault 已经 unsealed 且为 active：

```bash
vault status
```

最后用 `curl` 直接证明当前 listener 走的是**明文 HTTP**：

```bash
curl -s http://127.0.0.1:8200/v1/sys/health | jq .
```

到这里你已经获得了一个可用但**未加密**的 Vault；下一步会把它升级为 HTTPS。
