# 第四步：终止 leader 进程触发重新选举并复测两条路径

本步通过强制终止当前 leader 进程，触发 Raft 重新选举，并验证：(a) 新 leader 在剩余 2 个节点中产生；(b) 步骤 2、步骤 3 中观察到的两条路径在新 leader 下依然成立。该过程将 6.6 节 §1 中"节点失活后由其余节点接替"的描述转化为一次可直接观察的事件。

## 4.1 定位当前 leader 进程并终止之

根据当前的 `${ACTIVE_PORT}` 推断对应节点编号（8200→1、8210→2、8220→3），并终止其进程：

```bash
case "${ACTIVE_PORT}" in
  8200) ACTIVE_NODE=1 ;;
  8210) ACTIVE_NODE=2 ;;
  8220) ACTIVE_NODE=3 ;;
esac
echo "当前 leader 为 node-${ACTIVE_NODE}，准备终止该进程"

kill "$(cat /tmp/vault-${ACTIVE_NODE}.pid)"
sleep 5
```

## 4.2 重新查 `sys/leader`，确认新 leader

剩下的两个节点中应当有且只有一个变为新的 active：

```bash
for port in 8200 8210 8220; do
  echo "=== node @ ${port} ==="
  curl -sS --max-time 2 "http://127.0.0.1:${port}/v1/sys/leader" \
    | jq '{is_self, leader_address}' || echo "(此节点已下线)"
done
```

被 kill 的节点会直接连接失败；剩下两个节点中，**新 leader** 的 `is_self: true`，**新 standby** 的 `leader_address` 已经更新为新 leader 的 `api_addr`。

把两个新角色记到环境变量里：

```bash
# 把 ACTIVE_PORT / STANDBY_PORT 重新指向当前真实的 active / standby。
# 例如新 leader 是 8210，新 standby 是 8220：
export ACTIVE_PORT=8210
export STANDBY_PORT=8220
```

> 实际值请按上一条 `curl` 的输出手动确认，不要照抄上面这个示例。

## 4.3 在新 leader 下复测请求转发路径

```bash
curl -i \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "http://127.0.0.1:${STANDBY_PORT}/v1/demo-kv/data/hello"
```

预期：`HTTP/1.1 200 OK`，响应体里依然是步骤 2 写入的 `message=written via active`——证明数据复制无损、新 leader 服务正常、standby 默认转发依旧生效。

## 4.4 在新 leader 下复测客户端重定向路径

```bash
curl -i \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "X-Vault-No-Request-Forwarding: 1" \
  "http://127.0.0.1:${STANDBY_PORT}/v1/demo-kv/data/hello"
```

预期：`HTTP/1.1 307 Temporary Redirect`，并且 `Location` 头里的地址正是**新 leader** 的 `api_addr`。这一变化从客户端视角验证了 standby 中保存的"当前活跃节点是谁"这一信息的确随选举结果发生了切换。

## 4.5 这一步的核心闭环

leader 失活后，Raft 在剩余 2 个 voter 节点中重新选出 active；新 standby 立刻能在 `sys/leader` 与 `307` 重定向的 `Location` 头中报告新的 active 地址；客户端无论走转发路径还是重定向路径都能继续读到原数据。至此，HA 模式正文中的全部核心概念已在终端中获得直接观察。
