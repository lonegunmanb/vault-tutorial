# 第四步：Periodic Token vs explicit_max_ttl

文档 §5.3 关于 periodic token 的核心论断：

> as long as the system is actively renewing this token — in other words,
> as long as the system is alive — the system is allowed to keep using
> the token.

§5.2 关于 explicit_max_ttl 的核心论断：

> This value becomes a hard limit on the token's lifetime — no matter
> what the values in (1), (2), and (3) from the general case are, the
> token cannot live past this explicitly-set value. **This has an effect
> even when using periodic tokens to escape the normal TTL mechanism.**

我们分别验证。

## 4.1 普通 token 是会撞天花板的

```bash
TOKEN_NORMAL=$(vault token create -ttl=30s -format=json | jq -r .auth.client_token)
vault token lookup "$TOKEN_NORMAL" | grep -E "ttl|explicit_max_ttl|period"
```

注意 `period` = `0`，`explicit_max_ttl` = `0` —— 走 §5.1 的"一般情况"。

试图续命 1 小时：

```bash
vault token renew -increment=3600 "$TOKEN_NORMAL"
```

返回的 `token_duration` 不会真的是 3600，会被挂载点 / 系统 max_ttl 顶住
（dev 模式默认 32 天，所以这次能给到 3600）。重点不在这次能不能续到，
重点是：**它有一个动态计算的天花板，每次续约都重新算**。

## 4.2 Periodic Token 的"无限续命"

创建一个 period=30s 的 periodic token：

```bash
PERIODIC=$(vault token create -period=30s -format=json | jq -r .auth.client_token)
vault token lookup "$PERIODIC" | grep -E "ttl|period|explicit_max_ttl"
```

注意：

- `period` = `30s`
- `ttl` = `30s` （初始值 = period）
- `explicit_max_ttl` = `0`（无硬天花板）

等 20 秒后续约：

```bash
sleep 20
vault token renew "$PERIODIC"
vault token lookup "$PERIODIC" | grep -E "ttl|period"
```

`ttl` 重新被顶回 `30s`。这就是 periodic 的本质——**每次续约都重置
回 period，没有累积上限**。

如果你愿意，可以多续几轮观察"它真的能一直续下去"：

```bash
for i in 1 2 3; do
  sleep 20
  echo "--- 第 $i 次续约 ---"
  vault token renew "$PERIODIC" | grep duration
done
```

**生产含义**：长跑 daemon 用 period=1h 的 token，每 30 分钟续一次，
就能"应用还活着 token 就活着、应用挂了 1 小时内 token 自己消失"。

## 4.3 explicit_max_ttl 是硬天花板，连 periodic 都压得住

创建一个 period=30s **但** explicit_max_ttl=1m 的 token：

```bash
CAPPED=$(vault token create -period=30s -explicit-max-ttl=1m -format=json | jq -r .auth.client_token)
vault token lookup "$CAPPED" | grep -E "ttl|period|explicit_max_ttl|expire_time"
```

注意 `expire_time` —— 这是一个**在签发时就锁定的过期时刻**，从那一刻起 60 秒后该 token 必然失效。

试图续命：

```bash
sleep 20 && vault token renew -increment=3600 "$CAPPED" | grep duration
sleep 20 && vault token renew -increment=3600 "$CAPPED" | grep duration
```

第一次续约能给到 ~40s（剩余到 explicit_max_ttl 的距离），第二次只能
给到 ~20s——**单调递减，趋近 0**。

继续等到 `expire_time` 之后：

```bash
sleep 30 && vault token lookup "$CAPPED" 2>&1 | tail -2
```

应该看到 `bad token` —— 即使是 periodic token，**也无法超过
explicit_max_ttl**。这是文档原话强调的："This has an effect even when
using periodic tokens to escape the normal TTL mechanism."

## 4.4 选型小结

| 场景 | 推荐配置 |
| --- | --- |
| 一次性短任务（CI job） | 普通 ttl，用完不续 |
| 中等寿命的 service account | ttl + 合理的 max_ttl |
| 长跑 daemon（数据库连接池等） | periodic + 合理的 explicit_max_ttl |
| 应急用的 root token | `operator generate-root` 临时签，用完立即 revoke |

`explicit_max_ttl` 几乎总是建议带上——它是**最后一道安全闸门**，无论
应用代码错误还是恶意续约都无法绕过。
