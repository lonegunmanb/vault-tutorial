# 第四步：用受限 token 验证策略效果

用 root token 创建一枚额外附加 `team-reader` 策略的短期 token。Vault 通常还会自动附加 `default` 策略；后续命令会通过临时环境变量 `VAULT_TOKEN=$TEAM_TOKEN` 使用它，不覆盖当前 shell 中的 root token。

```bash
TEAM_TOKEN=$(vault token create -policy=team-reader -ttl=20m -field=token)
echo "受限 token 已创建，长度：${#TEAM_TOKEN}"
```

使用受限 token 读取机密。由于策略授予了 `team-secrets/data/app/config` 的 `read` 能力，读取应当成功。

```bash
VAULT_TOKEN=$TEAM_TOKEN vault kv get team-secrets/app/config
```

使用同一枚受限 token 列出目录。KV v2 的目录列表对应 metadata 路径，因此策略中单独授予了 `team-secrets/metadata/app` 的 `list` 能力。

```bash
VAULT_TOKEN=$TEAM_TOKEN vault kv list team-secrets/app
```

尝试使用受限 token 修改机密。当前策略没有授予写入能力，因此该命令应当返回权限错误。

```bash
VAULT_TOKEN=$TEAM_TOKEN vault kv put team-secrets/app/config username="webapp" password="blocked" 2>&1 | tail -5
```

现在更新服务器端策略，给同一路径增加 `create` 和 `update` 能力。

```bash
cat > /root/team-reader.hcl <<'EOF'
path "team-secrets/data/app/config" {
  capabilities = ["create", "read", "update"]
}

path "team-secrets/metadata/app" {
  capabilities = ["list"]
}
EOF

vault policy fmt /root/team-reader.hcl
vault policy write team-reader /root/team-reader.hcl
```

再次使用同一枚受限 token 写入数据。此时写入应当成功，说明策略内容变化会影响后续访问判断。

```bash
VAULT_TOKEN=$TEAM_TOKEN vault kv put team-secrets/app/config username="webapp" password="changed-by-policy-update"
VAULT_TOKEN=$TEAM_TOKEN vault kv get -field=password team-secrets/app/config
echo
```

本步骤的重点是把策略从“文件内容”变成可观察的访问结果：能读、能列、不能写，或者更新后可以写，都应当用实际请求验证。
