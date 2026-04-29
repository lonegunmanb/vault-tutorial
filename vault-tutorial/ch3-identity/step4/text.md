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

### 为什么要绕过 API？

Vault 1.19+ 的 API 层**已经堵死了**重复 entity / alias 的创建入口。
历史上的重复数据都是旧版 bug 在存储层留下的。要在干净的 1.19 环境
里复现，唯一的办法就是**绕过 API、直接改存储**——这正是
`sys/raw` + Snappy 解压/重压的用途。

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

### 4.5.2 安装 Snappy 解压库

Vault 的 storagepacker 用 Snappy 压缩存储数据，后面的注入脚本需要
解压/重压：

```bash
apt-get install -y -qq libsnappy-dev > /dev/null 2>&1
pip install --quiet --break-system-packages python-snappy
```

### 4.5.3 准备两个正常的 entity

我们用 API 正常创建两个 entity：`bob`（目标名字）和 `boc`（同长度
的"替身"，一会儿在存储层被偷偷改名成 `bob`）：

```bash
vault auth enable userpass

BOB_EID=$(vault write -format=json identity/entity \
  name="bob" metadata=team="ops" \
  | jq -r .data.id)
echo "BOB_EID=$BOB_EID"

BOC_EID=$(vault write -format=json identity/entity \
  name="boc" metadata=team="ops" \
  | jq -r .data.id)
echo "BOC_EID=$BOC_EID"

# 确认 API 层有 bob 和 boc 两个不同名 entity
vault list identity/entity/name
```

### 4.5.4 用 Python 把 "boc" 在存储层偷偷改名成 "bob"

思路：通过 `sys/raw` 读出 `boc` 所在的 storagepacker bucket（Snappy
压缩的 protobuf），解压 → 把字节 `boc` 替换成 `bob`（同长度，
protobuf 的 length 字段不受影响）→ 重新压缩写回。这样完全不需要
我们自己编码 protobuf——只做一次同长度字节替换。

> 为什么 `boc→bob` 替换是安全的？因为 `o` 不是十六进制字符
> `[0-9a-f]`，所以 `boc` 不可能出现在 UUID、accessor 等十六进制值
> 里；也不会出现在 protobuf type_url、bucket key 等固定字符串里。
> 被替换的**只有** entity name 这一个字段。

```bash
cat > /tmp/inject-dup.py << 'PYEOF'
#!/usr/bin/env python3
"""inject-dup.py — 在存储层把 boc 改名为 bob，制造同名重复 entity"""
import hashlib, base64, json, os, subprocess
import snappy

def vault_json(*args):
    """调用 vault CLI 并返回解析后的 JSON"""
    r = subprocess.run(
        ["vault"] + list(args) + ["-format=json"],
        capture_output=True, text=True,
        env={**os.environ, "VAULT_ADDR": "http://127.0.0.1:8200", "VAULT_TOKEN": "root"},
    )
    if r.returncode != 0:
        raise RuntimeError(f"vault {' '.join(args)} failed:\n{r.stderr}")
    return json.loads(r.stdout)

CANARY_SNAPPY = 0x53  # compressutil 的 Snappy 标志字节 'S'

# ── 1. 找到 identity/ 引擎的 mount UUID ──
print("[1/4] 查 identity mount UUID …")
mounts = vault_json("read", "sys/mounts")
identity_uuid = mounts["data"]["identity/"]["uuid"]
raw_base = f"sys/raw/logical/{identity_uuid}"
print(f"      UUID = {identity_uuid}")

# ── 2. 计算 boc 所在 bucket 并读出原始字节 ──
boc_eid = os.environ["BOC_EID"]
bucket_idx = hashlib.md5(boc_eid.encode()).digest()[0]
bucket_path = f"{raw_base}/packer/buckets/{bucket_idx}"
print(f"[2/4] boc (EID={boc_eid[:8]}…) 在 bucket {bucket_idx}")
print(f"      读取 {bucket_path} …")

raw_resp = vault_json("read", bucket_path, "encoding=base64")
raw_bytes = base64.b64decode(raw_resp["data"]["value"])
print(f"      原始字节: {len(raw_bytes)} B, 首字节: 0x{raw_bytes[0]:02x}")

# ── 3. 解压 → 替换 → 重新压缩 ──
print("[3/4] Snappy 解压 → boc→bob 替换 → 重新压缩 …")
if raw_bytes[0] == CANARY_SNAPPY:
    proto_bytes = snappy.decompress(raw_bytes[1:])
else:
    proto_bytes = raw_bytes

count = proto_bytes.count(b"boc")
assert count >= 1, f"在 protobuf 里没找到 'boc'，bucket 识别有误？"
print(f"      找到 {count} 处 'boc'，全部替换为 'bob'")
modified = proto_bytes.replace(b"boc", b"bob")

recompressed = bytes([CANARY_SNAPPY]) + snappy.compress(modified)
new_b64 = base64.b64encode(recompressed).decode()

# ── 4. 写回（用 vault write 避免 HTTP 编码问题）──
print(f"[4/4] 写回 {bucket_path} …")
r = subprocess.run(
    ["vault", "write", bucket_path, f"value={new_b64}"],
    capture_output=True, text=True,
    env={**os.environ, "VAULT_ADDR": "http://127.0.0.1:8200", "VAULT_TOKEN": "root"},
)
if r.returncode != 0:
    raise RuntimeError(f"写回失败:\n{r.stderr}")
print(f"      ✅ 存储里现在有两个叫 'bob' 的 entity：")
print(f"         原始 bob = {os.environ.get('BOB_EID','(见上方)')}")
print(f"         伪造 bob = {boc_eid} (原名 boc)")
PYEOF

export BOB_EID BOC_EID
python3 /tmp/inject-dup.py
```

> **发生了什么？** 现在 Vault 的物理存储里有**两个**叫 `bob` 的
> entity，但 MemDB（内存索引）里还是一个 `bob` 一个 `boc`。两者不
> 一致——这正是旧版 bug 留下的典型现场。要让 Vault "看见"存储里
> 的脏数据，需要走一次 **seal → unseal** 触发 post-unseal 全量加载。

### 4.5.5 Phase 1：seal/unseal → 观察 DUPLICATES DETECTED

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

### 4.5.6 Phase 2：激活 flag → 再次 seal/unseal → 观察自动去重

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

### 4.5.7 验证去重结果

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
