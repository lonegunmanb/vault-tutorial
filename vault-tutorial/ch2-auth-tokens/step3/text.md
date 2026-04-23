# 第三步：Accessor 是单向引用

文档 §4.2 列出了 accessor 能做的 4 件事：

1. lookup token properties (但**拿不到 token 本身**)
2. lookup token capabilities on a path
3. renew the token
4. revoke the token

这一步把这 4 件事跑一遍，并验证"单向"的真实含义。

## 3.1 创建一个 token 并保留 accessor

```bash
RESP=$(vault token create -policy=default -ttl=1h -format=json)
JOB_TOKEN=$(echo "$RESP" | jq -r .auth.client_token)
JOB_ACCESSOR=$(echo "$RESP" | jq -r .auth.accessor)

echo "JOB_TOKEN=$JOB_TOKEN  (敏感，不应该到处存)"
echo "JOB_ACCESSOR=$JOB_ACCESSOR  (可以放心存)"
```

## 3.2 用 accessor 做 4 件事

**Lookup 属性**：

```bash
vault token lookup -accessor "$JOB_ACCESSOR"
```

注意输出里 `id` 字段的值是 `n/a`（普通 lookup 能看到真实 token ID）——
这就是文档说的 "not including the actual token ID"。

**Lookup capabilities**（需要通过 API，CLI 的 `vault token capabilities`
只接受 token ID，不接受 accessor）：

```bash
vault write sys/capabilities-accessor accessor="$JOB_ACCESSOR" paths='["sys/health"]'
```

**Renew**：

```bash
vault token renew -accessor "$JOB_ACCESSOR" -increment=2h
```

**Revoke**：

```bash
vault token revoke -accessor "$JOB_ACCESSOR"
```

确认 token 已死：

```bash
vault token lookup "$JOB_TOKEN" 2>&1 | tail -2
```

## 3.3 验证"单向"——accessor 拿不出 token

文档强调 "single direction"。验证一下：所有 accessor 相关的命令
都查不到 token 本身的字符串。

```bash
# 列出所有 accessor（这是 Vault 里"列 token"的唯一方式）
vault list auth/token/accessors | head -10
```

输出里只有 accessor 字符串，**没有任何一个 hvs.* token**。这正是
设计意图：调度系统、审计系统、运维平台都可以放心存 accessor，因为：

- 拿到 accessor → 能撤销关联的 token / 能查它的属性 → **足以应急响应**
- 拿到 accessor → **拿不到 token** → **不能用它去读密钥** → **不会扩大泄漏面**

## 3.4 实战场景小练习

模拟一个"调度系统给一批 job 派 token"的场景：

```bash
# 调度系统给 3 个 job 派 token，并按 job_id 存下 accessor
declare -A JOB_ACCESSORS
for job in job-001 job-002 job-003; do
  ACC=$(vault token create -policy=default -ttl=1h -format=json | jq -r .auth.accessor)
  JOB_ACCESSORS[$job]=$ACC
  echo "$job → $ACC"
done

# 假设 job-002 出问题了，调度系统要立刻吊销它的 token
echo "吊销 job-002..."
vault token revoke -accessor "${JOB_ACCESSORS[job-002]}"

# 其它 job 不受影响
echo "job-001 仍然有效:"
vault token lookup -accessor "${JOB_ACCESSORS[job-001]}" | grep ttl
echo "job-003 仍然有效:"
vault token lookup -accessor "${JOB_ACCESSORS[job-003]}" | grep ttl
```

**这一步的核心结论**：accessor 让"持有撤销权"和"持有访问权"被
彻底分离。这是 Vault 在最小机密暴露面方向上提供的一个非常优雅的
原语，配合 §2 的 token 树，构成了完整的"token 治理"工具集。
