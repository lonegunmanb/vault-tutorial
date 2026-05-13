# 第 1 步：起 OpenLDAP 容器并验证 alice 的初始口令

本步什么 Vault 命令都不写。它的目的只有一个——让你**亲眼看到**：在接入 Vault 之前，alice 这位用户的口令就是一段明明白白的字符串 `1LearnedVault`，**任何**知道这一串字符的人都能以 alice 的身份 bind LDAP。后面三步要做的事，就是把『谁能以 alice 的身份操作』这件事的答案从『谁知道 1LearnedVault』改成『谁有权读 `ldap/static-cred/learn`』。

---

## 1.1 确认环境就绪

先看一眼 Vault：

```bash
vault status | head -7
```

预期输出至少包含：

```
Initialized     true
Sealed          false
...
Version         1.19.2
```

再看 OpenLDAP 容器是否已经在跑：

```bash
docker ps -f name=vault-openldap --format 'table {{.Names}}\t{{.Status}}'
```

预期输出形如：

```
NAMES             STATUS
vault-openldap    Up 30 seconds
```

如果第二条命令的列表为空，说明 OpenLDAP 容器没启动，请运行 `tail -50 /var/log/ldap-rotation-init.log` 查看后台脚本卡在哪里。

## 1.2 看一眼 alice 的目录条目

`ldapsearch` 是 OpenLDAP 自带的命令行查询工具，它的几个常用参数含义如下：

| 参数 | 含义 |
| --- | --- |
| `-x` | 用 simple bind（DN + 口令）而不是 SASL |
| `-H ldap://...` | LDAP 服务器地址 |
| `-D <DN>` | 用哪个 DN 去 bind |
| `-w <password>` | bind 时用的口令（写在命令行里，仅适合实验环境） |
| `-b <DN>` | 搜索的起点（base DN） |
| `-s base` / `-s sub` | 搜索范围：`base` 只看这一条；`sub` 含子树 |
| 末尾的 `cn sn` 等 | 只返回这几个属性，省掉一长串其它字段 |

用 admin 凭据看一下 alice 的条目长什么样：

```bash
ldapsearch -x -H ldap://127.0.0.1:389 \
  -D "cn=admin,dc=learn,dc=example" -w 2LearnVault \
  -b "cn=alice,ou=users,dc=learn,dc=example" -s base \
  cn sn objectClass
```

预期看到（末尾的 search result / numEntries 略去）：

```
dn: cn=alice,ou=users,dc=learn,dc=example
objectClass: person
objectClass: top
cn: alice
sn: Liddell
```

注意：`ldapsearch` **不会**把 `userPassword` 这个属性的明文打出来——OpenLDAP 默认对外只返回 hash，更何况非 admin 用户根本看不到这一项。我们用『能不能成功 bind』这件事来反推口令是不是对的就行。

## 1.3 用 alice 自己的初始口令 bind 一次

这就是『接入 Vault 之前的世界』：

```bash
ldapsearch -x -H ldap://127.0.0.1:389 \
  -D "cn=alice,ou=users,dc=learn,dc=example" -w 1LearnedVault \
  -b "cn=alice,ou=users,dc=learn,dc=example" -s base cn 2>&1 | tail -8
```

预期输出末尾几行：

```
cn: alice

# search result
search: 2
result: 0 Success

# numResponses: 2
# numEntries: 1
```

这一段输出之所以能证明『alice 的初始口令此刻确实有效』，需要把 `ldapsearch` 在底层做的两段动作分开看：

1. **第一段——bind**：`ldapsearch` 用 `-D` 给出的 DN 与 `-w` 给出的口令向 LDAP 服务器发起一次 simple bind 请求。LDAP 协议（[RFC 4511 §4.2](https://datatracker.ietf.org/doc/html/rfc4511#section-4.2)）规定服务器会回一个 `BindResponse`，其中带一个**结果码（resultCode）**。如果口令对得上，结果码是 `0`，名字叫 `success`；如果对不上，结果码是 `49`，名字叫 `invalidCredentials`。**bind 失败时，`ldapsearch` 会立刻退出，根本不会再发后续的搜索请求**——所以一旦 bind 不通，你看到的不会是 `result: 0 Success` 而是 `ldap_bind: Invalid credentials (49)`，并且不会有任何 `dn:` / `cn:` 行出现。
2. **第二段——search**：bind 通过之后，`ldapsearch` 才会按 `-b` 与 `-s` 发起一次搜索请求，并把命中的条目逐条打印出来。最后一行 `result: 0 Success` 是**搜索请求**自己的结果码，含义是『搜索本身没有出错』。

把这两段对照到刚才的输出上：

- `cn: alice` 这一行是搜索阶段返回的属性——它能出现在屏幕上，本身就证明 bind 阶段没有提早失败；
- `result: 0 Success` 是搜索阶段的成功码，进一步说明请求被服务器正常处理；
- `numResponses: 2` 表示服务器一共回了两条消息——一条搜索条目（含 `dn:` / `cn:`）+ 一条 `searchResultDone`；`numEntries: 1` 表示其中实际命中了 1 条条目。

> **关于 `tail -8` 截断的小提示**：完整的 `ldapsearch` 输出最前面还有几行注释（`# extended LDIF` 头、`# base <...>` 等），紧接着是 `# alice, users, learn.example` 与 `dn: cn=alice,...` 这两行。我们这里加 `| tail -8` 是为了把屏幕噪音降到最小、只保留判断成败所需的关键尾部；把 `| tail -8` 去掉再跑一次，就能看到完整的 LDIF 输出。

总而言之：**只要这条命令打印出了 `result: 0 Success` 且没有 `ldap_bind: Invalid credentials`，就可以断定 alice 此刻在 LDAP 端的口令就是 `1LearnedVault`**。这就是 simple bind 的完整语义：『拿对的 DN + 对的口令去连，LDAP 就接受你的所有后续请求』。

> **此时此刻，凡是知道 `1LearnedVault` 这一串字符的人都能以 alice 的身份操作 LDAP**。这一串字符以明文形式至少出现在三处：（i）你的 shell 历史；（ii）后台 `init/background.sh` 写入种子数据时使用过；（iii）OpenLDAP 容器内部的存储。第 3 步会让这一份口令失效。

---

## ✅ 验收

- [ ] `vault status` 显示 `Initialized = true`、`Sealed = false`、`Version = 1.19.2`
- [ ] `docker ps -f name=vault-openldap` 显示容器 `Up`
- [ ] 用 admin 凭据查 alice 条目，能看到 `dn: cn=alice,ou=users,dc=learn,dc=example`
- [ ] 用 `1LearnedVault` 以 alice 身份 bind，看到 `result: 0 Success`

下一步将启用 `ldap/` 引擎、写连接配置、立刻 `rotate-root`，然后再次尝试用旧的 `2LearnVault` bind——看到它已经失效。
