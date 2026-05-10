# 第二步：并行启用 syslog 与 unix-socket 审计设备并对照

## 2.1 启用 syslog 审计设备（写本机 rsyslog 的 local0 facility）

```bash
vault audit enable -path=syslog/ syslog \
  facility=LOCAL0 tag=vault-audit
```

`facility=LOCAL0` 与背景脚本中预置的 rsyslog 规则 `local0.* /var/log/vault/vault-audit.syslog` 对接，因此投递到 syslog 的审计记录会进入这份独立文件，便于直接观察。

## 2.2 启动一个 Unix Socket 监听器，再启用 socket 审计设备指向它

为了演示 `socket` 设备最稳妥的形态——本机 Unix Socket，先用 `socat` 在 `/tmp/vault-audit.sock` 上起一个简单监听器，把收到的内容写到本地文件：

```bash
nohup socat -u UNIX-LISTEN:/tmp/vault-audit.sock,fork,mode=666 \
  OPEN:/var/log/vault/vault-audit.socket,creat,append \
  > /var/log/socat.log 2>&1 &
sleep 1

vault audit enable -path=socket/ socket \
  address=/tmp/vault-audit.sock socket_type=unix
```

> 这里刻意选择 `socket_type=unix` 而非 TCP/UDP，因为正文已强调 UDP 会静默丢包、TCP 在对端不可达时可能反过来拖累 Vault；本机 Unix Socket 是 socket 设备最适合演示且最稳的形态。

确认三台审计设备同时在线：

```bash
vault audit list -detailed
```

预期看到 file/、syslog/、socket/ 三行。

## 2.3 触发同一组操作，并对照三处目的地的产物

```bash
vault kv put secret/demo username=alice password=second-write
vault kv get secret/demo > /dev/null
```

**对照三处的最后一条记录**：

```bash
echo "=== file 审计设备 ==="
tail -n 1 /var/log/vault/vault-audit.log | jq -c '{type, "path": .request.path, "id": .request.id}'

echo "=== syslog 审计设备（经 rsyslog → 文件） ==="
tail -n 1 /var/log/vault/vault-audit.syslog | grep -oE '\{.*\}' | head -n1 \
  | jq -c '{type, "path": .request.path, "id": .request.id}'

echo "=== socket 审计设备（经 socat → 文件） ==="
tail -n 1 /var/log/vault/vault-audit.socket | jq -c '{type, "path": .request.path, "id": .request.id}'
```

预期三处末尾输出的 `request.id` **完全相同**。这正是 8.1 节正文中的关键结论：「Vault 把同一条审计记录扇出（fan-out）给所有已启用的审计设备」。

## 2.4 验证 Vault 的「至少写出去一份」可用性约定

故意杀掉 `socat` 模拟 socket 对端宕机（同时让 file 与 syslog 仍在线）：

```bash
pkill -f "socat -u UNIX-LISTEN:/tmp/vault-audit.sock"
sleep 1
```

再触发一次写操作；因为 file 与 syslog 仍能写入，Vault 会照常处理：

```bash
vault kv put secret/demo username=alice password=after-socat-killed
echo "Vault 仍正常响应，因为 file 与 syslog 仍能写出去这条审计记录。"
```

将 `socat` 重新拉起来以便后续步骤继续观察：

```bash
nohup socat -u UNIX-LISTEN:/tmp/vault-audit.sock,fork,mode=666 \
  OPEN:/var/log/vault/vault-audit.socket,creat,append \
  > /var/log/socat.log 2>&1 &
sleep 1
```

## 2.5 这一步的核心闭环

学员已经在同一台 Vault 上把三种类型的审计设备并行挂起，亲手看到同一次 API 调用在三个目的地产生 `request.id` 完全相同的审计记录；并通过故意杀掉 socket 对端，验证了「只要还有任意一台设备能写入，Vault 业务请求继续被服务」这一可用性规则。下一步将通过 `elide_list_responses` 与 `SIGHUP` 复现两类高频运维场景。
