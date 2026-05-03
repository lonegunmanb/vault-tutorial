# 第一步：启动 LocalStack，启用 aws 认证并指向本地 STS / IAM

[4.3 章 §2](/ch4-aws) 的核心机制：iam 方法**Vault 把客户端签好的
请求转发给 AWS STS** 让 AWS 做最终判定。我们把"AWS"换成跑在本机的
LocalStack——同样讲 STS / IAM API，登录链路就能在本地真实跑通。

## 1.1 启动 LocalStack

```bash
docker run -d --name localstack -p 4566:4566 -e SERVICES=iam,sts,ec2 localstack/localstack:3
```

镜像在准备阶段已预拉。等容器健康：

```bash
sleep 3
curl -s http://127.0.0.1:4566/_localstack/health | jq '.services | {iam, sts}'
```

应看到 `iam` / `sts` 都是 `"available"`——这就是 Vault iam 认证流程
要打的两个服务。

## 1.2 用 AWS CLI 直连 LocalStack 确认它能讲 STS

先给 AWS CLI 配一对凭据——LocalStack 接受任意 SigV4 签名，但 CLI 自己
要看到 key 才肯发请求：

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
aws --endpoint-url=http://127.0.0.1:4566 sts get-caller-identity
```

应返回：

```json
{
    "UserId": "AKIAIOSFODNN7EXAMPLE",
    "Account": "000000000000",
    "Arn": "arn:aws:iam::000000000000:root"
}
```

> 这正是 [4.3 章 §2](/ch4-aws) 引的"signs a `GetCallerIdentity` query
> ... sends it to the Vault server" 那条流程的客户端侧——只不过我们
> 直接打 LocalStack 看一眼它返回什么。这里返回的是 root ARN，只能
> 证明 STS 能用；Vault 的 iam 登录路径不能把 `root` 当普通 IAM
> principal 解析，下一步会先建一个真正的 IAM user 再绑定 role。

## 1.3 启用 aws 认证方法

```bash
vault auth enable aws
vault auth list | grep aws
```

应看到 `aws/   aws    auth_xxxxx`——默认挂在 `auth/aws/` 下。

## 1.4 配 `config/client`：把 Vault 也指向 LocalStack

[4.3 章 §12](/ch4-aws) 讲过：`config/client` 里的 access_key /
secret_key 是 **Vault 自己**用来调 AWS API 的——不是登录方的。我们
让 Vault 用 LocalStack 的 root 凭据 `test/test`，并通过 `sts_endpoint`
/ `iam_endpoint` 把所有 AWS API 调用打到本地 4566：

```bash
vault write auth/aws/config/client \
    access_key=test \
    secret_key=test \
    endpoint=http://127.0.0.1:4566 \
    iam_endpoint=http://127.0.0.1:4566 \
    sts_endpoint=http://127.0.0.1:4566 \
    sts_region=us-east-1 \
    iam_server_id_header_value=vault.example.com
```

每个字段含义：

| 字段 | 含义 |
| :--- | :--- |
| `access_key` / `secret_key` | Vault 调 AWS 用的凭据；LocalStack 接受任意 SigV4 签名，但仍需要这对 key 让 Vault SDK 走完签名流程 |
| `endpoint` | EC2 服务端点（`ec2:DescribeInstances` 用） |
| `iam_endpoint` | IAM 服务端点（`iam:GetUser` / `iam:GetRole` 等用） |
| `sts_endpoint` | STS 服务端点（验签 `GetCallerIdentity` 用）——**iam 认证流程的关键** |
| `sts_region` | 强制 Vault 把转发请求当作发往这个 region 的 STS |
| `iam_server_id_header_value` | [4.3 章 §2](/ch4-aws) 那道额外防重放 header 的服务端值 |

回读：

```bash
vault read auth/aws/config/client
```

注意 `secret_key` 不会回显——`config/client` 把它当机密对待。
`iam_server_id_header_value` 应当显示为 `vault.example.com`。

## 1.5 这一步的核心闭环

到这里 Vault 与 LocalStack 已经"对上了"——`auth/aws/login` 现在是个
能真正打通 STS 的端点。下一步建 role + 真实登录一次。
