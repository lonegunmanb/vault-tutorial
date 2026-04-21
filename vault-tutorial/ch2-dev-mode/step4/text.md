# 第四步：确立边界——Dev 模式的正确使用场合

经过前三步的实验，我们已经亲眼目睹了三个具体风险。现在我们用一个综合演练来总结"Dev 模式什么时候可以用，什么时候不能用"，并预览生产 Vault 的正确启动方式。

## 4.1 Root Token 的"公开性"验证

在现实的多用户系统中，`ps` 命令可以让任何用户看到所有进程的完整命令行参数：

```bash
# 任何用户都能运行这条命令
ps aux | grep "vault server"
```

输出中你会直接看到 `-dev-root-token-id=root`。这意味着：

1. 攻击者无需破解任何东西
2. 只需读取进程列表，Root Token 就触手可得
3. 控制了这个 Token = 控制了 Vault 的一切

```bash
# 验证：用"偷来"的 Token 读取任意机密
STOLEN_TOKEN="root"  # 从 ps 输出中得到

vault kv list secret/ --format=json \
  -header="X-Vault-Token: ${STOLEN_TOKEN}" 2>/dev/null \
  || VAULT_TOKEN="${STOLEN_TOKEN}" vault kv list secret/
```

## 4.2 `-dev-tls`：用 tcpdump 对比 TLS 加密效果

Vault 提供了 `-dev-tls` 变体——自动生成自签名 CA 和服务器证书，监听同一个 8200 端口但走 HTTPS。我们用它重复上一步的 tcpdump 实验，直接对比有无 TLS 时的抓包结果。

```bash
# 停止当前 Dev 实例
pkill -f "vault server" 2>/dev/null || true
sleep 2

# 启动 -dev-tls，日志里包含 VAULT_ADDR 和 VAULT_CACERT 路径
vault server -dev-tls -dev-root-token-id=root \
  > /tmp/vault-dev-tls.log 2>&1 &
sleep 3
```

从启动日志中提取环境变量：

```bash
eval $(grep -E 'export VAULT_(ADDR|CACERT)' /tmp/vault-dev-tls.log | sed 's/^[[:space:]]*\$[[:space:]]*//')
echo "VAULT_ADDR:   $VAULT_ADDR"
echo "VAULT_CACERT: $VAULT_CACERT"
```

再次抓包，然后执行与步骤 3.3 完全相同的写入/读取操作：

```bash
tcpdump -i lo -A -s 0 'tcp port 8200' > /tmp/vault-tls-traffic.cap 2>&1 &
TLS_PID=$!
sleep 1

vault kv put secret/tls-test value="sensitive-data-should-be-hidden"
vault kv get secret/tls-test

kill $TLS_PID
sleep 1
```

用步骤 3.4 中完全相同的关键词搜索抓包文件：

```bash
grep -ac "sensitive-data\|X-Vault-Token\|tls-test" /tmp/vault-tls-traffic.cap
```

输出应为 `0`——什么都找不到。流量依然在，只是 TLS 把它变成了只有通信双方才能解密的密文。

**`-dev-tls` 解决了明文传输问题，但仍然不适合生产，因为：**
- 自签名证书无法通过公开 PKI 链验证，应用需要显式信任该 CA
- 证书和私钥存储在临时目录，每次重启都重新生成，无法固定
- 存储后端仍是内存，数据不持久

清理并还原普通 dev 供后续步骤使用：

```bash
pkill -f "vault server" 2>/dev/null || true
rm -f /tmp/vault-tls-traffic.cap /tmp/vault-dev-tls.log
sleep 2

vault server -dev -dev-root-token-id=root \
  > /tmp/vault-dev.log 2>&1 &
sleep 2
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'
unset VAULT_CACERT
echo "已还原 Dev 模式（http://）"
```

## 4.3 正确使用 Dev 模式：CI Pipeline 示例

Dev 模式在以下场景中是**完全合理**的选择：

```bash
#!/bin/bash
# .github/workflows/test.yml 或 Makefile 中的 vault 集成测试片段

set -euo pipefail

# 在隔离容器内启动 dev 服务器
vault server -dev -dev-root-token-id=test-token \
  -dev-listen-address=127.0.0.1:8200 \
  > /dev/null 2>&1 &

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='test-token'

# 等待就绪
for i in $(seq 1 15); do
  vault status > /dev/null 2>&1 && break
  sleep 1
done

# 执行集成测试
vault kv put secret/config db_url="test://localhost/testdb"
./run-integration-tests.sh

# 容器销毁时所有数据随之消失，无需清理
```

关键要素：**隔离容器 + 已知 Token + 测试结束即销毁**。三个条件缺一不可，缺少任何一个都会让上面分析过的风险重新成立。

## 4.4 生产 Vault 的正确初始化流程预览

Dev 模式"short-circuit"了生产环境中每一个有意义的安全步骤：

| 步骤 | 生产环境 | Dev 模式 |
| :--- | :--- | :--- |
| 1. 配置文件 | 手动编写 HCL（listener / storage / seal） | 跳过，全部内置默认值 |
| 2. 初始化 | `vault operator init`，生成 5 个 Shamir 分片 | 自动完成 |
| 3. 解封 | 3 人各提供 1 个分片，`vault operator unseal` × 3 | 自动完成 |
| 4. 审计设备 | `vault audit enable file ...`（强制开启） | 未配置 |
| 5. 最小权限策略 | 创建细粒度 Policy，按需授权 | 只有 `root` + `default` |
| 6. 吊销 Root Token | 初始化后立即吊销，紧急时用 `operator generate-root` 重建 | 永久有效的 `root` |

```bash
# 验证：Dev 模式下 Root Token 永不过期，且拥有最高权限
vault token lookup | grep -E "expire_time|policies"
```

## 4.5 最终决策树

```bash
cat << 'DECISION_TREE'
你打算在哪里运行 Vault？

  ├─ 本地开发机，只有你在用，数据可以随时丢失
  │     └─> ✅ Dev 模式可以使用
  │
  ├─ CI/CD 容器（隔离、短暂、测试结束即销毁）
  │     └─> ✅ Dev 模式可以使用
  │
  ├─ 团队共享的开发服务器（多人访问）
  │     └─> ❌ 请使用生产模式（即使只是"开发用"）
  │
  ├─ 有任何数据需要在重启后保留
  │     └─> ❌ 内存存储不满足要求
  │
  ├─ 监听 0.0.0.0（对外暴露）
  │     └─> ❌ 无 TLS + 已知 Root Token = 立即被利用
  │
  └─ Staging / 生产 / 任何真实数据
        └─> ❌🚫 永远不允许
DECISION_TREE
```

完成后点击 **Continue** 进入总结。
