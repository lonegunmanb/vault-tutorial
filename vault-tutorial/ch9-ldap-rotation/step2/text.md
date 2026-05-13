# 第 2 步：启用 ldap/ 引擎并立刻 rotate-root

本步把 Vault 接到 OpenLDAP 上：写连接配置、然后**马上**做一次 `rotate-root` —— 让 Vault 这把『日常运维钥匙』从此**只属于 Vault**。这是 9.4 节正文第 4 节反复强调的一个动作：写完 `ldap/config` 的下一条命令必须是 `rotate-root`，否则那段时间里所有见过 `bindpass` 的人都依然能直接绕开 Vault 操作 LDAP。

## 关于 binddn：为什么不直接给 Vault 用 admin

LDAP 这一端有两类账号，请先把它们分清楚：

| 账号 | DN | 角色 |
| --- | --- | --- |
| **LDAP rootdn** | `cn=admin,dc=learn,dc=example` | 运维侧的 *break-glass* —— slapd 配置里登记的『超级用户』，享有这个数据库上**绕开 ACL 的隐式全权**；它的口令独立保存在 `cn=config` 的 `olcRootPW` 字段里，slapd 对它的 bind **不查 DIT**。 |
| **Vault 服务账号** | `cn=vault,ou=services,dc=learn,dc=example` | 我们 init 时已经建好的一个**普通条目**，初始口令 `2VaultBootstrap`。它**只**被 olcAccess 显式授权了一件事：写 `userPassword`（自己的 + 被管用户的）。 |

> **生产里绝不要把 rootdn 的凭据交给 Vault**——理由有两条：
>
> 1. 它**权力过大**：rootdn 在数据库内享有绕开 ACL 的隐式全权；Vault 只需要『改 `userPassword`』这一项能力，给它 rootdn 是经典的最小权限违反。
> 2. 它**`rotate-root` 也轮不动**：slapd 对 rootdn 的 bind 只查 `cn=config` 里的 `olcRootPW`，**完全不看** DIT 里同名条目的 `userPassword`；而 Vault 的 `rotate-root` 是通过 `ldapmodify` 改 DIT 里的 `userPassword`。结果就是 Vault 报 `Success!`，但旧口令通过 rootdn 这条捷径**永远**有效，rotate 形同虚设。
>
> 所以正确姿势是：**给 Vault 建一个专用的、最小权限的服务账号**，把它登记成 binddn；rootdn 留作运维出口，永远不递给任何自动化系统。本节的 `cn=vault,ou=services,...` 就是这样一个账号。

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

注意 `binddn` 用的是**专为 Vault 准备的服务账号**、不是 admin：

```bash
vault write ldap/config \
    binddn=cn=vault,ou=services,dc=learn,dc=example \
    bindpass=2VaultBootstrap \
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

预期能看到 `binddn = cn=vault,ou=services,dc=learn,dc=example`、`url = ldap://127.0.0.1:389` 这两行；`bindpass` 这一项**不会**出现。

> 这里我们没有写 `userdn` / `userattr` / `schema`：本节的 Static Role 在 [3.10 §3](/ch3-ldap) 已经讲过——它需要的所有 DN 信息都直接通过 `dn=` 字段在 role 上指明，Vault **不需要**再做搜索。所以最小配置就够了。

## 2.3 立刻 rotate-root

```bash
vault write -f ldap/rotate-root
```

预期输出：

```
Success! Data written to: ldap/rotate-root
```

这条命令做了什么：Vault 用刚才写进去的 `2VaultBootstrap` bind LDAP，把 `cn=vault` 这条**自己的**条目的 `userPassword` 改成一段新随机串，自己在内部记下这份新口令——**而且不再向任何 API 暴露它**。因为 `cn=vault` 是普通条目（不是 rootdn），slapd 给它的认证就走 DIT 里的 `userPassword`，所以这次 rotate 是**真正生效**的。

## 2.4 用旧口令验证『rotate-root 已经生效』

如果 rotate-root 真的生效了，那么以前那一份 `2VaultBootstrap` 应当无法再以 `cn=vault` 的身份 bind LDAP。试一下：

```bash
ldapsearch -x -H ldap://127.0.0.1:389 \
  -D "cn=vault,ou=services,dc=learn,dc=example" -w 2VaultBootstrap \
  -b "cn=vault,ou=services,dc=learn,dc=example" -s base "(objectClass=*)" 2>&1 | tail -3
```

预期输出：

```
ldap_bind: Invalid credentials (49)
```

`Invalid credentials (49)` 是 LDAP 协议规定的错误码，含义就是『DN 对、口令错』。这说明 `cn=vault` 在 LDAP 端的 `userPassword` 已经被改成了新随机串，老的 `2VaultBootstrap` 再也用不了。

> **此时此刻，`cn=vault` 的口令仅存于 Vault 内部存储**。Vault 自己的 API 也不再吐它——任何想以 `cn=vault` 的身份动 LDAP 的人，要么持有 Vault 的 root token、要么持有一条允许动 `ldap/*` 的策略；从此再也不存在『某人偷看 shell 历史就能拿到 Vault 服务凭据』这种攻击路径。

## 2.5 admin 仍然能用——这是设计

我们故意**不动** rootdn。运维侧用来应急登 LDAP 的那把钥匙必须保持在 Vault 之外，验证一下它仍然有效：

```bash
ldapsearch -x -H ldap://127.0.0.1:389 \
  -D "cn=admin,dc=learn,dc=example" -w 2LearnVault \
  -b "dc=learn,dc=example" -s base "(objectClass=*)" 2>&1 | tail -3
```

预期看到 `result: 0 Success`、`numEntries: 1`——admin 能 bind 成功。

> 这是**特性不是 bug**：rootdn 的口令在生产里应当走另一条独立的轨道（密码保险柜、PIM/PAM、纸质封存等等）；Vault 拿到的是一张『日常自动化用』的服务账号通行证，权限只覆盖『改 `userPassword`』这一件事。如果哪天 Vault 整个失联，运维仍然可以拿 rootdn 进 LDAP 自救——这正是给 Vault 用最小权限服务账号、而不是 rootdn 的意义。

## 2.6 顺便确认 alice 的口令『还』没被动过

我们刚才只动了 `cn=vault` 自己。alice 还在用她原本那一份 `1LearnedVault`：

```bash
ldapsearch -x -H ldap://127.0.0.1:389 \
  -D "cn=alice,ou=users,dc=learn,dc=example" -w 1LearnedVault \
  -b "cn=alice,ou=users,dc=learn,dc=example" -s base cn 2>&1 | tail -3
```

预期输出末尾应当还是 `result: 0 Success`。这是因为我们还没创建 Static Role；Vault 此时只是『有能力』管 LDAP，但还**没有去管 alice**。第 3 步就来管。

---

## ✅ 验收

- [ ] `vault secrets list` 看得到 `ldap/`
- [ ] `vault read ldap/config` 返回 `binddn = cn=vault,ou=services,dc=learn,dc=example`、`url = ldap://127.0.0.1:389`
- [ ] `vault write -f ldap/rotate-root` 输出 `Success!`
- [ ] 用 `2VaultBootstrap` 以 `cn=vault` 身份 bind 失败，错误是 `Invalid credentials (49)`
- [ ] 用 `2LearnVault` 以 `cn=admin` 身份 bind 仍然 `result: 0 Success`（rootdn 是运维 break-glass，不归 Vault 管）
- [ ] 用 `1LearnedVault` 以 alice 身份 bind 仍然 `result: 0 Success`
