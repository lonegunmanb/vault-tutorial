# 第三步：用 elide_list_responses 与 SIGHUP 复现两类高频运维场景

## 3.1 启用第二台 file 设备，开启 elide_list_responses

为了不破坏第一台 file 设备的「原样记录」对照基线，再挂一台同类型设备，但这一次显式打开 LIST 响应省略选项：

```bash
vault audit enable -path=file-elided/ file \
  file_path=/var/log/vault/vault-audit.elided.log \
  elide_list_responses=true
```

## 3.2 触发 LIST 操作，对照两处文件中 keys 字段的差异

```bash
for n in alpha bravo charlie delta echo; do
  vault kv put secret/$n value="$n" > /dev/null
done
vault kv list secret/ > /dev/null
```

对照两份 file 设备的最后一条响应记录：

```bash
echo "=== 未省略：keys 字段是数组 ==="
grep '"type":"response"' /var/log/vault/vault-audit.log \
  | tail -n 1 | jq '.response.data.keys'

echo "=== 已省略：keys 字段被替换为整数计数 ==="
grep '"type":"response"' /var/log/vault/vault-audit.elided.log \
  | tail -n 1 | jq '.response.data.keys'
```

预期：未省略的那份 keys 字段是 `["alpha","bravo","charlie","delta","echo"]` 之类的数组；已省略的那份 keys 字段直接是数字 `5`。这正是 8.1 节与 8.2 节正文中关于 `elide_list_responses` 行为的事实。

## 3.3 复现 file 审计设备的日志轮转流程：mv + SIGHUP

外部日志轮转工具（例如 logrotate）的标准做法是：先把当前日志改名归档、再向 vault 进程发送 `SIGHUP`，让 file 设备关闭并重新打开自己底层的文件描述符。这里用一行 `mv` + `kill -HUP` 复现这一时序：

```bash
ls -la /var/log/vault/vault-audit.log
mv /var/log/vault/vault-audit.log /var/log/vault/vault-audit.log.1
echo "改名后 vault 仍持有旧 fd，新 vault-audit.log 此时不存在："
ls -la /var/log/vault/vault-audit.log 2>&1 | head -n1

VAULT_PID=$(cat /tmp/vault.pid)
kill -HUP "$VAULT_PID"
sleep 1

vault kv put secret/demo trigger=after-sighup > /dev/null

echo "SIGHUP 之后 vault 重新打开了文件描述符，新 vault-audit.log 已被创建并继续写入："
ls -la /var/log/vault/vault-audit.log
tail -n 1 /var/log/vault/vault-audit.log | jq -c '{type, "path": .request.path, "id": .request.id}'
```

预期可以看到：原始 `vault-audit.log` 被重命名为 `.1` 后，vault 在 `SIGHUP` 之后立刻在原路径重建一份新 `vault-audit.log`，并把后续审计记录平滑写入新文件——正是 `file` 审计设备配合 logrotate 的标准时序。

## 3.4 这一步的核心闭环

学员已经亲手观察到：

- `elide_list_responses=true` 把 LIST 响应里的 `keys` 字段替换成数字计数，显著降低单条审计记录体积；
- 在 `mv` 走当前日志后，向 vault 发送 `SIGHUP` 即可让 file 设备关闭并重新打开文件描述符，外部日志轮转工具据此就能完成无中断的日志切割。

至此，三类审计设备的关键可观察行为都在同一台 Vault 上完成了对照演示。
