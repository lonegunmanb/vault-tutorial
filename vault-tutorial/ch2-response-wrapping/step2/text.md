# 第二步：lookup 检查与 creation_path 验证

文档建议的验证流程：

> Perform a lookup on the response-wrapping token. ... validate that the
> creation path matches expectations.

接收方在 unwrap **之前**，应该先做 lookup 验证——这一步**不消耗
token**，可以反复调。

## 2.1 生成一个新的 wrapping token

```bash
WRAP_TOKEN=$(vault kv get -wrap-ttl=120s -format=json secret/db-cred | jq -r .wrap_info.token)
echo "wrapping token = $WRAP_TOKEN"
```

## 2.2 用 lookup 检查 wrapping token

```bash
echo "lookup wrapping token（不消耗 token）:"
vault write sys/wrapping/lookup token=$WRAP_TOKEN
```

输出包含：

- `creation_path` — 应该是 `secret/data/db-cred`
- `creation_time` — token 创建时间
- `ttl` — 剩余有效秒数

## 2.3 验证 creation_path 的安全意义

假设你期望收到的是来自 `secret/data/db-cred` 的凭据。如果 lookup 返
回的 `creation_path` 是 `sys/wrapping/wrap` 或 `cubbyhole/response`
——这意味着**有人先拆封了原始数据，然后用 `sys/wrapping/wrap` 重新
包装成了一个"假"wrapping token 传给你**。

演示这个攻击场景——模拟中间人截获并重新包装：

```bash
# 中间人：先 unwrap 原始 token
STOLEN_DATA=$(vault unwrap -format=json $WRAP_TOKEN | jq -r .data)
echo "中间人偷到的数据: $STOLEN_DATA"
```

中间人拿到了真数据后，想伪装没发生过，用 `sys/wrapping/wrap` 重新
包装一份传给你：

```bash
FAKE_WRAP=$(vault write -wrap-ttl=120s -format=json \
  sys/wrapping/wrap \
  username="app_user" \
  password="P@ssw0rd-2026" \
  | jq -r .wrap_info.token)

echo ""
echo "中间人伪造的 wrapping token = $FAKE_WRAP"
```

现在你（接收方）拿到了这个"假"token，先做 lookup：

```bash
echo ""
echo "接收方对假 token 做 lookup:"
vault write sys/wrapping/lookup token=$FAKE_WRAP
```

注意 `creation_path` —— 输出是 `sys/wrapping/wrap`，**不是**你期望的
`secret/data/db-cred`！

```bash
echo ""
echo "对比：真正的 wrapping token creation_path 应该是 secret/data/db-cred"
echo "实际看到的 creation_path 是 sys/wrapping/wrap → 数据来源不对！"
echo "→ 应立即触发安全事件调查"
```

**这就是 creation_path 验证的价值：即使中间人完美复制了数据内容，
路径来源也会出卖它。**

## 2.4 lookup 不消耗 token——可以反复查

```bash
# 用刚才那个 FAKE_WRAP 演示 lookup 可以多次调用
echo "第一次 lookup:"
vault write -format=json sys/wrapping/lookup token=$FAKE_WRAP | jq .data.creation_path

echo "第二次 lookup（仍然有效）:"
vault write -format=json sys/wrapping/lookup token=$FAKE_WRAP | jq .data.creation_path

echo ""
echo "现在 unwrap 它:"
vault unwrap $FAKE_WRAP > /dev/null

echo ""
echo "unwrap 之后再 lookup（应该失败——token 已被消耗）:"
vault write sys/wrapping/lookup token=$FAKE_WRAP 2>&1 | tail -3
```

lookup 只读不写——可以反复调用验证状态。但 unwrap 之后 token 就不
存在了，lookup 也会报错。

## 2.5 用 accessor 做 lookup（不暴露 token ID）

如果调度方只想查看 wrapping token 的状态但不想持有 token 本身
（避免自己能拆封），可以只传 accessor：

```bash
WRAP_JSON=$(vault kv get -wrap-ttl=120s -format=json secret/db-cred)
WRAP_TOKEN2=$(echo $WRAP_JSON | jq -r .wrap_info.token)
WRAP_ACC=$(echo $WRAP_JSON | jq -r .wrap_info.accessor)

echo "wrapping token   = $WRAP_TOKEN2"
echo "wrapping accessor = $WRAP_ACC"

echo ""
echo "用 accessor 查状态（只能看状态，不能拆封）:"
vault token lookup -accessor $WRAP_ACC | grep -E "creation_path|expire_time|policies"
```

**这一步的核心结论**：

| 操作 | 消耗 token？ | 用途 |
| --- | --- | --- |
| `sys/wrapping/lookup` | 否 | 拆封前验证 creation_path、TTL |
| `vault unwrap` | **是** | 拆封取数据 |
| `vault token lookup -accessor` | 否 | 用 accessor 远程监控 token 状态 |

| 验证要点 | 正常 | 异常 |
| --- | --- | --- |
| token 有效性 | lookup 成功 | lookup 失败 → 已被拆过或过期 |
| creation_path | 匹配预期路径 | 不匹配 → 可能被中间人重新包装 |
| TTL | 在合理范围内 | 远长于预期 → 可能被 rewrap 过 |
