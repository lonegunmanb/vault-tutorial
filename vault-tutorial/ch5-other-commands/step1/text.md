# 第一步：用 `path-help` 读取当前路由帮助

`vault path-help` 用于从当前 Vault 服务器读取某条路径的内置帮助。它不是查看本地手册，而是询问当前已经启用的后端：这条路径支持哪些子路径、参数和动作。

先查看 `database/` 后端的总体帮助：

```bash
vault path-help database
```

输出中会出现后端描述和可匹配的路径。由于这些路径通常用正则表达式表示，第一次阅读时不需要逐字记忆，只要先理解它们是在描述“这个后端能够处理哪些 API 路径”。

继续查看更具体的动态凭据路径：

```bash
vault path-help database/creds/readonly
```

重点观察输出中的 `DESCRIPTION` 和 `PARAMETERS`。它们说明这条路径的用途，以及调用这条路径时可能涉及哪些参数。

最后查看系统租约查询路径：

```bash
vault path-help sys/leases/lookup
```

这一阶段的关键点是：当你不知道某个后端的 API 路径应如何书写时，先用 `path-help` 查询后端，再逐步缩小到具体路径。