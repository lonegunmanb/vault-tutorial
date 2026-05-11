# 第 1 步：启动 Gin 应用，亲眼看到数据库里只有密文

本步要把『加密即服务』的核心闭环——「应用送明文 → Vault 返密文 → 应用只把密文写进 PostgreSQL → 取出密文 → Vault 返明文」——在终端里完整地走一遍。

---

## 1.1 检查后台已经准备好的环境

`transit/` 引擎与 `transit/keys/payments` 密钥已经在后台创建好（见实验说明）。先确认一下：

```bash
vault read transit/keys/payments
```

预期输出中关键字段：`name = payments`、`type = aes256-gcm96`、`latest_version = 1`、`min_decryption_version = 1`、`deletion_allowed = true`。这两个版本号字段会在第 2 步密钥轮转中变化，先记住它们的初始值。

PostgreSQL 容器与表也已经建好：

```bash
psql -c '\d payments'
```

预期会列出 4 个列：id、name、cc_info（VARCHAR(255)）、created_at。这与官方仓库 [`schema.sql`](https://github.com/hashicorp-education/learn-vault-spring-cloud/blob/main/vault-transit/src/main/resources/schema.sql) 一一对应。

确认一下表是空的：

```bash
psql -c 'SELECT count(*) FROM payments;'
```

预期：`count = 0`。

## 1.2 看一眼 Gin 应用做了什么

应用源码已经准备在 `/root/eaas-app/app.go`，可在编辑器面板里打开浏览，或在终端里直接看：

```bash
sed -n '1,30p' /root/eaas-app/app.go
```

只需要记住三件事——它们与官方 Java 版本（[`VaultTransitApplication.java`](https://github.com/hashicorp-education/learn-vault-spring-cloud/blob/main/vault-transit/src/main/java/com/hashicorp/vaulttransit/VaultTransitApplication.java)）的对外行为是完全一致的：

1. 应用通过两个环境变量与 Vault 通信：`VAULT_ADDR` 与 `VAULT_TOKEN`；通过 `DATABASE_URL` 与 PostgreSQL 通信；
2. 写入接口 `POST /payments` 接收 `{"name":"...","cc_info":"..."}`（客户端不传 id，由服务器生成 UUID）；cc_info 不会被原样存入数据库——它会先被发到 transit/encrypt/payments，把返回的 ciphertext（形如 `vault:v1:...`）写进 payments.cc_info 列；
3. 读取接口 `GET /payments` 反过来：从数据库取出每条记录后，把 cc_info 列里的密文发到 transit/decrypt/payments，再把还原出来的明文随其余字段一并返回。

> **官方实现的一点小特例**：`POST /payments` 在 Java 版本与本节 Go 版本中都返回**包含刚插入这一条记录的数组**，而该数组里的 `cc_info` 字段返回的是『刚刚落库的密文』本身，**不会**再经一次解密——这是官方的真实行为，本节如实保留，便于学员一眼看到刚才落库的密文长什么样。1.4 节验证这一点。

## 1.3 启动应用

应用已经预先编译好了，直接运行二进制：

```bash
cd /root/eaas-app
nohup ./app > app.log 2>&1 &
echo $! > app.pid
sleep 2
tail -n 5 app.log
```

预期最后一行类似 `[GIN-debug] Listening and serving HTTP on :8080`。如果看到 `bind: address already in use`，说明上一次实验留下了残余进程，执行 `pkill -x app` 后再重新启动即可。

## 1.4 写入一笔支付记录，注意返回值里的 `cc_info` 是密文

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"name":"Test Customer","cc_info":"4242424242424242"}' \
  http://127.0.0.1:8080/payments
echo
```

预期返回（id、createdAt、cc_info 的具体字节每次都不一样，UUID 随机、时间戳与 GCM nonce 都会变化）：

```json
[{"id":"e67ee875-fb66-4135-95d6-2f0bfa185e5e","name":"Test Customer","cc_info":"vault:v1:NNFKub3wEVQj4SVS9cM7KP0F9CL/aVQA0mfdqZ0LpohVHX9VeWPQwej3vVk=","createdAt":"2026-05-11T08:29:16.486125315Z"}]
```

注意整体是一个**数组**（包含刚插入这一条记录），且数组里的 `cc_info` 字段是 `vault:v1:...` 形式的密文——这就是 1.2 节末尾那条小特例所说的『POST 返回的是落库的密文本身』。

## 1.5 直接打开 PostgreSQL 表，亲眼看到落库的就是密文

```bash
psql -c 'SELECT id, name, cc_info FROM payments;'
```

预期：

```
                  id                  |     name      |                                cc_info
--------------------------------------+---------------+-----------------------------------------------------------------------
 e67ee875-fb66-4135-95d6-2f0bfa185e5e | Test Customer | vault:v1:NNFKub3wEVQj4SVS9cM7KP0F9CL/aVQA0mfdqZ0LpohVHX9VeWPQwej3vVk=
(1 row)
```

注意 `cc_info` 列里**完全没有** `4242424242424242` 这个明文卡号。这就是『应用持密文』在数据库层面的直接体现——拿到这份数据库的人，没有 Vault 与正确的 Token，是无论如何也读不出明文卡号的。

为了把这一点说得更死，可以再做一次明文检索：

```bash
psql -t -c "SELECT count(*) FROM payments WHERE cc_info LIKE '%4242%';"
```

预期：`0`——任意一条记录的 `cc_info` 列里都搜不到原始卡号的任何子串。

## 1.6 通过 `GET /payments` 读出明文

```bash
curl -s http://127.0.0.1:8080/payments
echo
```

预期：

```json
[{"id":"e67ee875-fb66-4135-95d6-2f0bfa185e5e","name":"Test Customer","cc_info":"4242424242424242","createdAt":"2026-05-11T08:29:16.486125Z"}]
```

应用内部完成的工作是：从 PostgreSQL 取出每条记录 → 通过 `X-Vault-Token` 头把每条记录的 `cc_info` 发给 `transit/decrypt/payments` → 把 Vault 返回的 base64 明文解码 → 拼装成 JSON 返回。整个过程中**应用进程本身从来没有保管过任何长效密钥**，它只在每个请求里向 Vault 借一次解密能力。

可以再写一笔记录、再 `GET /payments` 一次，确认列表里两条都正常解密：

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"name":"Another Customer","cc_info":"5555555555554444"}' \
  http://127.0.0.1:8080/payments | head -c 200; echo
curl -s http://127.0.0.1:8080/payments
echo
```

---

## ✅ 验收

- [ ] `vault read transit/keys/payments` 显示 `latest_version = 1`、`deletion_allowed = true`
- [ ] `POST /payments` 返回的数组里 `cc_info` 字段以 `vault:v1:` 开头
- [ ] `psql -c 'SELECT id, name, cc_info FROM payments;'` 看到 `cc_info` 列存的就是 `vault:v1:...`，且 `LIKE '%4242%'` 搜不到任何记录
- [ ] `GET /payments` 能成功还原 `"cc_info":"4242424242424242"`

下一步将演示密钥轮转后老密文如何继续可读、新写入如何自动用新版本、以及如何用 `rewrap` 把存量密文整体升级到新版本——而这一切**全程不会暴露明文**。
