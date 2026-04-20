# 第二步：编写生产风格 HCL 配置

Dev 模式（`vault server -dev`）使用内存存储、自动解封、Root Token 是 `root`，**绝不可用于生产**。本步骤我们手写一份生产风格的 HCL 配置，使用 Integrated Storage（Raft）作为存储后端。

## 2.1 创建配置文件

将下面的内容写入 `/etc/vault.d/vault.hcl`：

```bash
cat > /etc/vault.d/vault.hcl <<'EOF'
# 1. API 监听器
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true       # 实验环境关闭 TLS；生产中绝对要开启
}

# 2. 存储后端：Integrated Storage（基于 Raft 的内置存储）
storage "raft" {
  path    = "/opt/vault/data"
  node_id = "node-1"
}

# 3. 集群通信地址
api_addr     = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"

# 4. 启用 Web UI
ui = true

# 5. 关闭 mlock（仅用于无 swap 的容器/沙箱环境，生产环境配合系统配置）
disable_mlock = true
EOF

cat /etc/vault.d/vault.hcl
```

## 2.2 启动 Vault（后台运行）

注意：与 Dev 模式不同，启动后 Vault 处于 **Sealed**（封印）状态，必须手动初始化和解封后才能使用。

```bash
# 启动 vault server，日志写入 /var/log/vault.log
nohup vault server -config=/etc/vault.d/vault.hcl > /var/log/vault.log 2>&1 &

# 等待端口起来
sleep 3

# 查看启动日志的关键行
tail -20 /var/log/vault.log
```

## 2.3 检查 Vault 状态

```bash
vault status
```

你应该看到类似输出：

```
Key                Value
---                -----
Seal Type          shamir
Initialized        false
Sealed             true
Total Shares       0
Threshold          0
...
```

注意三个关键字段：

- `Initialized: false` — 集群从未初始化过，没有任何密钥材料
- `Sealed: true` — 处于封印状态，无法对外服务
- `Seal Type: shamir` — 使用 Shamir 算法切分 Unseal Key（生产推荐用 Auto-Unseal 对接云 KMS）

`vault status` 命令的退出码也很重要：`0` 表示已解封，`2` 表示已封印——这是健康检查脚本的标准信号。

完成后点击 **Continue** 进入下一步：初始化与解封。
