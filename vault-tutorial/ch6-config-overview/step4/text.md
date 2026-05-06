# 第四步：删除 disable_mlock 复现启动失败

第 6.1 节明确指出：当使用 integrated storage（`raft`）时，`disable_mlock` **必须**显式给出取值，否则 Vault 拒绝启动。本步骤通过故意删除该参数复现这一行为，帮助你记住这一前置条件。

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

尝试在前台启动，把启动失败的报错直接打印出来（不要加 `&`，这样错误一目了然）：

```bash
vault server -config=/root/vault.hcl 2>&1 | head -n 20 || true
```

你应能看到类似如下含义的报错：raft 存储要求显式设置 `disable_mlock`。Vault 不会启动，进程立即退出。

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
2. **某些顶层参数与所选存储后端强相关**——例如 raft 存储下，缺失 `disable_mlock` 就直接导致启动失败。

后续 6.2-6.9 节会基于这份骨架，进一步深入 listener、自动解封、Autopilot、遥测与高并发调优。
