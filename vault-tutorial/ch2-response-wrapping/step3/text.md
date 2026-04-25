# 第三步：TTL 过期自动销毁与 rewrap 续命

文档原话：

> The response-wrapping token has a lifetime that is separate from the
> wrapped secret, and often can be much shorter.

wrapping token 的 TTL 由调用方指定，**与被包装数据本身的 TTL 完全独
立**。这一步验证两个性质：过期销毁 和 rewrap 续命。

## 3.1 极短 TTL——5 秒后自动销毁

```bash
SHORT_WRAP=$(vault kv get -wrap-ttl=5s -format=json secret/db-cred | jq -r .wrap_info.token)
echo "wrapping token (TTL=5s) = $SHORT_WRAP"

echo ""
echo "立刻 lookup（应成功）:"
vault write -format=json sys/wrapping/lookup token=$SHORT_WRAP | jq .data.creation_path
```

等待 6 秒后再尝试：

```bash
echo ""
echo "等待 6 秒让 token 过期..."
sleep 6

echo ""
echo "过期后 lookup（应失败）:"
vault write sys/wrapping/lookup token=$SHORT_WRAP 2>&1 | tail -3

echo ""
echo "过期后 unwrap（同样失败）:"
vault unwrap $SHORT_WRAP 2>&1 | tail -3
```

两个都失败——token 过期后被自动吊销，cubbyhole 里的数据一并销毁。
**没有人能恢复这些数据——包括 root token 也不行**。

**这就是 TTL 的安全意义**：即使 wrapping token 在传输中被截获，只要
攻击者没有在极短窗口内拆封，token 就自动失效。

## 3.2 rewrap：不拆封就续命

有些场景下，wrapping token 需要传递较长时间（例如跨时区的团队间传
递），但你不想一开始就设很长的 TTL。`sys/wrapping/rewrap` 允许
**不拆封数据**的情况下，用旧 token 换一个新 token（新 TTL）。

```bash
# 先生成一个 TTL=30s 的 wrapping token
WRAP_A=$(vault kv get -wrap-ttl=30s -format=json secret/db-cred | jq -r .wrap_info.token)
echo "原始 wrapping token (A) = $WRAP_A"

echo ""
echo "lookup A 的 creation_path:"
vault write -format=json sys/wrapping/lookup token=$WRAP_A | jq .data.creation_path
```

rewrap 换一个新 token：

```bash
WRAP_B=$(vault write -wrap-ttl=120s -format=json sys/wrapping/rewrap token=$WRAP_A | jq -r .wrap_info.token)
echo ""
echo "rewrap 后新 token (B) = $WRAP_B"
```

验证旧 token 已失效：

```bash
echo ""
echo "旧 token A 已失效:"
vault unwrap $WRAP_A 2>&1 | tail -3
```

验证新 token 可以正常拆封：

```bash
echo ""
echo "新 token B 正常拆封:"
vault unwrap $WRAP_B
```

## 3.3 rewrap 的安全注意事项

```bash
# rewrap 后 creation_path 仍然保持原始路径
WRAP_C=$(vault kv get -wrap-ttl=60s -format=json secret/db-cred | jq -r .wrap_info.token)
WRAP_D=$(vault write -wrap-ttl=60s -format=json sys/wrapping/rewrap token=$WRAP_C | jq -r .wrap_info.token)

echo "rewrap 后 lookup creation_path:"
vault write -format=json sys/wrapping/lookup token=$WRAP_D | jq .data.creation_path
```

注意——rewrap 后新 token 的 `creation_path` **仍然是原始的
`secret/data/db-cred`**，不会变成 `sys/wrapping/rewrap`。

这意味着 rewrap 操作对接收方是透明的——接收方仍然可以通过
`creation_path` 验证数据来源，无需感知中间是否经过了 rewrap。

## 3.4 TTL 选择建议

| 场景 | 建议 TTL | 原因 |
| --- | --- | --- |
| CI/CD 管道内部传递 | 30s ~ 60s | Runner 几秒内就启动并消费 |
| 运维人员传给远程服务器 | 2m ~ 5m | SSH 登录 + 手动操作需要时间 |
| 跨团队/跨时区传递 | 先设短 TTL + rewrap | 避免长 TTL 的暴露窗口 |
| 长期托管（合规场景） | rewrap 定期轮转 | CA 根密钥等需长期保管但定期验证 |

**这一步的核心结论**：

| 现象 | 原因 |
| --- | --- |
| TTL 过期后 unwrap 失败 | token 自动吊销，cubbyhole 数据销毁 |
| rewrap 旧 token 失效，新 token 可用 | 数据从旧 cubbyhole 迁移到新 cubbyhole |
| rewrap 后 creation_path 变了 | 新 token 的创建路径是 `sys/wrapping/rewrap` |
| 任何人（包括 root）都恢复不了过期的数据 | cubbyhole 随 token 一起被不可逆地销毁 |
