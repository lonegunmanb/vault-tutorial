# 第三步：删除对象：delete 的后端语义

先列出 Cubbyhole 里现在有哪些 key：

```bash
vault list cubbyhole/
```

删除刚才写入的一条凭据：

```bash
vault delete cubbyhole/git-credentials
vault read cubbyhole/git-credentials || true
```

你会看到读取已删除路径时返回找不到数据。对 Cubbyhole 来说，这就是删除该路径的数据。

再看 Transit key。Transit 为了避免误删加密密钥，默认不允许直接删除 key。先确认当前状态：

```bash
vault read transit/keys/crud-demo | grep deletion_allowed
```

把 `deletion_allowed` 改为 `true`，再删除 key：

```bash
vault write transit/keys/crud-demo/config deletion_allowed=true
vault delete transit/keys/crud-demo
vault read transit/keys/crud-demo || true
```

这就是 `delete` 最重要的经验：命令只是发出 HTTP DELETE，真正决定“删什么、能不能删、删完是什么状态”的，是后端引擎自己的规则。
