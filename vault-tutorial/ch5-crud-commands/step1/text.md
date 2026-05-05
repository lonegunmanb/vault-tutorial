# 第一步：路径即 API 入口：read 与 list

先观察 `read`：它会对你给出的路径发起读取请求。这个路径不是本地文件路径，而是 Vault API 路由树里的入口。

读取当前 token 的信息：

```bash
vault read auth/token/lookup-self
```

同一个路径可以用 JSON 输出，方便脚本处理：

```bash
vault read -format=json auth/token/lookup-self | jq '.data | {display_name, policies, ttl}'
```

只取一个字段时，用 `-field`：

```bash
vault read -field=display_name auth/token/lookup-self
echo
```

再观察 `list`：它列出路径下面的 key，而不是读取每个 key 的内容。

```bash
vault list identity/entity/id
```

如果你想看列表中某个 Entity 的详情，可以把 ID 拼回 `read` 路径：

```bash
ENTITY_ID=$(vault list -format=json identity/entity/id | jq -r '.[0]')
vault read identity/entity/id/$ENTITY_ID
```

到这里先记住一个分工：`read` 看一个具体路径返回什么，`list` 看一个目录路径下有哪些 key。
