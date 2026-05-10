# 第一步：启用 file 审计设备并观察 JSON 行结构与 HMAC

## 1.1 启动并初始化 Vault

```bash
./start-vault.sh
sleep 3

vault operator init -key-shares=1 -key-threshold=1 \
  -format=json > /root/init-output.json

UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' /root/init-output.json)
ROOT_TOKEN=$(jq -r '.root_token' /root/init-output.json)

cat >> /etc/profile.d/vault.sh <<EOF
export UNSEAL_KEY='${UNSEAL_KEY}'
export VAULT_TOKEN='${ROOT_TOKEN}'
EOF
source /etc/profile.d/vault.sh

vault operator unseal "$UNSEAL_KEY"
```

## 1.2 启用一台 file 审计设备，写到 /var/log/vault/vault-audit.log

```bash
vault audit enable file \
  file_path=/var/log/vault/vault-audit.log
```

立即列出当前已启用的所有审计设备，确认 file 设备已挂载：

```bash
vault audit list -detailed
```

预期可以看到一行 `file/`，类型为 `file`，options 中包含 `file_path=/var/log/vault/vault-audit.log`。

## 1.3 触发若干次 API 操作，再看落盘内容

```bash
vault secrets enable -path=secret kv-v2 2>/dev/null || true
vault kv put secret/demo username=alice password=correct-horse-battery-staple
vault kv get secret/demo > /dev/null
vault token lookup > /dev/null
```

打开审计日志的最后 3 条记录，注意 **每一行都是一个独立 JSON 对象**：

```bash
tail -n 3 /var/log/vault/vault-audit.log | jq -c '{type, time, "request.path": .request.path, "request.id": .request.id}'
```

预期可看到形如 `{"type":"request","time":"...","request.path":"secret/data/demo","request.id":"..."}` 的结构化条目。每一次 API 调用都会产生一条 type=request 与一条 type=response，二者通过 request.id 配对。

## 1.4 验证敏感字段默认被 HMAC

```bash
tail -n 1 /var/log/vault/vault-audit.log \
  | jq '.auth | {client_token, accessor, display_name}'
```

预期 `client_token` 与 `accessor` 字段都以 `hmac-sha256:...` 字符串形式出现——这就是 8.1 节正文与 8.2 节正文反复强调的「字符串敏感字段默认走 HMAC-SHA256」行为。

## 1.5 这一步的核心闭环

学员已经亲手让一台 file 审计设备运行起来；并直接观察到逐行 JSON、`request.id` 配对、敏感字段 HMAC 这三个 8.1 / 8.2 节正文中的关键事实。下一步将在不影响 file 设备的前提下，**并行**再挂两台不同类型的设备，作横向对照。
