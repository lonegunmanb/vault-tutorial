# 第三步：Host Key Signing——客户端不再回答 yes/no

## 3.0 先讲清楚：这一步在解决什么问题？

回想第一次 ssh 一台新机器时跳出来的那段对话：

```
The authenticity of host '[127.0.0.1]:2222' can't be established.
RSA key fingerprint is SHA256:abcd1234...
Are you sure you want to continue connecting (yes/no)?
```

意思是：**"我从来没见过这台机器，也没人告诉我它的指纹长什么样，你
确定要信吗？"** 你回 yes，客户端就把这条指纹记进
`~/.ssh/known_hosts`，下次自动放行。

这条交互在两种场景里很难维护：

1. **自动伸缩集群**——主机一直在增减，你没法手动 yes/no 每一台
2. **CI / 自动化脚本**——脚本不能跟你交互，多半被迫加上
   `StrictHostKeyChecking=no`，等于关掉了"防中间人"那道门

### 跟 Step 2 的对称关系

Step 2 解决了 **"服务器怎么信任客户端"**：sshd 配
`TrustedUserCAKeys`，认 Vault 签出来的 user 证书。

Step 3 反过来解决 **"客户端怎么信任服务器"**：客户端的 `known_hosts`
里写一行 `@cert-authority`，认 Vault 签出来的 host 证书。

| 方向 | 信任根存在哪 | 凭据是什么 |
| :--- | :--- | :--- |
| 服务器 ← 客户端（Step 2） | sshd 的 `TrustedUserCAKeys` | Vault 签的 **user** 证书 |
| 客户端 ← 服务器（Step 3） | 客户端 `known_hosts` 里一行 `@cert-authority` | Vault 签的 **host** 证书 |

> 类比：以前每见一个新人都要核对一次他的身份证（`known_hosts` 一台
> 一台记），现在改成"凡是公安局盖章的身份证我都信"
> （`@cert-authority` 一行管所有机器）。

下面这张图把整个过程类比成"机场登机口验票"，结合 §3.6 一起看更直
观：

![SSH host certificate verification, airport boarding-gate analogy](./assets/host-cert-airport.png)

下面分两件事来做：

1. **服务器侧**：让 Vault 给容器的 host key 签一张证书，sshd 启动时
   出示给客户端
2. **客户端侧**：在 `known_hosts` 写一行 `@cert-authority`，告诉 ssh
   "凡是这个 CA 签的 host 证书都信"

## 3.1 单独挂一个 host CA 引擎

Step 1 已经有了 `ssh-client-signer/`（专签 user 证书）。**主机证书**
按官方惯例再单独挂一个，让"谁能登"和"谁是合法主机"在审计日志里完全
分开：

```bash
vault secrets enable -path=ssh-host-signer ssh
vault write ssh-host-signer/config/ca generate_signing_key=true
```

> **为什么再挂一个？技术上完全可以复用 Step 1 那个 `ssh-client-signer/`
> 都签**——但运维上不推荐，原因有二：
>
> 1. **权限边界更清晰**：负责"发用户登录证书"的人和负责"发主机
>    身份证书"的人通常是不同团队（前者是平台/SRE，后者是配置管
>    理）。两个独立 mount 后，可以用 Vault 策略给两拨人**只**授权
>    自己那一把 CA，不会互相越权。
> 2. **撤销／轮换互不影响**：哪天怀疑 user CA 私钥泄漏要紧急轮换，
>    不会同时把所有主机证书也作废掉，反之亦然。
>
> 一句话："谁能登"和"谁是合法主机"是两件独立的事，对应两把独立
> 的 CA 更稳。

把这把 host CA 公钥导出来——**它就是 §3.5 客户端要写进 `known_hosts`
的那把**：

```bash
vault read -field=public_key ssh-host-signer/config/ca \
    > /root/host-trusted-ca.pem
cat /root/host-trusted-ca.pem
```

## 3.2 创建一个签 host 证书的 role

```bash
vault write ssh-host-signer/roles/hostrole \
    key_type=ca \
    allow_host_certificates=true \
    allowed_domains="localhost,127.0.0.1" \
    allow_bare_domains=true \
    allow_subdomains=true \
    ttl=24h
```

跟 Step 2 的 user role 比，关键差异：

| 字段 | 含义 |
| :--- | :--- |
| `allow_host_certificates=true` | 允许签**主机**证书（Step 2 那条是 `allow_user_certificates`） |
| `allowed_domains="localhost,127.0.0.1"` | 限制能给哪些主机名签证书——别让同一把 CA 满世界乱签 |
| `allow_bare_domains=true` | 放行**裸域名本身**（`localhost`、`127.0.0.1`） |
| `allow_subdomains=true` | 再放行子域名（`node1.localhost` 这种），方便后面真集群用 |
| `ttl=24h` | 主机证书一般给得宽——主机不会"撤权"那么频繁 |

> ⚠️ **`allow_bare_domains` 这条不加会撞错**：
>
> ```
> * 127.0.0.1 is not a valid value for valid_principals
> ```
>
> 因为 `allow_subdomains` 只放 `foo.localhost` 这种**子**域名，
> `localhost` / `127.0.0.1` 自己是裸域名，得另一个开关。

## 3.3 把容器的 host key 拿出来给 Vault 签

