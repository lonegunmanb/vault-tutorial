# 第一步：启用 SSH 引擎，生成 CA

[3.5 章 §1](/ch3-ssh) 讲过：SSH 引擎跟 KV / AWS 一样是个普通的可挂载
插件，但它的产物是"登录凭证"而不是"机密字符串"。这一步先把 CA 模式
的"信任根"立起来——后续 Step 2、Step 3 都依赖它。

## 1.1 挂载 SSH 引擎

按官方文档的命名约定挂在 `ssh-client-signer/`：

```bash
vault secrets enable -path=ssh-client-signer ssh
```

`secrets list` 一眼确认：

```bash
vault secrets list | grep ssh-client-signer
```

应该能看到一行 `ssh-client-signer/    ssh    ssh_xxxxx`。这跟其它任
何引擎挂载没区别——SSH 引擎在路由表里就是个普通插件。

## 1.2 让引擎自己生成 CA 私钥

这是 CA 模式整个机制的"信任根"诞生的瞬间：

```bash
vault write ssh-client-signer/config/ca generate_signing_key=true
```

返回里有两个字段：

- `public_key`：**SSH CA 公钥**，接下来要分发给所有目标主机的
  `TrustedUserCAKeys` 文件
- 私钥：**不返回**，永远留在 Vault 内部。即使是 root 也没有任何 API
  能 export 出来——这是 SSH 引擎设计的安全保证

把公钥单独捞出来存到本地（Step 2 要把它喂给容器里的 sshd）：

```bash
vault read -field=public_key ssh-client-signer/config/ca \
    > /root/trusted-user-ca-keys.pem

cat /root/trusted-user-ca-keys.pem
```

会看到一行 `ssh-rsa AAAA...`。这把公钥的指纹也可以看一下：

```bash
ssh-keygen -lf /root/trusted-user-ca-keys.pem
```

输出形如 `4096 SHA256:... vault-ssh-host-signer (RSA-CERT)`——说明
Vault 给我们生成的是 4096 位 RSA。

## 1.3 试一下：能不能再 generate 一次？

```bash
vault write ssh-client-signer/config/ca generate_signing_key=true
```

会报 `keys are already configured`——CA 私钥一旦生成就是这把，**重
新生成意味着所有已签发的证书集体作废**，所以 Vault 在 API 层堵掉
"误手覆盖"。要换 CA 必须先 `vault delete
ssh-client-signer/config/ca`，但本实验里我们不这么做。

## 1.4 还没有 role，所以还签不出东西

```bash
vault write -field=signed_key ssh-client-signer/sign/my-role \
    public_key=@/root/.ssh/id_rsa.pub
```

会报 `unknown role: my-role`。CA + role 是两件事：

- **CA**：信任根，**全引擎一份**
- **role**：签发策略，**可以有很多个**——比如 `dev-role`（短 TTL +
  只准登 dev 主机）vs `ops-role`（更长 TTL + 准登所有主机）

下一步我们就来创建第一个 role，并让一个真正的 sshd 容器信任这把 CA。
