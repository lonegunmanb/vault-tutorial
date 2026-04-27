# 第二步：CA 模式端到端——容器作 sshd，故意先撞两个常见错误

这一步把 CA 模式跑通：用 docker 启一个 ubuntu 容器作目标主机，配
sshd 信任 Step 1 那把 CA，创建签发 role，签客户端证书，ssh 进去。

我们**故意先用最小 role 配置**，让 [3.5 章 §8](/ch3-ssh) 那张错误对
照表里两条最常见的错误真的发生在你眼前，再补上正确字段。

## 2.1 启动目标 sshd 容器（信任 CA 公钥）

容器把宿主机的 `/root/trusted-user-ca-keys.pem` 挂到
`/etc/ssh/trusted-user-ca-keys.pem`（只读），sshd_config 里写
`TrustedUserCAKeys` 指向它。**所有改动都在容器里，宿主机的 sshd 完全
没动**。

```bash
docker rm -f ssh-target-ca > /dev/null 2>&1 || true

docker run -d --name ssh-target-ca \
  -p 2222:22 \
  -v /root/trusted-user-ca-keys.pem:/etc/ssh/trusted-user-ca-keys.pem:ro \
  ubuntu:24.04 \
  bash -c '
    apt-get update -qq && apt-get install -y -qq openssh-server > /dev/null
    useradd -m -s /bin/bash ubuntu
    passwd -d ubuntu > /dev/null
    mkdir -p /var/run/sshd
    cat > /etc/ssh/sshd_config <<EOF
Port 22
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem
LogLevel VERBOSE
EOF
    ssh-keygen -A > /dev/null 2>&1
    exec /usr/sbin/sshd -D -e
  '
```

等 sshd 起来（apt 安装大约 20–40 秒）：

```bash
for i in $(seq 1 60); do
  ssh -o ConnectTimeout=1 -o StrictHostKeyChecking=no -o BatchMode=yes \
      -p 2222 ubuntu@127.0.0.1 true 2>&1 | grep -q "Permission denied" && break
  sleep 1
done
echo "sshd ready"
```

> 看到 "Permission denied" 反而是好消息——说明 sshd 已经在监听并按
> 公钥/证书规则在拒绝我们（因为还没签证书）。容器里的 sshd 起来了，
> Step 2 后面所有失败都是 Vault role 配置层面的问题，跟 sshd 无关。

## 2.2 创建签发 role（最小配置——故意有坑）

```bash
vault write ssh-client-signer/roles/my-role \
    key_type=ca \
    allow_user_certificates=true \
    allowed_users="*" \
    ttl=5m
```

只有四个字段——故意**没写 `default_user`，没写 `default_extensions`**。
[3.5 章 §4.3](/ch3-ssh) 提示过这两个是新手最容易漏的，下面就让你看
看漏了会发生什么。

## 2.3 第一次签证书：撞上 "empty valid principals not allowed by role"

```bash
vault write -field=signed_key ssh-client-signer/sign/my-role \
    public_key=@/root/.ssh/id_rsa.pub > /root/.ssh/id_rsa-cert.pub
```

立刻就报错了，**连证书都没签出来**：

```
Error writing data to ssh-client-signer/sign/my-role: Error making API request.

URL: PUT http://127.0.0.1:8200/v1/ssh-client-signer/sign/my-role
Code: 400. Errors:

* empty valid principals not allowed by role
```

