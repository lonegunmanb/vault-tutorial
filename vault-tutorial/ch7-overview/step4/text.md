# 第四步：整理三栏对照表

请把前三步的观察结果填进下面这张三栏对照表中。在终端里也可以直接执行下方命令，把结果一次性打印到屏幕上，对照填写。

```bash
printf '\n=== 方式一：vault kv get ===\n'
echo "VAULT_TOKEN env  = $VAULT_TOKEN (前 8 位: ${VAULT_TOKEN:0:8})"
vault kv get -format=json secret/seven/app | jq '{request_id, lease_id, lease_duration, data: .data.data}'

printf '\n=== 方式二：Vault Agent 渲染 ===\n'
echo "agent token sink = /root/agent-token (前 8 位: $(cut -c 1-8 /root/agent-token))"
echo "agent rendered file = /root/agent-secret.txt"
cat /root/agent-secret.txt

printf '\n=== 方式三：Vault Proxy 代理 ===\n'
echo "proxy token sink = /root/proxy-token (前 8 位: $(cut -c 1-8 /root/proxy-token))"
echo "proxy listener   = http://127.0.0.1:8100"
VAULT_ADDR=http://127.0.0.1:8100 VAULT_TOKEN= vault kv get -format=json secret/seven/app | jq '{request_id, lease_id, lease_duration, data: .data.data}'
```

整理好的对照表如下，请逐栏与上面命令的输出对照确认：

| 维度 | 方式一：`vault kv get` | 方式二：Vault Agent 渲染 | 方式三：Vault Proxy 代理 |
| :--- | :--- | :--- | :--- |
| 认证主体 | 调用者自己持有的 token（本实验为 root） | Agent 通过 AppRole 自动取得的 Vault token | Proxy 通过 AppRole 自动取得的 Auto-auth token |
| 令牌存放位置 | 环境变量 `VAULT_TOKEN` | file sink：`/root/agent-token` | file sink：`/root/proxy-token`，并由 Proxy 进程内部使用 |
| 应用看到的机密形式 | CLI 标准输出 | 本地文件 `/root/agent-secret.txt`（按模板格式） | CLI 标准输出（请求实际由 Proxy 转发） |
| 应用是否需要管理 token | 是 | 否 | 否（请求即使不带 token 也会被 Proxy 强制附加 Auto-auth token） |
| 缓存归属 | 无 | Agent 维护 token 与租约的续期 | Proxy 维护 token 与租约的续期，并具备可缓存请求子集的能力 |

完成对照后，本实验的目标就达成了：你已经在同一台 Vault 上，亲手用三种方式取出同一条 KV 机密，并明确了三者在「谁来认证、token 放在哪里、机密以什么形式呈现给应用」这三个最关键维度上的差异。

后续 7.2、7.3、7.4 节会分别深入 Agent 模板、Agent 进程供给与 Proxy 部署拓扑；7.5 起则进入 Kubernetes 集成的三件套实战。本节建立的三栏心智模型是后续所有动手实验的共同锚点。
