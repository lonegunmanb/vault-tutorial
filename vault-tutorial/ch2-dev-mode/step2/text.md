# 第二步：验证数据短暂性——重启即清零

这一步我们用最直接的方式证明 Dev 模式的内存存储不可靠：写入一条机密，然后重启服务器，看它消失。

## 2.1 写入一条"重要"机密

模拟一个真实场景：假设你的应用将数据库凭据存放在 Vault 中。

```bash
vault kv put secret/myapp/db \
  username="admin" \
  password="SuperSecret_Prod_2026!" \
  host="db.internal.example.com"

vault kv get secret/myapp/db
```

你应该能看到：

```
====== Secret Path ======
secret/data/myapp/db

======= Metadata =======
Key              Value
---              -----
created_time     2026-xx-xx...
version          1

====== Data ======
Key        Value
---        -----
host       db.internal.example.com
password   SuperSecret_Prod_2026!
username   admin
```

机密已成功存储。现在记住这些数据，我们来重启服务器。

## 2.2 重启 Dev 服务器——数据消失前的最后记录

```bash
# 记录当前机密版本数（期望值：1）
vault kv metadata get secret/myapp/db 2>/dev/null | grep "current_version"

# 终止当前 Dev 服务器进程
pkill -f "vault server" 2>/dev/null || true
echo "Dev 服务器已停止"
sleep 2

# 重新启动一个新的 Dev 服务器（注意：这是一个全新的内存实例）
vault server -dev -dev-root-token-id=root \
  > /tmp/vault-dev-2.log 2>&1 &
sleep 2
echo "新的 Dev 服务器已启动"
```

## 2.3 尝试读取刚才写入的机密

```bash
vault kv get secret/myapp/db
```

你会得到：

```
No value found at secret/data/myapp/db
```

注意：`secret/` 挂载点**依然存在**（Dev 模式每次启动都会自动重新挂载它），但挂载点下的所有数据已全部消失。这正是内存存储的本质——结构是代码写死的，数据是运行时产生的，进程一旦终止，数据荡然无存。

## 2.4 确认"一切归零"的程度

```bash
# 挂载点还在，但数据已空
vault secrets list

# 没有任何自定义策略（除了 root 和 default）
vault policy list
```

> **直面现实**：如果有人在生产环境中使用了 Dev 模式，一次服务器重启（内核升级、OOM Kill、部署更新）就会导致：
> - 所有存储的机密立即消失
> - 所有策略立即消失
> - 所有认证方法配置立即消失
> - 所有应用程序同时失去访问 Vault 的能力
> 
> 这不是理论风险，这是**确定性的灾难**。

## 2.5 清理：重新建立一个干净的 Dev 实例

我们为后续步骤重新准备好环境：

```bash
# Dev 服务器已经在运行，验证一下
vault status | grep "Sealed"

# KV v2 在新 Dev 实例中默认是挂载好的
vault kv put secret/test message="hello"
vault kv get secret/test
```

完成后点击 **Continue** 进入第三步。
