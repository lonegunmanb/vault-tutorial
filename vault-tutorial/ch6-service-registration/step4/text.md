# 第四步：为节点加上自定义 service_tags 与 service_meta

正文 §2.3 列出了两个常被忽略但在多机房 / 多版本部署中非常有用的参数：`service_tags` 与 `service_meta`。本步骤把它们实际加到 node-3 的配置上，看 Consul 服务目录中该节点的条目如何变化。

## 4.1 修改 node-3 的 vault.hcl

把 `/root/vault-3.hcl` 末尾的 `service_registration "consul"` 块替换为含 `service_tags` 与 `service_meta` 的版本：

```bash
cat > /tmp/sd-block.hcl <<'EOF'
service_registration "consul" {
  address      = "127.0.0.1:8500"
  service_tags = "az-a,version-1.19.2,role-vault"
  service_meta = {
    az          = "az-a"
    environment = "classroom"
  }
}
EOF

# 删除原 service_registration 块（从 'service_registration "consul"' 行到与之配对的 '}' 行）
sed -i '/^service_registration "consul"/,/^}/d' /root/vault-3.hcl

# 追加新的块
cat /tmp/sd-block.hcl >> /root/vault-3.hcl

tail -n 10 /root/vault-3.hcl
```

确认输出末尾正是新的带 `service_tags` 与 `service_meta` 的块。

## 4.2 重启 node-3 让新配置生效

`service_registration` 的相关参数仅在节点启动时读取，因此需要重启该 Vault 进程：

```bash
kill "$(cat /tmp/vault-3.pid)"
sleep 3

./start-node.sh 3
sleep 3

# 重启后该节点处于 sealed 状态，需要重新 unseal 才能回到 standby 池
VAULT_ADDR=http://127.0.0.1:8220 vault operator unseal "$UNSEAL_KEY"
sleep 5
```

## 4.3 在 Consul 服务目录中观察新标签

通过 Consul 的 HTTP catalog API 查看 node-3 对应条目：

```bash
curl -sS http://127.0.0.1:8500/v1/catalog/service/vault \
  | jq '.[] | select(.ServicePort == 8220)
              | {ServiceID, ServicePort, ServiceTags, ServiceMeta}'
```

预期 `ServiceTags` 是数组 `["az-a", "version-1.19.2", "role-vault"]`，`ServiceMeta` 是对象 `{ "az": "az-a", "environment": "classroom" }`。

进一步可以做"按标签筛选"的服务发现查询——Consul 支持以 `<tag>.<service>.service.consul` 形式按 tag 子集解析：

```bash
echo "=== 仅返回带 az-a 标签的 vault 节点 ==="
dig @127.0.0.1 -p 8600 az-a.vault.service.consul SRV +short
```

应当只返回 8220 这一条 SRV 记录。

## 4.4 这一步的核心闭环

学员看到：`service_tags` / `service_meta` 让 Vault 节点在 Consul 服务目录中携带任意维度的业务标签，配合 Consul 原生的"按 tag 过滤"DNS 查询，就可以做到"客户端只把请求路由到指定机房 / 指定版本的 Vault 节点"——这一切完全在 Vault 与 Consul 之间静态协商完成，应用代码无需任何感知。

至此，本实验完成了 6.7 节正文围绕 `service_registration "consul"` 块给出的全部主线观察点：从隐式 / 显式注册的边界，到三个标准 DNS 端点的语义，到 sealed 节点的自动隐身，再到自定义标签 / 元数据的透传。
