# 第四步：局部更新：patch 只改指定字段

实验环境里已经准备了一个 PKI role。先查看它的 `allow_localhost` 字段：

```bash
vault read -field=allow_localhost pki/roles/example
echo
```

用 `patch` 只修改这一个字段：

```bash
vault patch pki/roles/example allow_localhost=false
vault read -field=allow_localhost pki/roles/example
echo
```

如果要把它改回来，也可以把 JSON 请求体从 stdin 交给 `patch`：

```bash
cat > role-patch.json <<'EOF'
{
  "allow_localhost": true
}
EOF

cat role-patch.json | vault patch pki/roles/example -
vault read -field=allow_localhost pki/roles/example
echo
```

现在再读取整个 role，确认其他字段仍然存在：

```bash
vault read pki/roles/example | grep -E 'allowed_domains|allow_subdomains|allow_localhost|max_ttl'
```

这就是 `patch` 相对 `write` 的价值：你只点名要修改的字段，其他字段交给后端保留。
