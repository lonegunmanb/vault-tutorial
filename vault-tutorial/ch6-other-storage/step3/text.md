# 第三步：postgresql 后端 — 手工建表 + 直接观察密文行

[6.5 节 §5](/ch6-other-storage) 已经强调：**PostgreSQL 后端不会自动创建表**，这是它与 DynamoDB 后端最显著的运维差异。本步严格按官方文档给出的 schema 手工建表、启动 Vault、写入数据，最后到 PostgreSQL 表里 `SELECT` 出加密后的字节，亲手验证"密文落在哪里"。

## 3.1 拉起一个本地 PostgreSQL

```bash
./start-postgres.sh
```

该脚本使用 docker 启动 `postgres:16-alpine`，监听 `127.0.0.1:5432`，预创建用户 `vault`、密码 `vaultpw`、库名 `vault`。它会等待 PostgreSQL 接受连接后再退出。

确认 PostgreSQL 可用：

```bash
PGPASSWORD=vaultpw psql -h 127.0.0.1 -U vault -d vault -c '\dt'
```

输出应是 "Did not find any relations"——库是空的。

## 3.2 按官方文档手工执行 `CREATE TABLE`

直接运行预置的 schema SQL（与 6.5 节正文中给出的 SQL 完全一致）：

```bash
PGPASSWORD=vaultpw psql -h 127.0.0.1 -U vault -d vault -f /root/vault-pg-schema.sql
PGPASSWORD=vaultpw psql -h 127.0.0.1 -U vault -d vault -c '\dt'
```

第二条命令应输出一张名为 `vault_kv_store` 的表。

> 本步**没有**创建 `vault_ha_locks` 表——本实验未启用 `ha_enabled`，因此用不到锁表。如果配置中打开了 `ha_enabled = "true"`，就必须按 6.5 节 §5.2 给出的第二段 SQL 再创建一次锁表，否则启动会因为找不到锁表而报错。

## 3.3 切换到 postgresql 后端启动 Vault

```bash
cat /root/vault-pg.hcl
./start-vault.sh pg
sleep 3
vault status || true
```

注意配置中的：

```hcl
storage "postgresql" {
  connection_url = "postgres://vault:vaultpw@127.0.0.1:5432/vault?sslmode=disable"
  table          = "vault_kv_store"
}
```

`sslmode=disable` 与 6.5 节正文里的提示对应：**默认会尝试 SSL 连接，本实验数据库未启 SSL，因此显式关掉**；生产环境应使用 `sslmode=verify-full` 配合真实 CA。

初始化并解封：

```bash
vault operator init -key-shares=1 -key-threshold=1 \
  -format=json > /root/init-pg.json

vault operator unseal "$(jq -r '.unseal_keys_b64[0]' /root/init-pg.json)"
export VAULT_TOKEN=$(jq -r '.root_token' /root/init-pg.json)
```

写入一条机密：

```bash
vault secrets enable -path=secret kv-v2
vault kv put secret/demo storage=postgresql note="written-via-pg-backend"
vault kv get secret/demo
```

## 3.4 直接到 PostgreSQL 表里观察密文行

到 PostgreSQL 里直接看 `vault_kv_store` 行数：

```bash
PGPASSWORD=vaultpw psql -h 127.0.0.1 -U vault -d vault \
  -c 'SELECT count(*) FROM vault_kv_store;'
```

行数应是几十甚至上百——Vault 把内部状态、policy、token、KV 数据全部以"路径 + key"的方式拍平到了这张表。

挑一行看 `parent_path` / `path` / `key` 字段（注意 `value` 是 BYTEA，直接 SELECT 出来会很长，先只取头几个字节）：

```bash
PGPASSWORD=vaultpw psql -h 127.0.0.1 -U vault -d vault -c "
SELECT parent_path, path, key, octet_length(value) AS bytes,
       encode(substring(value FROM 1 FOR 16), 'hex') AS first_16_bytes_hex
FROM vault_kv_store
ORDER BY parent_path
LIMIT 10;
"
```

可以看到 `value` 列的每一行都是不可读的字节，且 `first_16_bytes_hex` 显示的全是看上去随机的十六进制——**这正是 Vault 加密屏障在外部存储后端上的物化表现**：PostgreSQL 数据库里能看到的只是密文，没有 unseal key 即使拿到这张表的完整副本也无法还原任何机密内容。

## 3.5 重启进程，确认 PostgreSQL 后端持久化生效

```bash
pkill -f 'vault server'
sleep 2
./start-vault.sh pg
sleep 3

vault operator unseal "$(jq -r '.unseal_keys_b64[0]' /root/init-pg.json)"
export VAULT_TOKEN=$(jq -r '.root_token' /root/init-pg.json)

vault kv get secret/demo
```

数据仍然能读出来——与 step1 的 filesystem 后端一致，PostgreSQL 后端也是真正的持久化后端，与 step2 的 in-memory 形成鲜明对比。
