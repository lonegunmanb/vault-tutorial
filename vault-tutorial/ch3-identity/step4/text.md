# 第四步：force-identity-deduplication 激活与不可逆语义

[3.6 §5](/ch3-identity) 介绍了 1.19+ 的去重激活机制：

- 旧版 Vault 的 bug 可能在持久化存储里留下重复 entity / alias / group
- 1.19+ 在 unseal 阶段会**主动检测**并打日志
- 提供一个**一次性、永远不可逆**的开关
  `sys/activation-flags/force-identity-deduplication/activate` 来彻
  底强制去重

我们的 Dev 模式 Vault 是干净的（没有任何旧版本残留的重复），但在
§4.5 的 Hands-on 实验里我们会**故意用 `sys/raw` 往存储层注入一个
重复 entity**，亲眼观察检测与去重的完整流程。

## 4.0 这个开关到底解决了什么问题？

先用两张图张图把"问题 → 解决方案 → 新保障"全讲清楚——后面 §4.1 ~ §4.5
就是亲手跑第二张图里的每一格：

![dedup-problem](../assets/dedup-problem.png)
![dedup-upgrade](../assets/dedup-upgrade.png)

> **两层不可逆一句话总结**：启用新打印机 = "最终出售、不退不换"
> （**开关不可逆**）；新打印机开机那一刻把两张证合并成一张，碎掉
> 的那张再也拼不回来（**合并不可逆**）。所以文档反复强调：推开关
> 之前先确认每一组重复确实该合并——合错了也没有"撤销 merge"。

下面 §4.1 ~ §4.5 就是亲手把图里每一格跑一遍。

Dev 模式 Vault 的日志在 `/var/log/vault-dev.log`：

```bash
grep -E "post-unseal setup starting|post-unseal setup complete|DUPLICATES DETECTED" /var/log/vault-dev.log
```

你会看到 setup starting → setup complete 两行夹着一段日志，**没有**
`DUPLICATES DETECTED` 一行——这意味着当前集群干净，可以直接进 §5.1
第 5 步激活。

