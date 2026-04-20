# 第三步：管理密钥版本

KV v2 支持密钥版本管理，每次更新都会保留历史版本。

更新密钥（会创建新版本）：

```bash
vault kv put secret/myapp/config \
  username="admin" \
  password="n3wP@ssw0rd"
```

查看所有版本的元数据：

```bash
vault kv metadata get secret/myapp/config
```

读取特定版本：

```bash
vault kv get -version=1 secret/myapp/config
```

删除当前版本（软删除，可恢复）：

```bash
vault kv delete secret/myapp/config
```

恢复被删除的版本：

```bash
vault kv undelete -versions=2 secret/myapp/config
```

永久销毁某个版本：

```bash
vault kv destroy -versions=1 secret/myapp/config
```
