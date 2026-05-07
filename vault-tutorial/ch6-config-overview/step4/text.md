# 第四步：观察省略 disable_mlock 后的 mlock 行为

第 6.1 节强调：当使用 integrated storage（`raft`）时，通常应显式设置 `disable_mlock = true`，因为 `mlock` 与 Raft 底层使用的 BoltDB 内存映射文件配合得不好，可能导致整个数据集被常驻内存。本步骤故意省略该参数，观察当前 Vault 版本的默认行为：服务可能仍能启动，但会回退为启用 `mlock`。

先停掉当前正在运行的 Vault：

```bash
kill -TERM "$(cat /tmp/vault.pid)"
sleep 2
ps -p "$(cat /tmp/vault.pid)" -o pid,cmd 2>/dev/null || echo "Vault stopped."
```

把配置文件中的 `disable_mlock` 这一行注释掉，模拟运维人员遗漏该项：

```bash
cp /root/vault.hcl /root/vault.hcl.bak
sed -i 's/^disable_mlock/# disable_mlock/' /root/vault.hcl
grep -n 'disable_mlock' /root/vault.hcl
```

短暂在前台启动一次，只观察配置摘要中的 `Mlock` 行。这里使用 `timeout`，避免服务长期占用当前终端：

```bash
timeout 4s vault server -config=/root/vault.hcl 2>&1 | sed -n '1,24p' || true
```

在当前实验使用的 Vault 版本中，你应能看到类似 `Mlock: supported: true, enabled: true` 的配置摘要。这说明省略 `disable_mlock` 后，Vault 并不会自动采用推荐的 raft 行为，而是会尝试启用 `mlock`。如果运行环境没有相应权限，或者数据集增长较大，这个默认值就可能带来启动或内存占用问题。

恢复配置：

```bash
cp /root/vault.hcl.bak /root/vault.hcl
grep '^disable_mlock' /root/vault.hcl
```

重新在后台启动，并确认服务恢复：

```bash
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
sleep 2
vault operator unseal "$(jq -r '.unseal_keys_b64[0]' /root/init.json)"
vault status
```

到这里你已经从两个角度理解了本节的核心要点：

1. **配置文件由顶层标量参数与命名块组成**，缺一不可；`storage` 与 `listener` 是必填项。
2. **某些顶层参数与所选存储后端强相关**——例如 raft 存储下，建议显式写出 `disable_mlock = true`，避免 Vault 回退到启用 `mlock` 的默认行为。

后续 6.2-6.9 节会基于这份骨架，进一步深入 listener、自动解封、Autopilot、遥测与高并发调优。
