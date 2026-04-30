# 第 3 步：Dynamic Role —— 用完即删的临时账号

模型：[3.10 §4](/ch3-ldap)。本步要：

1. 准备 `creation_ldif` 与 `deletion_ldif` 模板
2. 创建 Dynamic Role
3. `vault read ldap/creds/<role>` 申领凭据 → 拿到一个**新建**的临时账号 + Lease
4. 用临时账号登 LDAP；从 LDAP 端 `ldapsearch` 验证账号确实存在
5. `vault lease revoke` 撤 Lease → 临时账号从 LDAP 上消失

---

## 3.1 准备 LDIF 模板

```bash
cat > /tmp/creation.ldif <<'EOF'
dn: cn={{.Username}},ou=DynamicUsers,dc=example,dc=org
changetype: add
objectClass: inetOrgPerson
cn: {{.Username}}
sn: TempUser
userPassword: {{.Password}}
EOF

cat > /tmp/deletion.ldif <<'EOF'
dn: cn={{.Username}},ou=DynamicUsers,dc=example,dc=org
changetype: delete
EOF
```

`{{.Username}}` 与 `{{.Password}}` 是 Vault 在每次申领时填充的占位符。

## 3.2 创建 Dynamic Role

```bash
vault write ldap/role/web-api \
  creation_ldif=@/tmp/creation.ldif \
  deletion_ldif=@/tmp/deletion.ldif \
  default_ttl="2m" \
  max_ttl="10m" \
  username_template="v_{{.RoleName}}_{{unix_time}}"

vault read ldap/role/web-api
```

> **`@file` 语法很重要**：多行 LDIF 直接传给 `vault write` 会被换行符破坏。
> 用 `@` 让 Vault 自己读文件，等价于先 `base64 -w0` 再传，但更可读。

## 3.3 申领一份凭据

```bash
CRED=$(vault read -format=json ldap/creds/web-api)
echo "$CRED" | jq

USER=$(echo "$CRED" | jq -r .data.username)
PASS=$(echo "$CRED" | jq -r .data.password)
LEASE=$(echo "$CRED" | jq -r .lease_id)

echo "临时用户: $USER"
echo "临时密码: $PASS"
echo "Lease ID: $LEASE"
```

## 3.4 从 LDAP 端验证账号存在

```bash
# 用 admin 列 ou=DynamicUsers
ldapsearch -x -H ldap://127.0.0.1:389 \
  -D "cn=admin,dc=example,dc=org" -w admin \
  -b "ou=DynamicUsers,dc=example,dc=org" "(cn=$USER)" cn

# 用临时账号自己登
ldapwhoami -x -H ldap://127.0.0.1:389 \
  -D "cn=$USER,ou=DynamicUsers,dc=example,dc=org" -w "$PASS"
```

`ldapwhoami` 应输出 `dn:cn=v_web-api_...,ou=DynamicUsers,dc=example,dc=org`。

## 3.5 撤销 Lease，观察临时账号消失

```bash
vault lease revoke "$LEASE"
sleep 1

# 再查
ldapsearch -x -H ldap://127.0.0.1:389 \
  -D "cn=admin,dc=example,dc=org" -w admin \
  -b "ou=DynamicUsers,dc=example,dc=org" "(cn=$USER)" cn 2>&1 | grep -E "numResponses|numEntries|cn:"
```

应只看到 `# numResponses: 1`、看不到任何 `# numEntries:` 也看不到 `cn:` 行——账号已被 `deletion_ldif` 销毁。

> 小知识：`ldapsearch` 在 0 命中时只会输出 `# numResponses: 1`（包含 search-result 本身），
> **不会**输出 `# numEntries:` 行（该行只在命中 ≥1 时才出现）。所以 grep 必须包含 `numResponses` 才能看到「删除成功」的信号。

## 3.6 让 Lease 自然过期

```bash
CRED2=$(vault read -format=json ldap/creds/web-api)
USER2=$(echo "$CRED2" | jq -r .data.username)
LEASE2=$(echo "$CRED2" | jq -r .lease_id)
echo "新临时用户：$USER2 (Lease 2 分钟后自动过期)"

# 立刻能查到
ldapsearch -x -H ldap://127.0.0.1:389 \
  -D "cn=admin,dc=example,dc=org" -w admin \
  -b "ou=DynamicUsers,dc=example,dc=org" "(cn=$USER2)" cn | grep "^cn:"

echo "等 130 秒看 Lease 自动过期..."
sleep 130

# 再查应已消失
ldapsearch -x -H ldap://127.0.0.1:389 \
  -D "cn=admin,dc=example,dc=org" -w admin \
  -b "ou=DynamicUsers,dc=example,dc=org" "(cn=$USER2)" cn | grep -E "numResponses|numEntries|cn:"
```

---

## ✅ 验收

- [ ] 申领一次后，OpenLDAP 的 `ou=DynamicUsers` 多了一个 `v_web-api_...` 账号
- [ ] 用临时账号 `ldapwhoami` 能成功
- [ ] `vault lease revoke` 后该账号立刻从 LDAP 消失
- [ ] 不主动 revoke 也能自然过期 → LDAP 上同样消失

> 与 Static Role 对比：Static = 同一账号 + 密码定时变；Dynamic = 每次新账号 + Lease 一到自动删。
> 与 [3.3 AWS 引擎](/ch3-aws-engine) 对比：模型完全相同，只是清理对象从 IAM User 变成 LDAP entry。
