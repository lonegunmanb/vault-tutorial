# 第三步：手工合并——把两个 alias 挂到同一 Entity

step2 留下了两条独立的 entity（alice@userpass / alice@userpass-corp）。
这一步把它们合并成一个"真正的 alice"。

## 3.1 创建一个命名 Entity

```bash
vault write identity/entity name=alice-real policies=default
ENT_REAL=$(vault read -format=json identity/entity/name/alice-real | jq -r .data.id)
echo "新建的 alice-real entity_id = $ENT_REAL"
```

## 3.2 拿到两个 mount 的 accessor

```bash
USERPASS_ACC=$(vault auth list -format=json | jq -r '."userpass/".accessor')
USERPASS_CORP_ACC=$(vault auth list -format=json | jq -r '."userpass-corp/".accessor')

echo "userpass/      accessor = $USERPASS_ACC"
echo "userpass-corp/ accessor = $USERPASS_CORP_ACC"
```

## 3.3 把 step1 / step2 自动建的两条 alias 改挂到 alice-real 下

先列出当前所有 alias，找到那两条：

```bash
vault list -format=json identity/entity-alias/id | jq -r '.[]' \
  | while read aid; do
      vault read -format=json identity/entity-alias/id/$aid \
        | jq -c '{id: .data.id, name: .data.name, mount_accessor: .data.mount_accessor, canonical_id: .data.canonical_id}'
    done
```

挑出 `name=alice` 的两条 alias_id，分别改它们的 `canonical_id`：

```bash
for aid in $(vault list -format=json identity/entity-alias/id | jq -r '.[]'); do
  info=$(vault read -format=json identity/entity-alias/id/$aid)
  name=$(echo "$info" | jq -r .data.name)
  if [ "$name" = "alice" ]; then
    echo "重新挂载 alias $aid 到 entity $ENT_REAL"
    vault write identity/entity-alias/id/$aid \
      canonical_id=$ENT_REAL \
      name=alice \
      mount_accessor=$(echo "$info" | jq -r .data.mount_accessor)
  fi
done
```

> 注意——`vault write identity/entity-alias/id/<id>` 这条 API 是
> "整体覆盖"，所以必须把 `name` 和 `mount_accessor` 一并传，否则它
> 们会被清成空字符串，alias 就废掉了。

## 3.4 验证：alice-real 下现在挂了两条 alias

```bash
vault read identity/entity/id/$ENT_REAL
```

输出里 `aliases` 数组应该有 2 条——一条 `mount_type = userpass`、
一条 `mount_type = userpass`（但 `mount_path = userpass-corp/`）。

step1/step2 留下的那两条空 entity 现在已经没有 alias 了，可以删掉：

```bash
echo "现在 entity 列表（应该只有 alice-real 真正持有 alias）:"
for eid in $(vault list -format=json identity/entity/id | jq -r '.[]'); do
  info=$(vault read -format=json identity/entity/id/$eid)
  echo "  $eid  name=$(echo "$info" | jq -r .data.name)  aliases=$(echo "$info" | jq -r '.data.aliases | length')"
done
```

## 3.5 重新登录，看 entity_id 是否一致

```bash
vault login -format=json -method=userpass username=alice password=s3cr3t \
  | jq -r .auth.entity_id

vault login -format=json -method=userpass -path=userpass-corp \
  username=alice password=s3cr3t \
  | jq -r .auth.entity_id
```

两次输出都应该是 `$ENT_REAL` ——**alice 通过哪个 mount 登录都已经被
归并成同一个真实身份了**。

```bash
echo "目标 entity_id = $ENT_REAL"
```

**这一步的核心结论**：合并是一次性的管理动作，做完之后**所有未来的
登录都会自动落到合并后的 entity 上**——因为 Vault 在 login 时会用
(alias_name, mount_accessor) 去查 alias，命中已有 alias 就直接用上面
的 `canonical_id`，根本不再新建 entity。

实际生产里，企业 IdP 同步系统（或一段定期跑的脚本）会负责"任何新出
现的 alias 都按某种规则归到正确的 Entity 下"，把 §3 的隐式建 entity
默认行为完全替换掉。
