# 第一步：阅读基线 vault.hcl 并启动一个 HTTP 监听

先看一下预置的配置文件：

```bash
cat /root/vault.hcl
```

请重点关注 `listener "tcp"` 块。在本步骤中，它仍属于教学用的最弱配置——`tls_disable = true` 显式关闭了默认启用的 TLS，以便后续步骤能够从"明文 HTTP"基线出发，逐步将 TLS 收紧至生产强度。

> 6.2 节正文已强调：Vault 的 TCP listener 默认即启用 TLS 1.2/1.3，必须显式声明 `tls_disable = true` 才会回退为 HTTP；正式环境严禁采用此类配置。

以后台模式启动 Vault，并将日志写入 `/var/log/vault.log`：

```bash
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
sleep 2
cat /tmp/vault.pid
```

确认监听端口已处于 LISTEN 状态：

```bash
ss -lntp | grep ':8200' || true
```

完成初始化与解封（教学用 1/1 Shamir 分片；正式环境请采用更高阈值或 auto-unseal）：

```bash
vault operator init -key-shares=1 -key-threshold=1 -format=json > /root/init.json
export UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' /root/init.json)
export VAULT_TOKEN=$(jq -r '.root_token' /root/init.json)
vault operator unseal "$UNSEAL_KEY"
echo "export VAULT_TOKEN=${VAULT_TOKEN}" >> /etc/profile.d/vault.sh
```

确认 Vault 已处于 unsealed 且 active 状态：

```bash
vault status
```

最后通过 `curl` 直接验证当前 listener 采用的是**明文 HTTP**：

```bash
curl -s http://127.0.0.1:8200/v1/sys/health | jq .
```

至此，你已获得一个可用但**未加密**的 Vault；下一步将把它升级为 HTTPS。
