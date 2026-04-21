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

## 4.2 `-dev-tls` 模式——略好但仍不够

Vault 提供了一个稍微安全一点的 Dev 变体：

```bash
# 停止当前 Dev 实例
pkill -f "vault server" 2>/dev/null || true
sleep 2

# 启动带 TLS 的 Dev 模式
vault server -dev-tls -dev-root-token-id=root \
  > /tmp/vault-dev-tls.log 2>&1 &
sleep 3

# 查看启动日志
grep -E "VAULT_ADDR|CA cert|certificate" /tmp/vault-dev-tls.log | head -10
```

`-dev-tls` 自动生成自签名 CA 和服务器证书，并提示 `VAULT_ADDR=https://...`。与纯 HTTP 相比，流量是加密的。

**但它仍然不适合生产，因为：**
- 自签名证书无法通过公开 PKI 链验证（浏览器和标准工具会报错）
- 证书和私钥存储在临时目录，每次重启都重新生成
- 存储后端仍是内存，数据仍然不持久

```bash
# 停止 -dev-tls 实例，恢复普通 dev
pkill -f "vault server" 2>/dev/null || true
sleep 2
vault server -dev -dev-root-token-id=root \
  > /tmp/vault-dev.log 2>&1 &
sleep 2
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'
```

## 4.3 正确使用 Dev 模式：CI Pipeline 示例

Dev 模式在以下场景中是**完全合理**的选择：

```bash
# 模拟 CI 环境中的使用方式
cat << 'SCRIPT'
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
SCRIPT

echo "以上是 CI pipeline 中安全使用 Dev 模式的标准模板"
echo "关键要素：隔离容器 + 已知 Token + 测试结束即销毁"
```

## 4.4 生产 Vault 的正确初始化流程预览

对比一下生产 Vault 的启动流程，理解 Dev 模式"short-circuit"了多少步骤：

```bash
echo "=== 生产 Vault 启动清单（对比 Dev 模式）==="
echo ""
echo "生产步骤                              Dev 模式"
echo "──────────────────────────────────────────────────────"
echo "1. 准备 HCL 配置文件              ← vault server -dev"
echo "   (listener/storage/seal 等)        (全部自动化/跳过)"
echo ""
echo "2. vault operator init              ← 自动完成"
echo "   (生成 5 个 Shamir 分片)"
echo "   (输出 Root Token 一次)"
echo ""
echo "3. vault operator unseal (×3)       ← 自动完成"
echo "   (三个不同人员各提供一个分片)"
echo ""
echo "4. 配置审计设备                     ← 未配置"
echo "   vault audit enable file ..."
echo ""
echo "5. 创建细粒度策略                   ← 只有 root + default"
echo "   (最小权限原则)"
echo ""
echo "6. 吊销初始 Root Token              ← 永远有效的 'root'"
echo "   (只在紧急时使用 operator generate-root)"
```

```bash
# 实际验证：Root Token 在 Dev 模式下永不过期
vault token lookup | grep -E "expire_time|policies"
# expire_time: n/a  ← 永不过期
# policies: [root]  ← 最高权限
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
