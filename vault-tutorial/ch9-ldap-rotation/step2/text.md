# 第 2 步：启用 ldap/ 引擎并立刻 rotate-root

本步把 Vault 接到 OpenLDAP 上：写连接配置、然后**马上**做一次 `rotate-root` —— 让 admin 这把『万能钥匙』从此**只属于 Vault**。这是 9.4 节正文第 4 节反复强调的一个动作：写完 `ldap/config` 的下一条命令必须是 `rotate-root`，否则那段时间里所有见过 `bindpass` 的人都依然能直接绕开 Vault 操作 LDAP。

---

## 2.1 启用 ldap 机密引擎

```bash
vault secrets enable ldap
```

预期输出：

```
Success! Enabled the ldap secrets engine at: ldap/
```

确认它已经挂在 `ldap/` 路径下：

```bash
vault secrets list | grep -E "Path|^ldap/"
```

预期看到一行 `ldap/` 开头、Type 列写着 `ldap`。

## 2.2 写入连接配置

```bash
vault write ldap/config \
    binddn=cn=admin,dc=learn,dc=example \
    bindpass=2LearnVault \
    url=ldap://127.0.0.1:389
```

预期输出：

```
Success! Data written to: ldap/config
```

读回来看一下（`bindpass` 永远不会回显，这是 Vault 的有意保护）：

```bash
vault read ldap/config
```

预期能看到 `binddn = cn=admin,dc=learn,dc=example`、`url = ldap://127.0.0.1:389` 这两行；`bindpass` 这一项**不会**出现。

> 这里我们没有写 `userdn` / `userattr` / `schema`：本节的 Static Role 在 [3.10 §3](/ch3-ldap) 已经讲过——它需要的所有 DN 信息都直接通过 `dn=` 字段在 role 上指明，Vault **不需要**再做搜索。所以最小配置就够了。

## 2.3 立刻 rotate-root

```bash
vault write -f ldap/rotate-root
```

预期输出：

```
Success! Data written to: ldap/rotate-root
```

这一条命令做的事在 9.4 节正文第 4 节已经解释过：Vault 用刚才写进去的 `2LearnVault` bind LDAP，把 admin 的 `userPassword` 改成一段新随机串，自己在内部记下这份新口令——**而且不再向任何 API 暴露它**。

## 2.4 用旧口令验证『rotate-root 已经生效』

如果 rotate-root 真的生效了，那么以前那一份 `2LearnVault` 应当无法再 bind LDAP。试一下：

```bash
ldapsearch -x -H ldap://127.0.0.1:389 \
  -D "cn=admin,dc=learn,dc=example" -w 2LearnVault \
  -b "dc=learn,dc=example" -s base "(objectClass=*)" 2>&1 | tail -3
```

预期输出：

```
ldap_bind: Invalid credentials (49)
```

`Invalid credentials (49)` 是 LDAP 协议规定的错误码，含义就是『DN 对、口令错』。这说明 admin 在 LDAP 端的 `userPassword` 已经被改成了新随机串，老的 `2LearnVault` 再也用不了。

> **此时此刻，admin 的口令仅存于 Vault 内部存储**。Vault 自己的 API 也不再吐它——任何想以 admin 身份动 LDAP 的人，要么持有 Vault 的 root token、要么持有一条允许动 `ldap/*` 的策略；从此再也不存在『某人偷看 shell 历史就能拿到管理员口令』这种攻击路径。

## 2.5 顺便确认 alice 的口令『还』没被动过

我们刚才只动了 admin。alice 还在用她原本那一份 `1LearnedVault`：

```bash
ldapsearch -x -H ldap://127.0.0.1:389 \
  -D "cn=alice,ou=users,dc=learn,dc=example" -w 1LearnedVault \
  -b "cn=alice,ou=users,dc=learn,dc=example" -s base cn 2>&1 | tail -3
```

预期输出末尾应当还是 `result: 0 Success`。这是因为我们还没创建 Static Role；Vault 此时只是『有能力』管 LDAP，但还**没有去管 alice**。第 3 步就来管。

---

## ✅ 验收

- [ ] `vault secrets list` 看得到 `ldap/`
- [ ] `vault read ldap/config` 返回 `binddn = cn=admin,dc=learn,dc=example`、`url = ldap://127.0.0.1:389`
- [ ] `vault write -f ldap/rotate-root` 输出 `Success!`
- [ ] 用 `2LearnVault` 以 admin 身份 bind 失败，错误是 `Invalid credentials (49)`
- [ ] 用 `1LearnedVault` 以 alice 身份 bind 仍然 `result: 0 Success`
