# 第三步：格式化、写入与读取策略

创建一份故意缩进不整齐的本地策略文件。它允许读取 `team-secrets/app/config`，并允许列出 `team-secrets/app` 目录。

```bash
cat > /root/team-reader-rough.hcl <<'EOF'
path "team-secrets/data/app/config" {
capabilities = ["read"]
}
path "team-secrets/metadata/app" {
capabilities = ["list"]
}
EOF

cp /root/team-reader-rough.hcl /root/team-reader.hcl
```

使用 `vault policy fmt` 格式化本地文件。该命令会覆盖目标文件，因此实验中先保留了一份 `team-reader-rough.hcl` 作为对照。

```bash
vault policy fmt /root/team-reader.hcl
diff -u /root/team-reader-rough.hcl /root/team-reader.hcl || true
```

把格式化后的策略上传到 Vault，服务器端策略名称为 `team-reader`。

```bash
vault policy write team-reader /root/team-reader.hcl
```

列出策略，确认 `team-reader` 已经安装到 Vault 服务器上。

```bash
vault policy list
```

读取服务器端保存的策略内容。这里同时演示默认输出和 JSON 输出；自动化场景通常更适合使用 JSON。

```bash
vault policy read team-reader
vault policy read -format=json team-reader | jq -r '.policy'
```

本步骤的重点是区分“本地策略文件”和“服务器端命名策略”。`fmt` 修改本地文件，`write` 才会把内容上传到 Vault。