容器启动时 `ssh-keygen -A` 已经生成了 host key（在
`/etc/ssh/ssh_host_rsa_key`）。把**公钥**拷到宿主机：

```bash
docker exec ssh-target-ca cat /etc/ssh/ssh_host_rsa_key.pub \
    > /root/ssh_host_rsa_key.pub
cat /root/ssh_host_rsa_key.pub
```

让 Vault 签这把公钥：

```bash
vault write -field=signed_key ssh-host-signer/sign/hostrole \
    cert_type=host \
    public_key=@/root/ssh_host_rsa_key.pub \
    valid_principals="127.0.0.1,localhost" \
    > /root/ssh_host_rsa_key-cert.pub
```

两个跟 Step 2 不同的参数：

- `cert_type=host`：**告诉 Vault 这是张 host 证书**（默认是 user）
- `valid_principals="127.0.0.1,localhost"`：这张证书"代表"哪些主机
  名／IP——客户端 ssh 时用的那个 hostname 必须出现在这个列表里

看一眼证书：

```bash
ssh-keygen -L -f /root/ssh_host_rsa_key-cert.pub | head -20
```

重点看两行：

- `Type: ssh-rsa-cert-v01@openssh.com host certificate`（**host**，不
  是 user）
- `Principals: 127.0.0.1, localhost`

## 3.4 把 host 证书塞进容器，让 sshd 出示它

```bash
docker cp /root/ssh_host_rsa_key-cert.pub \
    ssh-target-ca:/etc/ssh/ssh_host_rsa_key-cert.pub
```

加一行 `HostCertificate` 配置——这就是 sshd 的"出示证书"开关：

```bash
docker exec ssh-target-ca bash -c '
    grep -q HostCertificate /etc/ssh/sshd_config || \
        echo "HostCertificate /etc/ssh/ssh_host_rsa_key-cert.pub" >> /etc/ssh/sshd_config
'

docker exec ssh-target-ca pkill -HUP sshd
sleep 1
```

> sshd 看到 `HostCertificate` 这一行后，握手时除了亮自己的 host 公
> 钥，还会把这张 Vault 签的证书一并递给客户端。

## 3.5 客户端：写一行 `@cert-authority`

先把 Step 2 在 `known_hosts` 里留下的旧指纹清掉（不然客户端会以"老
朋友"模式直接对老指纹，根本不走证书路径）：

```bash
ssh-keygen -R "[127.0.0.1]:2222" 2>/dev/null || true
```

写入信任根。这一行的含义是：**"凡是从 `[127.0.0.1]:2222` 出示的、
由这把 CA 签的 host 证书，我都信"**：

```bash
echo "@cert-authority [127.0.0.1]:2222 $(cat /root/host-trusted-ca.pem)" \
    >> /root/.ssh/known_hosts

cat /root/.ssh/known_hosts
```

格式拆开看：

```
@cert-authority   [127.0.0.1]:2222   ssh-rsa AAAA...（host CA 公钥）
↑                 ↑                   ↑
模式标记          匹配哪些 hostname    用哪把 CA 验证
```

## 3.6 验证：再 ssh，没有 yes/no 了

注意这次**完全不带 `StrictHostKeyChecking=no`**——也就是不再"强行
跳过检查"，让 ssh 真正去走 host key 校验：

```bash
ssh -i /root/.ssh/id_rsa -p 2222 ubuntu@127.0.0.1 "hostname"
```

直接打印容器 hostname，**没有任何提示**。

发生了什么：

1. 客户端连 `[127.0.0.1]:2222`，sshd 递过来 host key + Vault 签的
   host 证书
2. 客户端在 `known_hosts` 里找匹配 `[127.0.0.1]:2222` 的条目，命中那
   行 `@cert-authority`
3. 客户端用这一行里的 CA 公钥验证 sshd 递来的证书签名——验过
4. 再看证书 Principals 里有没有 `127.0.0.1`——有
5. 通过，连接建立，**没有 yes/no**

## 3.7 反向实验：删掉那行试试

```bash
sed -i '/@cert-authority/d' /root/.ssh/known_hosts
ssh -o StrictHostKeyChecking=yes -i /root/.ssh/id_rsa \
    -p 2222 ubuntu@127.0.0.1 "hostname"
```

立刻退回经典提示：

```
The authenticity of host '[127.0.0.1]:2222' can't be established.
```

——客户端没了那行 `@cert-authority`，又被禁止自动 yes
（`StrictHostKeyChecking=yes`），只能拒绝。

把它加回来，准备进入 Step 4：

```bash
echo "@cert-authority [127.0.0.1]:2222 $(cat /root/host-trusted-ca.pem)" \
    >> /root/.ssh/known_hosts
```

## 小结：CA 模式两个方向都打通了

```
客户端                                     目标主机
───────                                   ─────────
id_rsa（私钥）                            sshd_config:
+ Vault 签的 user 证书 ─────────────►      TrustedUserCAKeys = client CA 公钥
                                          HostCertificate    = Vault 签的 host 证书

known_hosts:
  @cert-authority ... host CA 公钥  ◄──── sshd 握手时出示 host 证书
```

两边都不维护"按用户名／按主机名"的本地清单——所有信任关系都收敛到
Vault 里那**两把 CA**。新增一台机器只要让 Vault 给它的 host key 签
一份证书；新增一个用户只要让 Vault 给他的 client key 签一份证书。
**目标主机和客户端都不用改配置**。
