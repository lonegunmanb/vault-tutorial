# 第一步：启用 TOTP 引擎，搞清两个核心端点

[3.12 章 §1](/ch3-totp) 讲过：TOTP 引擎按 TOTP 标准生成 time-based
credentials，也可以生成新 key 并验证由这把 key 生成的 password。它
对外只暴露两条核心路径——`totp/keys/...`（管 key 定义）和
`totp/code/...`（出/验 code）。这一步先把引擎挂上、把这两条路径的
角色分清楚，后续 Step 2、Step 3 都依赖它。

## 1.1 挂载 TOTP 引擎

按官方文档的命名约定挂在 `totp/`：

```bash
vault secrets enable totp
```

`secrets list` 一眼确认：

```bash
vault secrets list | grep totp
```

应该能看到一行 `totp/    totp    totp_xxxxx`。这跟其它任何引擎挂载没
区别——TOTP 引擎在路由表里就是个普通插件。

> 默认挂在与引擎名同名的 `totp/` 路径下；如果想挂在别的路径，加一个
> `-path=` 参数即可，例如 `vault secrets enable -path=mfa totp`。
> 本实验后续命令都假设默认 `totp/` 路径。

## 1.2 看一眼挂载之后的"零状态"

刚挂上的 TOTP 引擎里**一个 key 都没有**。`vault list` 一下：

```bash
vault list totp/keys
```

会得到：

```
No value found at totp/keys/
```

> "No value" 是 Vault CLI 对"路径存在但当前没数据"的标准回答。这个
> 输出本身证明引擎已经挂好——只是 `totp/keys/` 这个 LIST 端点目前
> 里面没条目。

试试在没建 key 的情况下读 `/code`：

```bash
vault read totp/code/no-such-key
```

会立刻返回 `unknown key: no-such-key`。**`totp/keys/...` 是 key 定义
所在，`totp/code/...` 完全寄生在 key 上**——没有 key，就没有 code。
这是后面两步的核心心智模型。

## 1.3 把两个端点的角色画到表里

| 端点 | 角色 | 写谁 / 读谁 |
| :--- | :--- | :--- |
| `totp/keys/<name>` | **key 定义管理面** | `vault write` 建 key（generator 喂 url / provider `generate=true`），`vault read` 看 key 元数据，`vault list` 列所有 key，`vault delete` 删 key |
| `totp/code/<name>` | **凭据出/验面** | Generator 模式 `vault read` 出 code；Provider 模式 `vault write code=<...>` 验 code |

两条路径在 ACL 层完全可以**单独授权**——这就是 [3.12 章 §5](/ch3-totp)
那条权限边界的字面落地，Step 4 我们会实际演示。

## 1.4 不创建 key 直接 list 一下其它端点

```bash
vault read totp/keys/no-such-key 2>&1
```

会拿到 `No value found at totp/keys/no-such-key`——读不存在的 key
返回 "no value"，跟"读不存在的 code"返回 `unknown key` 是两套错误
路径，因为 Vault CLI 把 read 端点的"没数据"和"未知名字"区分开了。

> 这是个有用的细节：实操中如果 `vault read totp/code/<name>` 报
> `unknown key`，说明你**还没在 `totp/keys/<name>` 写 key**；
> 如果 `vault read totp/keys/<name>` 报 `No value found`，说明
> **key 名字打错了或被删了**。

下一步进入 Generator 模式：让 Vault 接手第三方服务签发的 otpauth URL，
替你按时算 TOTP code。
