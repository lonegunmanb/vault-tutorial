# 第五步：Password Policy — 跟 ACL Policy 完全无关的另一套

文档开篇的警示：

> Password policies are unrelated to Policies other than sharing similar
> names.

ACL Policy 决定"能不能调某条 API"，Password Policy 决定"Vault 替你
生成密码时该怎么凑字符"。两者放在不同的 sys 端点下：

```
  /sys/policies/acl/<name>          ← ACL Policy（前 4 步都在写它）
  /sys/policies/password/<name>     ← Password Policy（本步）
```

## 5.1 看看默认 password policy 长什么样

dev 模式下默认 password policy 没显式落地，但生成端点能直接演示
"如果不指定 policy，默认用什么字符集"。我们先写一份跟文档默认一样
的 policy 当对照：

```bash
cat > /root/default-like.hcl <<'EOF'
length = 20

rule "charset" {
  charset = "abcdefghijklmnopqrstuvwxyz"
  min-chars = 1
}
rule "charset" {
  charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  min-chars = 1
}
rule "charset" {
  charset = "0123456789"
  min-chars = 1
}
rule "charset" {
  charset = "-"
  min-chars = 1
}
EOF

vault write sys/policies/password/default-like policy=@/root/default-like.hcl
```

调用 generate 端点看效果（这个端点专门用来调试，不需要任何机密引擎
配合）：

```bash
echo "default-like policy 生成 5 次:"
for i in 1 2 3 4 5; do
  vault read -field=password sys/policies/password/default-like/generate
done
```

每条都是 20 字符，必含小写、大写、数字和 `-`。

## 5.2 写一份"严格合规"的 password policy

很多企业要求密码至少 24 字符 + 大写、小写、数字、特殊字符各 2 个：

```bash
cat > /root/strict.hcl <<'EOF'
length = 24

rule "charset" {
  charset = "abcdefghijklmnopqrstuvwxyz"
  min-chars = 2
}
rule "charset" {
  charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  min-chars = 2
}
rule "charset" {
  charset = "0123456789"
  min-chars = 2
}
rule "charset" {
  charset = "!@#$%^&*"
  min-chars = 2
}
EOF

vault write sys/policies/password/strict policy=@/root/strict.hcl

echo ""
echo "strict policy 生成 5 次:"
for i in 1 2 3 4 5; do
  vault read -field=password sys/policies/password/strict/generate
done
```

注意每条密码：

- 长 24 字符
- 各字符类别都至少 2 个

文档 §7.1 的细节在这里都能验证：

- 多条 rule 的 charset **会被合并去重**作为生成池
- 但每条 rule 自己的 `min-chars` **各自独立检查**

## 5.3 演示性能陷阱：rule 越苛刻越慢

文档 §7.2 强调"小字符集 + 高 min-chars"会让生成器疯狂重试。我们
极端化一下试试：

```bash
cat > /root/extreme.hcl <<'EOF'
length = 8
rule "charset" {
  charset = "!@"
  min-chars = 6
}
rule "charset" {
  charset = "abcdefghijklmnopqrstuvwxyz"
  min-chars = 1
}
EOF

vault write sys/policies/password/extreme policy=@/root/extreme.hcl

echo "extreme policy（8 长度但要 6 个 !@）生成 3 次（注意每次延迟）:"
for i in 1 2 3; do
  time vault read -field=password sys/policies/password/extreme/generate > /dev/null
done
```

对比 strict 的速度：

```bash
echo ""
echo "strict policy 同样 3 次（很快）:"
for i in 1 2 3; do
  time vault read -field=password sys/policies/password/strict/generate > /dev/null
done
```

extreme 那个会肉眼可见地慢——生成器不断生成 8 字符候选，发现"6 个
都得是 !@ 之一"的条件极少自然满足，反复重试。

## 5.4 文档强制的边界条件

试几个**不合法**的 password policy，看 Vault 怎么拒：

```bash
echo "1) 没有任何 charset rule（必失败）:"
echo 'length = 20' > /tmp/bad1.hcl
vault write sys/policies/password/bad1 policy=@/tmp/bad1.hcl 2>&1 | tail -3

echo ""
echo "2) length 太短（< 4，必失败）:"
cat > /tmp/bad2.hcl <<'EOF'
length = 3
rule "charset" {
  charset = "abc"
}
EOF
vault write sys/policies/password/bad2 policy=@/tmp/bad2.hcl 2>&1 | tail -3
```

这些边界检查就是文档里反复列的硬约束。

## 5.5 让机密引擎用这条 policy

password policy 真正的用途是被机密引擎调用。dev 模式下没装真实数据
库，但可以快速看一眼配置接口长什么样——以 database 引擎为例：

```bash
vault secrets enable database

# 这里只演示"配置时怎么引用 password policy"——不实际连数据库，
# 所以只看命令形态，不看运行结果
echo "如果要用 strict policy 给 PostgreSQL 引擎生成密码，配置长这样:"
cat <<'EXAMPLE'
vault write database/config/my-pg \
  plugin_name=postgresql-database-plugin \
  password_policy=strict \
  connection_url="postgresql://{{username}}:{{password}}@host:5432/dbname" \
  allowed_roles="*" \
  username=vaultadmin \
  password=...
EXAMPLE

echo ""
echo "（database 章节会真的连 PostgreSQL；本步只示意 password_policy 的引用语法）"
```

**这一步的核心结论**：

| 概念 | ACL Policy | Password Policy |
| --- | --- | --- |
| 端点 | `sys/policies/acl/<name>` | `sys/policies/password/<name>` |
| 作用 | 控制 token 能调哪些 API | 控制 Vault 生成的随机密码长什么样 |
| 语法核心 | `path` + `capabilities` | `length` + 多条 `rule "charset"` |
| 调试方式 | `vault token capabilities` | `sys/policies/password/<name>/generate` |
| 失败模式 | 403 | 性能崩溃（生成不出来）/ 配置被拒 |
| 谁会引用它 | 每次 API 请求 | database / ldap / 其它需要造密码的引擎 |

记住——**这两个东西除了名字像，就没有任何关系**。
