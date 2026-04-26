# 第一步：挂载点的本质与迁移动机

在动手迁移之前，先理解 Vault 挂载点的底层模型。

## 1.1 什么是挂载点

Vault 中所有的机密引擎和认证方法都通过一个 **路径** 挂载到 Vault 的 API 路由树上。当你执行 `vault secrets enable -path=secret kv` 时，Vault 在内部注册了 `secret/` 这个路径前缀，之后所有发往 `secret/*` 的 API 请求都交给 KV 引擎处理。

查看当前所有机密引擎的挂载信息：

```bash
vault secrets list -detailed
```

输出中几个关键字段：

- `Path`：挂载路径（即 API 前缀）
- `Accessor`：挂载点的内部唯一标识，不随路径变化
- `UUID`：底层存储的标识

注意 `Accessor`——它是 Vault 在存储层面识别引擎的标识。**Mount Migration 本质上就是把这个 Accessor 指向的底层存储，从旧路径映射到新路径**，而不是复制数据。

## 1.2 查看认证方法的挂载信息

```bash
vault auth list -detailed
```

同样的结构——每个认证方法也有自己的 `Path`、`Accessor`、`UUID`。

## 1.3 为什么需要迁移

常见的生产场景：

| 场景 | 例子 |
| :--- | :--- |
| **命名规范统一** | 早期用 `secret/`，后来公司规范要求 `kv-prod/` |
| **团队拆分** | 一个 `secret/` 下混着 A、B 两个团队的数据，要拆成 `team-a/` 和 `team-b/` |
| **遗留系统下线** | `legacy-kv/` 里还有数据没迁走，但想换一个更清晰的路径 |
| **认证方法整理** | `old-login/` 这个路径名太含糊，想重命名为 `corp-userpass/` |

在没有 Mount Migration 之前，这些需求要通过**手动脚本逐条导出导入**来实现——不但慢，还有以下风险：

- 导出与导入之间的时间窗口内，数据可能被修改
- 引擎下挂载的角色（如 AppRole role、数据库 role）无法简单导出
- 过程中需要同时维护两套 Policy
- 操作中断会导致"两头都不完整"的灾难

## 1.4 验证预置数据

在开始迁移前，确认环境中的数据完好：

```bash
echo "=== secret/ 下的数据 ==="
vault kv list secret/app-team-a/
vault kv get -format=json secret/app-team-a/db | jq .data.data

echo ""
echo "=== legacy-kv/ 下的数据 ==="
vault kv get -format=json legacy-kv/old-service | jq .data.data

echo ""
echo "=== userpass 用户 ==="
vault list auth/userpass/users/

echo ""
echo "=== old-login 用户 ==="
vault list auth/old-login/users/

echo ""
echo "=== 当前 policy ==="
vault policy read app-team-a-read
```

记住此刻的状态——下一步你将把 `legacy-kv/` 整体迁移到 `archive/`。
