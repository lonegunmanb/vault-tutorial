# 第三步：Host Key Signing——客户端不再回答 yes/no

[3.5 章 §5.1](/ch3-ssh) 提到的另一半：默认情况下 SSH 客户端是用
`~/.ssh/known_hosts` 一台一台记目标主机指纹的——第一次连过去会跳出
"The authenticity of host... fingerprint is ... Are you sure (yes/no)?"
那个对话。在自动伸缩集群里这条交互很难维护。

让 Vault 也给**目标主机的 host key** 签一份证书，客户端只需在
`known_hosts` 里写一行 `@cert-authority` 就一劳永逸地信任所有这个
CA 签发过的主机。

## 3.1 给 host key signing 单独挂一个引擎（可选但推荐）

按官方约定，**用户证书**和**主机证书**用两个独立的 CA 是更干净的实
践：

```bash
vault secrets enable -path=ssh-host-signer ssh
vault write ssh-host-signer/config/ca generate_signing_key=true
```

> 也可以复用 Step 1 的 `ssh-client-signer/`——技术上完全可行。但
> 不同 CA 让"谁能登"和"谁是合法主机"在审计日志里完全分开，运维上
> 更清晰。

把这把"主机 CA 公钥"也存到本地：

```bash
vault read -field=public_key ssh-host-signer/config/ca \
    > /root/host-trusted-ca.pem
cat /root/host-trusted-ca.pem
```

## 3.2 创建专门用来签 host key 的 role

```bash
vault write ssh-host-signer/roles/hostrole \
    key_type=ca \
    allow_host_certificates=true \
    allowed_domains="localhost,127.0.0.1" \
    allow_subdomains=true \
    ttl=24h
```

注意三个跟 §2 不同的字段：

- `allow_host_certificates=true`（不是 `allow_user_certificates`）
- `allowed_domains` + `allow_subdomains`：限制能签哪些主机名／域名的
  证书
- `ttl=24h`：主机证书一般给得宽，因为主机不会"撤权"那样频繁

## 3.3 签 Step 2 容器的 host key

把 host key 公钥从容器拷出来：

```bash
docker exec ssh-target-ca cat /etc/ssh/ssh_host_rsa_key.pub \
    > /root/ssh_host_rsa_key.pub
cat /root/ssh_host_rsa_key.pub
```

让 Vault 签这把公钥，得到 host 证书：

```bash
vault write -field=signed_key ssh-host-signer/sign/hostrole \
    cert_type=host \
    public_key=@/root/ssh_host_rsa_key.pub \
    valid_principals="127.0.0.1,localhost" \
    > /root/ssh_host_rsa_key-cert.pub

ssh-keygen -L -f /root/ssh_host_rsa_key-cert.pub | head -20
```

注意这次：

- `Type:` 是 `ssh-rsa-cert-v01@openssh.com host certificate`
- `Principals:` 是 `127.0.0.1, localhost`——客户端会按这个列表与连接
  时用的 hostname 做匹配

## 3.4 把 host 证书塞进容器，让 sshd 出示它

```bash
docker cp /root/ssh_host_rsa_key-cert.pub \
    ssh-target-ca:/etc/ssh/ssh_host_rsa_key-cert.pub

# sshd 通过 HostCertificate 指令出示证书
docker exec ssh-target-ca bash -c '
    grep -q HostCertificate /etc/ssh/sshd_config || \
        echo "HostCertificate /etc/ssh/ssh_host_rsa_key-cert.pub" >> /etc/ssh/sshd_config
'

# 重启 sshd 让配置生效
docker exec ssh-target-ca pkill -HUP sshd
sleep 1
```

## 3.5 客户端：删掉旧 known_hosts，写一行 @cert-authority

把 Step 2 在 known_hosts 里留下的痕迹清掉：

```bash
ssh-keygen -R "[127.0.0.1]:2222" 2>/dev/null || true
```

写入 `@cert-authority` 信任根（**用容器映射在宿主机上的端点
`[127.0.0.1]:2222`** 作为 hostname pattern）：

```bash
echo "@cert-authority [127.0.0.1]:2222 $(cat /root/host-trusted-ca.pem)" \
    >> /root/.ssh/known_hosts

cat /root/.ssh/known_hosts
```

## 3.6 重新 ssh：不再有 yes/no 提示

注意这次**完全不带** `StrictHostKeyChecking=no`：

```bash
ssh -i /root/.ssh/id_rsa -p 2222 ubuntu@127.0.0.1 "hostname"
```

直接出 hostname，**没有任何询问**——客户端通过 `@cert-authority` 那
行得知"凡是 `[127.0.0.1]:2222` 出示的、由这把 CA 签的 host 证书都
信"，sshd 出示的 host 证书又确实由它签发，所以一拍即合。

## 3.7 做个反向实验：把 @cert-authority 那行删掉

```bash
sed -i '/@cert-authority/d' /root/.ssh/known_hosts
ssh -o StrictHostKeyChecking=yes -i /root/.ssh/id_rsa \
    -p 2222 ubuntu@127.0.0.1 "hostname"
```

立刻退回到经典提示：`The authenticity of host '[127.0.0.1]:2222' can't
be established.`

把它加回来，进入 Step 4：

```bash
echo "@cert-authority [127.0.0.1]:2222 $(cat /root/host-trusted-ca.pem)" \
    >> /root/.ssh/known_hosts
```

## 小结

到 Step 3 结束，CA 模式两个方向的"无账户态"都打通了：

```
客户端                                     目标主机
───────                                   ─────────
有 id_rsa                                 sshd_config:
有 Vault 签的 user 证书 ─────────►         TrustedUserCAKeys = client CA pubkey
                                          HostCertificate    = vault 签的 host 证书

known_hosts:
  @cert-authority ... host CA pubkey  ◄────── sshd 出示 host 证书
```

两侧都没有"按用户名／按主机名"的本地清单要维护，所有信任关系收敛到
Vault 里两把 CA。
