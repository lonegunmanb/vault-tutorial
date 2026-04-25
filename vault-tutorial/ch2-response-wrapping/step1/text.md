# 第一步：基础包装与一次性拆封

文档的核心论断：

> Vault can take the response it would have sent to an HTTP client and
> instead insert it into the cubbyhole of a single-use token, returning
> that single-use token instead.

先用 KV v2 来体会"包装 → 拆封 → 再拆就报错"的完整链路。

## 1.1 写一条测试数据

```bash
vault kv put secret/db-cred username="app_user" password="P@ssw0rd-2026"
```

正常读一次，确认明文可见：

```bash
vault kv get secret/db-cred
```

输出里 `password` 清清楚楚地显示着 `P@ssw0rd-2026`——这就是**不加
wrapping 时的默认行为**。想象一下这条命令的输出被写进了某个日志系统
或 CI 管道的标准输出——密码就泄了。

## 1.2 用 `-wrap-ttl` 包装响应

```bash
vault kv get -wrap-ttl=120s secret/db-cred
```

注意输出**完全不同了**——不再有 `username` / `password`，而是：

```
Key                              Value
---                              -----
wrapping_token:                  hvs.CAES...
wrapping_accessor:               ...
wrapping_token_ttl:              2m
wrapping_token_creation_time:    2026-...
wrapping_token_creation_path:    secret/data/db-cred
```

**关键字段**：

- `wrapping_token`：这就是"密封快递单号"——拿它去 unwrap；
- `wrapping_token_creation_path`：触发包装的原始请求路径，接收方可以
  用它验证数据确实来自 `secret/data/db-cred`；
- `wrapping_token_ttl`：120 秒后自动销毁。

把 wrapping token 抓出来供后续使用：

```bash
WRAP_TOKEN=$(vault kv get -wrap-ttl=120s -format=json secret/db-cred | jq -r .wrap_info.token)
echo "wrapping token = $WRAP_TOKEN"
```

## 1.3 拆封——第一次成功

```bash
echo "第一次 unwrap（应该成功，看到原始数据）:"
vault unwrap $WRAP_TOKEN
```

输出里会还原出完整的 KV 数据：`username=app_user`、`password=P@ssw0rd-2026`。

## 1.4 拆封——第二次失败

```bash
echo ""
echo "第二次 unwrap（应该失败——token 已被消耗）:"
vault unwrap $WRAP_TOKEN 2>&1 | tail -3
```

报错信息类似：`wrapping token is not valid or does not exist`。

**仔细体会**：wrapping token 是**一次性的**，拆完即销毁。如果你发现
自己拿到的 token 拆不开——要么超时了，要么**有人已经提前拆过了**。
第二种情况就是 response wrapping 提供的"防篡改 / 截获检测"机制。

## 1.5 包装任意自定义数据：`sys/wrapping/wrap`

不止 KV——任何你想传递的数据都能包装：

```bash
CUSTOM_WRAP=$(vault write -wrap-ttl=60s -format=json \
  sys/wrapping/wrap \
  tls_key="-----BEGIN PRIVATE KEY-----MIIEv...假装很长..." \
  cert_chain="-----BEGIN CERTIFICATE-----也很长..." \
  | jq -r .wrap_info.token)

echo "自定义数据的 wrapping token = $CUSTOM_WRAP"

echo ""
echo "拆封自定义数据:"
vault unwrap $CUSTOM_WRAP
```

`sys/wrapping/wrap` 是一个"回声"端点——把你传给它的数据原封不动地
包进 wrapping token 里。**任何需要安全传递的一次性数据都可以用它**。

**这一步的核心结论**：

| 现象 | 原因 |
| --- | --- |
| 加 `-wrap-ttl` 后看不到原始数据 | Vault 把数据塞进了一次性 token 的 cubbyhole |
| 第一次 unwrap 成功 | token 有效，cubbyhole 里有数据 |
| 第二次 unwrap 失败 | token 在第一次 unwrap 后已被吊销 |
| `sys/wrapping/wrap` 能包装任意 KV 对 | 它是通用的"密封快递"端点 |
