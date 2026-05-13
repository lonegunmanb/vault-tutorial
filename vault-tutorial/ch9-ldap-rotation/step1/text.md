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
# alice, users, learn.example
dn: cn=alice,ou=users,dc=learn,dc=example
cn: alice

# search result
search: 2
result: 0 Success
```

`result: 0 Success` 是关键——它说明刚才那次 bind 通过了。这就是 simple bind 的完整语义：『拿对的 DN + 对的口令去连，LDAP 就接受你的所有后续请求』。

> **此时此刻，凡是知道 `1LearnedVault` 这一串字符的人都能以 alice 的身份操作 LDAP**。这一串字符以明文形式至少出现在三处：（i）你的 shell 历史；（ii）后台 `init/background.sh` 写入种子数据时使用过；（iii）OpenLDAP 容器内部的存储。第 3 步会让这一份口令失效。

---

## ✅ 验收

- [ ] `vault status` 显示 `Initialized = true`、`Sealed = false`、`Version = 1.19.2`
- [ ] `docker ps -f name=vault-openldap` 显示容器 `Up`
- [ ] 用 admin 凭据查 alice 条目，能看到 `dn: cn=alice,ou=users,dc=learn,dc=example`
- [ ] 用 `1LearnedVault` 以 alice 身份 bind，看到 `result: 0 Success`

下一步将启用 `ldap/` 引擎、写连接配置、立刻 `rotate-root`，然后再次尝试用旧的 `2LearnVault` bind——看到它已经失效。