> 在生产里：如果这里看到了 `DUPLICATES DETECTED`，**绝对不要**直接激
> 活。先按 [official deduplication 文档](https://developer.hashicorp.com/vault/docs/secrets/identity/deduplication)
> 第 2-3 步把重复手工解决，再来第 5 步。激活前还存在的重复不会被自
> 动 merge。

## 4.2 看一眼当前 activation flags 状态

```bash
vault read sys/activation-flags
```

应该看到 `activated` 列表为空：

```
Key          Value
---          -----
activated    []
```

## 4.3 激活——启用新打印机（最终出售、不退不换）

```bash
vault write -f sys/activation-flags/force-identity-deduplication/activate
```

激活成功——相当于把旧打印机退役、换上了新的。再看一次状态：

```bash
vault read sys/activation-flags
```

`force-identity-deduplication` 应该已经出现在 `activated` 列表里：

```
Key          Value
---          -----
activated    [force-identity-deduplication]
```

## 4.4 验证"不退不换"

再激活一次：

```bash
vault write -f sys/activation-flags/force-identity-deduplication/activate
```

Vault 不会报错，但后台不再做任何事情——新打印机已经在位，再按一
次按钮只是 no-op。更重要的是**不存在 `deactivate` 接口**——吊牌
上写的"最终出售、不退不换"名副其实。

这就是**两层不可逆**：
1. **开关不可逆**——新打印机回不去老的，该集群从此 unseal 都跑查重
2. **合并不可逆**——激活那一刻碎掉的重复 entity 再也拼不回来，想拆
   只能手动新建 entity + 重绑 alias（新 ID 和历史审计/token 全对不
   上号）

## 4.5 亲手制造重复 entity 并观察去重（Hands-on Dedup 实验）

前面 §4.3 ~ §4.4 在一个干净的 Dev 模式里演示了"开关本身"的语义。
现在我们要更进一步：**故意在存储层注入一个同名 entity**，然后亲眼看
到 Vault 在 unseal 阶段如何检测、激活 flag 后又如何强制处理它。

> ⚠️ 这个实验需要重启 Vault 以启用 `raw_storage_endpoint`（给
> `sys/raw` API 开后门直接操作底层存储）。Dev 模式重启会丢失前面
> 所有步骤的数据——没关系，实验是自包含的。

### 为什么要用 sys/raw？

Vault 1.19+ 的 API 层**已经堵死了**重复 entity / alias 的创建入口。
历史上的重复数据都是旧版 bug 在存储层留下的。要在干净的 1.19 环境
里复现，唯一的办法就是**绕过 API、直接往存储里写**——这正是
`sys/raw` 的用途。

> Vault 自己的回归测试也是同一个套路：源码里有一个 `testonly` build
> tag 下的 `identity_store_injector_testonly.go`，专门提供
> `identity/duplicate/entities` 等端点向存储里注入重复数据。我们用
> `sys/raw` + 一段 Python 脚本达到同样的效果。

### 4.5.1 重启 Vault，启用 sys/raw

```bash
# 先杀掉当前 Dev Vault
VAULT_PID=$(pgrep -f "vault server -dev")
[ -n "$VAULT_PID" ] && kill -INT $VAULT_PID && sleep 2

# 写一个最小配置，只开 raw_storage_endpoint
cat > /tmp/vault-raw.hcl << 'EOF'
raw_storage_endpoint = true
EOF

# 用 -config 把它合并进 Dev 模式
nohup vault server -dev \
  -dev-root-token-id=root \
  -dev-listen-address=0.0.0.0:8200 \
  -config=/tmp/vault-raw.hcl \
  > /var/log/vault-dev.log 2>&1 &

# 等就绪
for i in $(seq 1 20); do
  if vault status > /dev/null 2>&1; then echo "Vault is ready."; break; fi
  sleep 1
done

# 提取 unseal key（Dev 模式只有 1 把，seal/unseal 要用到它）
UNSEAL_KEY=$(grep "Unseal Key:" /var/log/vault-dev.log | head -1 | awk '{print $NF}')
echo "UNSEAL_KEY=$UNSEAL_KEY"
```

验证 sys/raw 可用：

```bash
vault list sys/raw/logical/
```

如果返回了一组 UUID 前缀的路径，说明 `raw_storage_endpoint` 生效了。

### 4.5.2 准备一个正常的 entity "bob"

```bash
# 开一个 userpass 做 alias 挂点
vault auth enable userpass

BOB_EID=$(vault write -format=json identity/entity \
  name="bob" metadata=team="ops" \
  | jq -r .data.id)
echo "BOB_EID=$BOB_EID"

USERPASS_ACC=$(vault auth list -format=json | jq -r '."userpass/".accessor')
vault write identity/entity-alias \
  name="bob" canonical_id="$BOB_EID" mount_accessor="$USERPASS_ACC"

# 确认 API 层只有一个 bob
vault list identity/entity/name
```

### 4.5.3 用 Python 往存储里注入一个同名 "bob"

下面这段脚本：

1. 查 identity/ 引擎的 mount UUID → 拼出 sys/raw 路径前缀
2. 在 256 个 storagepacker bucket 里找一个**空槽位**
3. 生成一个 UUID 使其 `md5[0]` 恰好映射到该空槽位
4. 用 protobuf wire format 手工编码一个 `Bucket → Item → Any → Entity`
5. 把它写进 sys/raw

由于写的是空槽位，不需要读/解压已有的 Snappy 数据——**零外部依赖**。

```bash
cat > /tmp/inject-dup.py << 'PYEOF'
#!/usr/bin/env python3
"""inject-dup.py — 往 Vault identity 存储里注入一个同名 entity"""
import hashlib, uuid, base64, json, os
from urllib.request import Request, urlopen
from urllib.error import HTTPError

VAULT_ADDR = os.environ.get("VAULT_ADDR", "http://127.0.0.1:8200")
VAULT_TOKEN = os.environ.get("VAULT_TOKEN", "root")

def vault(method, path, data=None):
    url = f"{VAULT_ADDR}/v1/{path}"
    body = json.dumps(data).encode() if data else None
    req = Request(url, data=body, method=method)
    req.add_header("X-Vault-Token", VAULT_TOKEN)
    if body:
        req.add_header("Content-Type", "application/json")
    try:
        with urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except HTTPError as e:
        print(f"  ✗ HTTP {e.code}: {e.read().decode()[:200]}")
        raise

def vault_list(path):
    try:
        return vault("LIST", path).get("data", {}).get("keys", [])
    except HTTPError:
        return []

# ── protobuf wire-format helpers（无需 protobuf 库）──
def _varint(v):
    buf = bytearray()
    while v > 0x7F:
        buf.append((v & 0x7F) | 0x80); v >>= 7
    buf.append(v & 0x7F)
    return bytes(buf)

def _str(field, s):
    d = s.encode()
    return _varint((field << 3) | 2) + _varint(len(d)) + d

def _bytes(field, b):
    return _varint((field << 3) | 2) + _varint(len(b)) + b

# ── 1. 找到 identity/ 引擎的 mount UUID ──
print("[1/5] 查 identity mount UUID …")
mounts = vault("GET", "sys/mounts")
identity_uuid = mounts["data"]["identity/"]["uuid"]
raw_base = f"sys/raw/logical/{identity_uuid}"
print(f"      UUID = {identity_uuid}")

# ── 2. 列出已有的 entity packer buckets ──
print(f"[2/5] 列出 entity buckets …")
buckets = vault_list(f"{raw_base}/packer/buckets/")
occupied = {b.rstrip("/") for b in buckets}
print(f"      已占用 {len(occupied)} 个 bucket: {sorted(occupied)[:10]}…")

# ── 3. 找一个空槽位，生成映射到该槽位的 UUID ──
print("[3/5] 找空槽位 & 生成 UUID …")
target = next(i for i in range(256) if str(i) not in occupied)
while True:
    cand = str(uuid.uuid4())
    if hashlib.md5(cand.encode()).digest()[0] == target:
        dup_id = cand; break
bucket_key = f"packer/buckets/{target}"
print(f"      空槽位: {target}  UUID: {dup_id}")

# ── 4. 手工编码 protobuf ──
print("[4/5] 编码 protobuf …")
# Entity { id=2, name=3, bucket_key=9, namespace_id=12 }
entity_pb = (_str(2, dup_id) + _str(3, "bob")
             + _str(9, bucket_key) + _str(12, "root"))
# google.protobuf.Any { type_url=1, value=2 }
any_pb = (_str(1, "type.googleapis.com/identity.Entity")
          + _bytes(2, entity_pb))
# storagepacker.Item { id=1, message=2 }
item_pb = _str(1, dup_id) + _bytes(2, any_pb)
# storagepacker.Bucket { key=1, items=2 }
bucket_pb = _str(1, bucket_key) + _bytes(2, item_pb)

# ── 5. 写入 sys/raw ──
b64 = base64.b64encode(bucket_pb).decode()
print(f"[5/5] 写入 {raw_base}/{bucket_key} ({len(bucket_pb)} bytes) …")
vault("PUT", f"{raw_base}/{bucket_key}", {"value": b64})
print(f"      ✅ 同名 entity 'bob' (id={dup_id}) 已注入存储！")
PYEOF

python3 /tmp/inject-dup.py
```

> **发生了什么？** 现在 Vault 的物理存储里有**两个**叫 `bob` 的
> entity，但 MemDB（内存索引）里只有 API 创建的那一个。两者不一致
> ——这正是旧版 bug 留下的典型现场。要让 Vault "看见"存储里的脏
> 数据，需要走一次 **seal → unseal** 触发 post-unseal 全量加载。

### 4.5.4 Phase 1：seal/unseal → 观察 DUPLICATES DETECTED

**此时 flag 尚未激活**——Vault 只报警、不动手：

```bash
vault operator seal
vault operator unseal "$UNSEAL_KEY"
```

看日志：

```bash
grep -i "duplicate" /var/log/vault-dev.log
```

你应该看到类似这样的输出：

```
[WARN]  identity: DUPLICATES DETECTED: ...
```

这就是 1.19+ 在 unseal 阶段的**主动检测**——它扫描了所有 storagepacker
bucket，发现两个 entity 叫同一个名字 `bob`，于是打了一条 WARN。

但因为 `force-identity-deduplication` **尚未激活**，Vault 不会自动
处理——它只是告诉你"这里有脏数据，请先手工确认再激活"。

> 这对应生产里的正确流程：先看报告、确认每组重复确实该合并，再推开关。

### 4.5.5 Phase 2：激活 flag → 再次 seal/unseal → 观察自动去重

```bash
# 激活开关（不可逆！）
vault write -f sys/activation-flags/force-identity-deduplication/activate

# 确认激活
vault read sys/activation-flags
```

再走一次 seal/unseal：

```bash
vault operator seal
vault operator unseal "$UNSEAL_KEY"
```

看日志：

```bash
grep -iE "duplicate|deduplic|renaming" /var/log/vault-dev.log
```

你应该看到 Vault 这次**动手了**——对于同名 entity，它的处理方式是
**重命名**：保留先创建的 `bob`，把后来的那个改名为 `bob-<uuid>`，
并给被改名的 entity 打上 `duplicate_of_canonical_id` 元数据指向原
始 entity。

> 注意：同名 entity 的处理是**重命名**（rename），不是合并（merge）。
> 真正的 **merge** 只发生在**同名 alias**（同一个 mount_accessor +
> name 指向不同 entity）的场景——那种情况下，两个 entity 会被合并
> 成一个，多余的被删除。

### 4.5.6 验证去重结果

```bash
# 列出所有 entity name——应该有两个：bob 和 bob-<uuid>
vault list identity/entity/name

# 看原始 bob 的详情
vault read identity/entity/name/bob
```

被重命名的 entity 名字会变成 `bob-<uuid>` 格式。根据
[官方文档](https://developer.hashicorp.com/vault/docs/secrets/identity/deduplication/entity-group)，
rename 操作**不删数据、不新增权限**，保留原 entity 的所有关联。

> 源码层面（`identity_store_conflicts.go`）还会给被重命名的 entity
> 写入 `duplicate_of_canonical_id` 之类的内部元数据，但这属于实现细节，
> 官方文档未承诺其稳定性，不建议依赖。

这就是**新打印机**的完整工作流程：
1. **检测**（unseal 时扫描存储）
2. **报警**（flag 未激活时只打 WARN 日志）
3. **处理**（flag 激活后自动 rename / merge）
4. **持续保障**（此后每次 unseal 都重复 1-3）

## 4.6 总结：老打印机 vs 新打印机

| 维度 | 老打印机（激活前） | 新打印机（激活后） |
| --- | --- | --- |
| 重复 entity / alias / group | 可能存在（旧版 bug 造成） | 第一次开机就自动处理 |
| 同名 entity 怎么处理 | 不处理，只打 WARN 日志 | **重命名**为 `name-<uuid>` |
| 同名 alias（同 mount+name） | 不处理，只打 WARN 日志 | **合并**两个 entity 为一个 |
| 未来出现新重复 | 可能（并发竞态 + 残留 bug） | 每次开机自动查重，发现即处理 |
| 退回老打印机 | — | **不行，最终出售、不退不换** |
| 撤销已处理的重复 | — | **不行，rename/merge 都不可逆** |

---

> 进入 Finish 总结。
