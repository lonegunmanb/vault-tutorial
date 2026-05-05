# 第二步：使用 login 获取不落盘 token

现在用 `alice` 登录。为了让实验不改变本机 token helper，使用 `-no-store`：它会显示 token 信息，但不会把 token 保存为后续 CLI 的默认凭据。

```bash
vault login -method=userpass -path=staff -no-store username=alice password=wonderland
```

如果脚本只需要 token 字符串，可以使用 `-token-only`。它是 `-field=token -no-store` 的快捷形式。

```bash
ALICE_TOKEN=$(vault login -method=userpass -path=staff -token-only username=alice password=wonderland)
echo "Alice token prefix: ${ALICE_TOKEN:0:16}..."
```

用这枚 token 查询自身。这里通过临时环境变量 `VAULT_TOKEN=$ALICE_TOKEN` 发起请求，不覆盖 root token。

```bash
VAULT_TOKEN=$ALICE_TOKEN vault token lookup | grep -E 'display_name|policies|ttl'
```

验证 `alice` 的 token 确实能读取实验数据。

```bash
VAULT_TOKEN=$ALICE_TOKEN vault kv get secret/app/config
```

再用 `bob` 登录并尝试读取同一路径。`bob` 只有 `default` 策略，因此这次请求应被拒绝。

```bash
BOB_TOKEN=$(vault login -method=userpass -path=staff -token-only username=bob password=builder)
VAULT_TOKEN=$BOB_TOKEN vault kv get secret/app/config 2>&1 | tail -4
```

这一阶段的关键点是：`vault login` 使用 `-method` 指定认证类型，用 `-path` 指定实际挂载路径；登录成功后的结果是 Vault token。