这是 Vault SSH 引擎的一道前置防线，[官方 API 文档](https://developer.hashicorp.com/vault/api-docs/secret/ssh#sign-ssh-key)
里 `valid_principals` 参数原文是这么写的：

> **Required unless the role has specified `allow_empty_principals`
> or a value has been set for either the `default_user` or
> `default_user_template` role parameters.**

也就是说：**只要 role 既没设 `default_user`、签发请求又没传
`valid_principals`，签出来的证书 principals 列表就会是空的——这种证
书 sshd 必然拒收**（[官方 troubleshooting "Name is not a listed
principal"](https://developer.hashicorp.com/vault/docs/secrets/ssh/signed-ssh-certificates#name-is-not-a-listed-principal)
专门讲过这条 OpenSSH 行为）。Vault 干脆在签发时就把这种"注定签出来
也用不了"的情况堵掉，给出更清楚的错误信息。

> 同一份 API 文档里还列了一个 role 参数：
> [`allow_empty_principals (bool: false)`](https://developer.hashicorp.com/vault/api-docs/secret/ssh#allow_empty_principals)，
> 说明文字是 _"Allow signing certificates with no valid principals
> (e.g. any valid principal). **For backwards compatibility only. The
> default of false is highly recommended.**"_——这就是上面那条防线的
> "总开关"。**生产环境永远不要把它设成 true**。

不管怎样，根本原因都一样：**没人告诉证书"它能登哪个 Linux 用
户"**。下一小节修。

## 2.4 修复 1：补上 default_user，签发成功

```bash
vault write ssh-client-signer/roles/my-role \
    key_type=ca \
    allow_user_certificates=true \
    allowed_users="*" \
    default_user=ubuntu \
    ttl=5m

# 这次能签出来了
vault write -field=signed_key ssh-client-signer/sign/my-role \
    public_key=@/root/.ssh/id_rsa.pub > /root/.ssh/id_rsa-cert.pub

# 看一眼证书，Principals 这次应该有 "ubuntu"
ssh-keygen -L -f /root/.ssh/id_rsa-cert.pub | grep -A1 Principals
```

再登一次（**这次故意不传命令，登交互式 shell**）：

```bash
ssh -o StrictHostKeyChecking=no -i /root/.ssh/id_rsa \
    -p 2222 ubuntu@127.0.0.1
```

会看到这样的输出，然后**会话就卡在那里不动**：

```
PTY allocation request failed on channel 0
```

**这是预期现象**——sshd 拒绝分配伪终端（PTY）后，OpenSSH 客户端不会
自动断开，而是停在那里等你输命令（因为通道本身是开着的，stdin/stdout
还能用）。

**按 `Ctrl-D`（或者 `Ctrl-C` 也行）退出**这个卡住的会话，回到宿主
机的 shell。

跑个**带命令的非交互式**登录验证一下基本通道是通的：

```bash
ssh -o StrictHostKeyChecking=no -i /root/.ssh/id_rsa \
    -p 2222 ubuntu@127.0.0.1 "whoami; hostname"
```

应该能正常输出 `ubuntu` 和容器 hostname——说明**证书是合法的，登录
本身成功了**，问题只是没有 PTY 权限就开不了 shell。

## 2.5 修复 2：加上 permit-pty，再试交互式登录

`default_extensions` 是个 map 类型，**不能**用 `default_extensions='{"permit-pty":""}'`
这种内联字符串写法（CLI 不会把它解析成 map，会报
`expected a map, got 'string'`）。官方推荐用 heredoc JSON：

```bash
vault write ssh-client-signer/roles/my-role - <<EOF
{
  "key_type": "ca",
  "allow_user_certificates": true,
  "allowed_users": "*",
  "default_user": "ubuntu",
  "default_extensions": { "permit-pty": "" },
  "ttl": "5m0s"
}
EOF

vault write -field=signed_key ssh-client-signer/sign/my-role \
    public_key=@/root/.ssh/id_rsa.pub > /root/.ssh/id_rsa-cert.pub

# 看一眼证书的 Extensions，应该出现 permit-pty
ssh-keygen -L -f /root/.ssh/id_rsa-cert.pub | grep -A4 Extensions
```

> `vault write <path> -` 是 Vault CLI 的语法：用 `-` 作末尾参数表示
> "请求体从 stdin 读"，再用 heredoc 把 JSON 喂进去。涉及 map / 嵌套
> 结构的 role 配置都建议这么写。

现在交互式登录应该工作了：

```bash
ssh -o StrictHostKeyChecking=no -i /root/.ssh/id_rsa \
    -p 2222 ubuntu@127.0.0.1
```

进去后看一下：

```bash
whoami       # ubuntu
hostname     # 容器 ID 前 12 位
ls /etc/ssh/ # 注意 trusted-user-ca-keys.pem 在那儿——这就是证书被信任的根因
exit
```

## 2.6 看一下证书的完整结构

> ⚠️ 上一步 `ssh ... ubuntu@127.0.0.1` 让你**进了容器**——容器里没有
> `/root/.ssh/id_rsa-cert.pub`（那个文件在宿主机上）。先 `exit` 退出
> 容器回到宿主机 shell，再执行下面的命令。

```bash
ssh-keygen -L -f /root/.ssh/id_rsa-cert.pub
```

逐字段解读：

| 字段 | 含义 |
| :--- | :--- |
| `Type: ssh-rsa-cert-v01@openssh.com user certificate` | 用户证书（区别于 host 证书，Step 3 见） |
| `Public key: RSA-CERT SHA256:...` | 客户端 id_rsa.pub 的指纹 |
| `Signing CA: RSA SHA256:...` | 签发 CA 的指纹——sshd 用 TrustedUserCAKeys 文件里的公钥来核对这个 |
| `Key ID: "vault-token-<token accessor 的 hash>"` | Vault 自动写入，对应**签发这张证书的 token**——在审计日志里能直接定位到是谁签的 |
| `Serial: <数字>` | Vault 自增，用于撤销与对账 |
| `Valid: from ... to ...` | TTL 决定的窗口（5 分钟） |
| `Principals: ubuntu` | sshd 用它来匹配登录用户名 |
| `Extensions: permit-pty` | 给登入会话加上交互式 shell 能力 |

## 2.7 sshd 完全没看到客户端公钥

最关键的一条认知闭环——**故意保留 stderr**，让"目录不存在"这条错
误亲自打到你眼前：

```bash
docker exec ssh-target-ca ls -la /home/ubuntu/.ssh
```

会看到：

```
ls: cannot access '/home/ubuntu/.ssh': No such file or directory
```

容器里 `ubuntu` 用户的 `authorized_keys` **根本不存在**。它对"哪
些客户端能登"一无所知，全靠 `TrustedUserCAKeys` 那一行配置 + Vault
签出来的证书。

> 这就是 [3.5 章 §3](/ch3-ssh) 那张架构图里"零账户态"的字面意义：加
> 新用户、撤旧用户全在 Vault 里做，目标主机是哑的。

下一步给 host key 也签一份证书，把 `known_hosts` 那个 yes/no 提示也
干掉。
