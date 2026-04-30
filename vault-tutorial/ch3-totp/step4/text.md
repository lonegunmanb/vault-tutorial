# 第四步：进阶参数 + ACL 把"管 key"与"读 code"真正拆开

[3.12 章 §5](/ch3-totp) 引用了官方文档原文：

> _Using ACLs, it is possible to restrict using the TOTP secrets engine
> such that **trusted operators can manage the key definitions**, and
> both **users and applications are restricted in the credentials they
> are allowed to read**._

Step 1 在心智模型上就预告了：`totp/keys/...` 是管理面，`totp/code/...`
是凭据面，二者可以单独授权。这一步先把 provider 模式的几个进阶参数
（period / digits / algorithm / skew）过一遍——它们就是 ACL 之上**到
底允许 operator 创建什么形态的 key**——再创两条 policy 把权限边界
真正立起来，用两个独立 token 验证。

## 4.1 调 period：换一个 10 秒一变的短窗口 key

默认 `period=30`。生产里如果 issuer 要求更短的窗口（比如某些金融场
景要求 10s），可以这样建：

```bash
vault write -format=json totp/keys/short-period \
    generate=true \
    issuer=Vault \
    account_name=ops@test.com \
    period=10 \
    > /root/short-period.json

# 抠出 secret
SECRET=$(jq -r '.data.url' /root/short-period.json | grep -oE 'secret=[^&]+' | cut -d= -f2)

# oathtool 算 TOTP 时也要把 time-step-size 调成 10
CODE=$(oathtool --totp --time-step-size=10 -b "$SECRET")
echo "短窗口 TOTP: $CODE"

# 让 Vault 验
vault write totp/code/short-period code=$CODE
```

应该 `valid=true`。

> 注意 oathtool 算 TOTP 时**必须传一致的 `--time-step-size=10`**，
> 否则它默认按 30s 窗口算，跟 Vault 的 10s 窗口对不齐，永远算出
> 不一样的数字。这条是 TOTP 集成里最容易被忘掉的踩坑点：**period
> 必须双方一致**。

## 4.2 调 digits + algorithm：换 8 位 SHA256 的 TOTP

默认 `digits=6` + `algorithm=SHA1`。RFC 6238 也支持 8 位和 SHA256 /
SHA512。一些更新的 SaaS（特别是 SSO 类）会用 8 位 + SHA256：

```bash
vault write -format=json totp/keys/sha256-8d \
    generate=true \
    issuer=Vault \
    account_name=admin@test.com \
    algorithm=SHA256 \
    digits=8 \
    > /root/sha256-8d.json

SECRET=$(jq -r '.data.url' /root/sha256-8d.json | grep -oE 'secret=[^&]+' | cut -d= -f2)

# oathtool 同步切到 sha256 + 8 位
CODE=$(oathtool --totp=sha256 --digits=8 -b "$SECRET")
echo "SHA256 / 8 位 TOTP: $CODE"

vault write totp/code/sha256-8d code=$CODE
```

应该看到 `valid=true`，并且这次的 `code` 是 8 位数。

> oathtool 的 `--totp=sha256` 写法是 `--totp` 后面带 `=` 直接指定算法
> （不要写 `--totp sha256`，会被当成两个独立参数）。

## 4.3 调 skew=0：把容忍窗口从 90 秒收紧到 30 秒

