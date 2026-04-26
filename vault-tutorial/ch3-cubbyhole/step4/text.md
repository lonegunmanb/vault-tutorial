# 第四步：拆开 Response Wrapping 黑箱——`vault read cubbyhole/response`

[2.7 Response Wrapping](/ch2-response-wrapping) 那一节给的"黑箱"描述
是：

> Vault 把响应包起来，只交出一个 wrapping token，拆封即作废。

这一步用 cubbyhole 把"包起来"这三个字字面拆开——它就是把响应**写到
了一个新建一次性 token 的 `cubbyhole/response` 路径里**。

## 4.1 准备一份要被 wrap 的真实数据

挂一个 KV v2、写一条数据：

```bash
vault secrets enable -path=kv -version=2 kv
vault kv put kv/db password=s3cret
```

正常读一下，确认它就在那儿：

```bash
vault kv get kv/db
```

## 4.2 用 `-wrap-ttl=` 把读取动作"包"起来

```bash
WRAP=$(vault kv get -wrap-ttl=5m -format=json kv/db | jq -r .wrap_info.token)
echo "WRAP=$WRAP"
```

**关键**：返回里**没有真实的 password**——只有一个 wrapping token。
真实响应去哪儿了？等下我们就直接挖出来。

如果再走一遍 §4.1 的 `vault kv get` 看看正常路径——数据本体仍在
KV，wrap 操作没有破坏它，只是"另开一份带寿命的副本"塞进了某个
cubbyhole。

## 4.3 黑箱第一道墙：root 也读不到 `cubbyhole/response`

```bash
VAULT_TOKEN=root vault read cubbyhole/response 2>&1 | head -3
```

输出 `No value found at cubbyhole/response`。

这正是 Step 2 那条 Token 隔离规律的字面应用：root 自己的 cubbyhole
里就没这条数据——真正存放它的，是 Vault 在 §4.2 那一刻**新建的那个
wrapping token** 的 cubbyhole 命名空间。

## 4.4 用 wrapping token 进入它自己的命名空间

```bash
VAULT_TOKEN=$WRAP vault read cubbyhole/response
```

**真正的响应被字面读出来了**——你会看到一段 JSON，里面嵌着
`{"data":{"data":{"password":"s3cret"}, ...}}`。

注意 Vault 1.19+ 会在这条命令上点亮一段 deprecation 警告：

```
WARNING! ... Reading from 'cubbyhole/response' is deprecated.
Please use sys/wrapping/unwrap to unwrap responses, as it provides
additional security checks and other benefits.
```

**生产里不要这样写**——这一步纯粹是为了把"wrap = cubbyhole 内的一
份隔离数据"这条因果关系**亲手验证一次**。日常拆封请用：

```bash
VAULT_TOKEN=$WRAP vault unwrap
```

效果一样、还多了几道安全校验，并且拆封即销毁 wrapping token 本身。

## 4.5 验证"拆封即作废"——用同一个 wrapping token 再 unwrap 一次

```bash
echo "--- 第一次 unwrap（重新用一个新 wrap，因为上面那个已经被读 1 次了） ---"
WRAP2=$(vault kv get -wrap-ttl=5m -format=json kv/db | jq -r .wrap_info.token)
VAULT_TOKEN=$WRAP2 vault unwrap

echo ""
echo "--- 第二次 unwrap 同一个 token（应该报错） ---"
VAULT_TOKEN=$WRAP2 vault unwrap 2>&1 | head -5
```

第二次会拿到 `Code: 400` / wrapping token 已不存在——unwrap 内部做
了三件事：

1. 读 `cubbyhole/response` 拿到真实响应
2. **立刻 revoke 这个 wrapping token**
3. wrapping token 的 cubbyhole 在 revoke 的同时被原子销毁（Step 3 §3.2
   规律）

所以"一次拆封即作废"不是策略上的禁止，**是物理上没了**。

## 4.6 把 §7 那张图对照一遍

[3.4 文档 §7](/ch3-cubbyhole) 的流程图现在每一步都能在你的实验里指
出来：

| 流程图里的步骤 | 在你这次实验里对应的操作 |
| --- | --- |
| Vault 真的读了 `secret/...` | §4.1 + Vault 内部在 §4.2 那次 wrap 时帮你做了 |
| 新建 wrapping token | §4.2 拿到的 `$WRAP` |
| 把响应写进 `cubbyhole/response` | §4.4 你直接读到的那段 JSON |
| 命名空间 = wrapping token | §4.3 root 看不见、§4.4 wrap token 看得见 |
| 拆封 = 读 + revoke | §4.5 第二次失败 |
| Cubbyhole 整体销毁 | §4.5 第二次失败的字面原因 |

至此 Cubbyhole 引擎的所有"特殊"行为都在你眼前完整跑过一遍了。

---

> 进入 Finish 总结。
