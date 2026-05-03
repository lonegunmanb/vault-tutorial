# 第一步：启动 MiniStack，启用 aws 认证并指向本地 STS / IAM

[4.3 章 §2](/ch4-aws) 的核心机制：iam 方法**Vault 把客户端签好的
请求转发给 AWS STS** 让 AWS 做最终判定。我们把"AWS"换成跑在本机的
MiniStack——同样讲 STS / IAM API，登录链路就能在本地真实跑通。

## 1.1 启动 MiniStack

```bash
docker run -d --name ministack -p 4566:4566 ministackorg/ministack
```

镜像在准备阶段已预拉，1-2 秒即起。等容器健康：

```bash
sleep 3
curl -s http://127.0.0.1:4566/_localstack/health | jq '.services | {iam, sts}'
```

应看到 `iam` / `sts` 都是 `"available"`——这就是 Vault iam 认证流程
要打的两个服务。

## 1.2 用 AWS CLI 直连 MiniStack 确认它能讲 STS

先给 AWS CLI 配一对凭据——MiniStack 接受任意 SigV4 签名，但 CLI 自己
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
    "UserId": "000000000000",
    "Account": "000000000000",
    "Arn": "arn:aws:iam::000000000000:root"
}
```

> 这正是 [4.3 章 §2](/ch4-aws) 引的"signs a `GetCallerIdentity` query
> ... sends it to the Vault server" 那条流程的客户端侧——只不过我们
> 直接打 MiniStack 看一眼它返回什么。这里返回的是 root ARN，只能
> 证明 STS 能用；Vault 的 iam 登录路径不能把 `root` 当普通 IAM
> principal 解析，下一步会先建一个真正的 IAM user 再绑定 role。

## 1.3 起一个 STS Content-Type 改写 sidecar

MiniStack 的 STS 响应用 `Content-Type: application/xml`，而 Vault
1.19 的 `submitCallerIdentityRequest` 对这个 header 做**严格等于**
`text/xml` 的检查（源码 `path_login.go`）——不匹配就会被拒，
报个误导性很强的 `body of GetCallerIdentity is invalid`。body 实
际是好的，仅 header 不合。

写一个不到 30 行的 Python shim：监 4567，透传到 4566，仅把
`application/xml` 重写为 `text/xml`：

```bash
cat > /root/sts-shim.py <<'PY'
#!/usr/bin/env python3
import http.server, urllib.request, urllib.error
UPSTREAM = "http://127.0.0.1:4566"

class H(http.server.BaseHTTPRequestHandler):
    def _proxy(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else None
        hdrs = {k: v for k, v in self.headers.items() if k.lower() != "host"}
        req = urllib.request.Request(UPSTREAM + self.path, data=body,
                                     method=self.command, headers=hdrs)
        try:
            r = urllib.request.urlopen(req)
            status, headers, data = r.status, r.headers, r.read()
        except urllib.error.HTTPError as e:
            status, headers, data = e.code, e.headers, e.read()
        self.send_response(status)
        for k, v in headers.items():
            if k.lower() in ("transfer-encoding", "content-length", "content-type"):
                continue
            self.send_header(k, v)
        ct = headers.get("Content-Type", "")
        self.send_header("Content-Type", "text/xml" if ct == "application/xml" else ct)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = _proxy
    def log_message(self, *a, **kw): pass

http.server.ThreadingHTTPServer(("127.0.0.1", 4567), H).serve_forever()
PY
nohup python3 /root/sts-shim.py > /tmp/sts-shim.log 2>&1 &
sleep 1
```

验证改写生效（注意看 `Content-Type` 一行）：

```bash
curl -s -i -X POST http://127.0.0.1:4567/ \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data 'Action=GetCallerIdentity&Version=2011-06-15' \
  | grep -i '^content-type'
```

应看到 `Content-Type: text/xml`（如果 shim 没起来或上游挂了，这行就
出不来；可以 `cat /tmp/sts-shim.log` 看错）。这个 shim 只服务于 iam 认证这一
个场景——真 AWS 不需要它（AWS 本身就返 `text/xml`）。

## 1.4 启用 aws 认证方法

```bash
vault auth enable aws
vault auth list | grep aws
```

应看到 `aws/   aws    auth_xxxxx`——默认挂在 `auth/aws/` 下。

## 1.5 配 `config/client`：把 Vault 也指向 MiniStack

[4.3 章 §12](/ch4-aws) 讲过：`config/client` 里的 access_key /
secret_key 是 **Vault 自己**用来调 AWS API 的——不是登录方的。我们
让 Vault 用 MiniStack 的 root 凭据 `test/test`：IAM API 直接打 4566，
STS API 走 4567 那个只改写 Content-Type 的 shim：

```bash
vault write auth/aws/config/client \
    access_key=test \
    secret_key=test \
    endpoint=http://127.0.0.1:4566 \
    iam_endpoint=http://127.0.0.1:4566 \
    sts_endpoint=http://127.0.0.1:4567 \
    sts_region=us-east-1 \
    iam_server_id_header_value=vault.example.com
```

每个字段含义：

| 字段 | 含义 |
| :--- | :--- |
| `access_key` / `secret_key` | Vault 调 AWS 用的凭据；MiniStack 接受任意 SigV4 签名，但仍需要这对 key 让 Vault SDK 走完签名流程 |
| `endpoint` | EC2 服务端点（`ec2:DescribeInstances` 用） |
| `iam_endpoint` | IAM 服务端点（`iam:GetUser` / `iam:GetRole` 等用） |
| `sts_endpoint` | STS 服务端点——**iam 认证流程的关键**。指向 4567 那个 Content-Type 改写 shim，而不是直接打 4566 |
| `sts_region` | 强制 Vault 把转发请求当作发往这个 region 的 STS |
| `iam_server_id_header_value` | [4.3 章 §2](/ch4-aws) 那道额外防重放 header 的服务端值 |

回读：

```bash
vault read auth/aws/config/client
```

注意 `secret_key` 不会回显——`config/client` 把它当机密对待。
`iam_server_id_header_value` 应当显示为 `vault.example.com`。

## 1.6 这一步的核心闭环

到这里 Vault 与 MiniStack 已经"对上了"（中间隔了一个仅改写
Content-Type 的 shim）——`auth/aws/login` 现在是个能真正打通 STS
的端点。下一步建 role + 真实登录一次。