[Step 3.7](#) 演示了默认 `skew=1` 时 code 有 ~90s 的容忍窗口。生产
有时希望更严格：

```bash
vault write -format=json totp/keys/strict-skew \
    generate=true \
    issuer=Vault \
    account_name=strict@test.com \
    skew=0 \
    > /root/strict-skew.json

SECRET=$(jq -r '.data.url' /root/strict-skew.json | grep -oE 'secret=[^&]+' | cut -d= -f2)

# 算一份 code，立刻验证 → 应该 valid=true
CODE=$(oathtool --totp -b "$SECRET")
vault write totp/code/strict-skew code=$CODE

# 等 35 秒，让窗口走过 1 个 → 严格模式下立刻拒
sleep 35
vault write totp/code/strict-skew code=$CODE
```

第二次几乎一定 `valid=false`——这跟 Step 3.7 默认 skew=1 时"等 30s
依然 valid=true"形成直接对照。

> **生产建议**：如果上下游时钟用 NTP 同步得很可靠，把 `skew=0` 收
> 严最安全；如果用户手机时钟可能漂移（出国旅游、刷机），保留
> 默认 `skew=1` 以减少假拒。

## 4.4 list 当前所有 key + 删除一个

```bash
vault list totp/keys
```

应该看到 4 个 key：

```
Keys
----
my-key
my-user
short-period
sha256-8d
strict-skew
```

（顺序可能不一样。）

随便挑一个删：

```bash
vault delete totp/keys/short-period

vault list totp/keys

# 读已删除的 key 立刻报 unknown
vault read totp/code/short-period
```

最后那一条会回 `unknown key: short-period`——seed 已经被从 storage
里物理删除，**这把 key 永远拿不回来了**。如果是 provider 模式，下
游所有用户的 authenticator app 此刻就全部失效了。

> 这一条很重要：provider 模式删 key = 强制吊销该用户的整个 TOTP 注
> 册。如果只是想换一把 seed，正确做法是建一个**新名字**的 key，把
> 新的 barcode 发给用户重新注册，**等用户都迁过去再删旧 key**。

## 4.5 真正用 ACL 拆开"管 key 的 operator"和"读/验 code 的 user"

到这一刻为止我们一直用 root token，权限分割只是文字描述。下面创两
条 policy 让它落到字面：

### 4.5.1 写两条最小 policy

```bash
# operator：只能管 key 定义（CRUD totp/keys/...，看不到 code）
cat > /tmp/totp-operator.hcl <<'EOF'
path "totp/keys/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "totp/keys" {
  capabilities = ["list"]
}
EOF
vault policy write totp-operator /tmp/totp-operator.hcl

# user：完全相反，只能在 totp/code/... 上 read（generator）和 update（provider 验证）
cat > /tmp/totp-user.hcl <<'EOF'
path "totp/code/*" {
  capabilities = ["read", "update"]
}
EOF
vault policy write totp-user /tmp/totp-user.hcl
```

> Vault 的 `vault write` 操作对应 policy 里的 `update` capability；
> `vault read` 对应 `read`。所以 user policy 这两个加起来 = generator
> 读 code + provider 验 code 都能做，但**碰不了 keys 的任何路径**。

### 4.5.2 用 operator token 试

```bash
OP_TOKEN=$(vault token create -policy=totp-operator -ttl=1h -field=token)
echo "operator token: $OP_TOKEN"
```

切换到 operator token 试一遍：

```bash
VAULT_TOKEN=$OP_TOKEN vault list totp/keys

VAULT_TOKEN=$OP_TOKEN vault write totp/keys/op-key \
    generate=true \
    issuer=Vault \
    account_name=op@test.com

# 试着读个 code → 应该被 ACL 当场拒
VAULT_TOKEN=$OP_TOKEN vault read totp/code/op-key
```

最后一条会被拒：

```
Error reading totp/code/op-key: Error making API request.

URL: GET http://127.0.0.1:8200/v1/totp/code/op-key
Code: 403. Errors:

* 1 error occurred:
        * permission denied
```

operator 能建 key，**但拿不到 code**——意味着即使 operator token 被
盗，攻击者也没法用这把 token 直接登录任何 TOTP 受保护的服务。

### 4.5.3 用 user token 试

```bash
USR_TOKEN=$(vault token create -policy=totp-user -ttl=1h -field=token)
echo "user token: $USR_TOKEN"
```

```bash
# 读 generator key 的 code → OK
VAULT_TOKEN=$USR_TOKEN vault read totp/code/my-key

# 验 provider key 的 code → OK
SECRET=$(jq -r '.data.url' /root/my-user-key.json | grep -oE 'secret=[^&]+' | cut -d= -f2)
CODE=$(oathtool --totp -b "$SECRET")
VAULT_TOKEN=$USR_TOKEN vault write totp/code/my-user code=$CODE

# 试着改 key 定义 → 被 ACL 拒
VAULT_TOKEN=$USR_TOKEN vault write totp/keys/my-user \
    generate=true issuer=Vault account_name=hacker@evil.com
```

最后一条会被拒：

```
Error writing data to totp/keys/my-user: Error making API request.

URL: PUT http://127.0.0.1:8200/v1/totp/keys/my-user
Code: 403. Errors:

* 1 error occurred:
        * permission denied
```

user 能正常生 / 验 code，**但永远改不了 key 定义**。这两个分工合在
一起就是 [3.12 章 §5](/ch3-totp) 那条 ACL 边界的字面落地：seed 的
"造 / 删 / 换"由 operator 团队负责，"用"由用户和应用负责，**两边
互不越权**。

## 4.6 清理实验资源（可选）

Dev 模式重启就全没了，所以严格说不用清。手动清干净的话：

```bash
# 撤销两个临时 token
vault token revoke "$OP_TOKEN"
vault token revoke "$USR_TOKEN"

# 删两条 policy
vault policy delete totp-operator
vault policy delete totp-user

# 删所有 key
for k in $(vault list -format=json totp/keys 2>/dev/null | jq -r '.[]'); do
  vault delete totp/keys/$k
done
vault list totp/keys || echo "✓ 无残留 key"

# 禁掉 totp 引擎
vault secrets disable totp
vault secrets list | grep -E "^totp/" || echo "✓ totp 引擎已禁用"

# 把宿主机上几个临时文件也清了
rm -f /root/my-user-key.json /root/my-user-qr.png \
      /root/short-period.json /root/sha256-8d.json /root/strict-skew.json \
      /tmp/totp-operator.hcl /tmp/totp-user.hcl
```

下一节给一张 4 步全景图做收尾。
