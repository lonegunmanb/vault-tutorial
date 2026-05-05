# 第三步：创建 token 并诊断权限

除了通过认证方法登录，管理员也可以直接创建 token。下面创建一枚短期教学 token，带 `app-read` 策略、显示名称、元数据、TTL 和硬性最大 TTL。

```bash
vault token create \
  -policy=app-read \
  -ttl=20m \
  -explicit-max-ttl=1h \
  -display-name=training-child \
  -metadata=purpose=cli-lab \
  -format=json > /tmp/child-token.json

CHILD_TOKEN=$(jq -r .auth.client_token /tmp/child-token.json)
CHILD_ACCESSOR=$(jq -r .auth.accessor /tmp/child-token.json)
echo "Child token prefix: ${CHILD_TOKEN:0:16}..."
echo "Child accessor: $CHILD_ACCESSOR"
```

用 token 值查询完整状态。

```bash
vault token lookup "$CHILD_TOKEN" | grep -E 'display_name|meta|ttl|explicit_max_ttl|policies'
```

再用 accessor 查询。注意 accessor 不是登录凭据，但可以作为管理句柄使用。

```bash
vault token lookup -accessor "$CHILD_ACCESSOR" | grep -E 'accessor|ttl|policies'
```

用 `capabilities` 检查这枚 token 对两个路径的能力：它应该能读应用配置，但不能管理系统挂载点。

```bash
vault token capabilities "$CHILD_TOKEN" secret/data/app/config
vault token capabilities "$CHILD_TOKEN" sys/mounts
```

这一阶段的关键点是：`lookup` 看 token 状态，`capabilities` 看 token 对某条路径的权限，两者都不等同于真正读取机密。
