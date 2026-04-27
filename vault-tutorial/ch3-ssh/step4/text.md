# 第四步：OTP 模式——一次性密码登录

[3.5 章 §6](/ch3-ssh) 讲过：当目标主机不能用证书 / 公钥认证（合规、
老旧设备、密码-only 链路），就轮到 OTP 模式：

1. 客户端 `vault write ssh/creds/<role> ip=<目标>` 拿到一个一次性
   密码
2. `ssh user@target`，sshd 走 PAM
3. PAM 调 `vault-ssh-helper`，helper 把密码交给 Vault 验证
4. Vault 验证后销毁这个 OTP，helper 返回 PAM_SUCCESS

这一步另起一个干净的容器作目标主机，把这条链路完整搭起来。**仍然
不动宿主机**。

## 4.1 挂一个独立的 SSH 引擎，走 OTP role

OTP 跟 CA 完全是两套配置——可以共用同一个挂载点，但用独立路径更
清楚：

```bash
vault secrets enable -path=ssh ssh

vault write ssh/roles/otp_key_role \
    key_type=otp \
    default_user=ubuntu \
    cidr_list=172.17.0.0/16,127.0.0.0/8
```

字段含义：

| 字段 | 含义 |
| :--- | :--- |
| `key_type=otp` | 标识这是 OTP role（而不是 CA role） |
| `default_user=ubuntu` | OTP 默认登录用户名 |
| `cidr_list` | **OTP 模式特有**：限定能给哪些 IP 段签 OTP；写错的话 `vault write ssh/creds/...` 会被拒 |

## 4.2 启动 OTP 目标容器

容器要做三件事：装 `vault-ssh-helper`、写 helper 配置、改 PAM 与
sshd_config。这些都封装在 `/root/setup-otp-target.sh` 里
（init/assets 已经下发到宿主机），通过 `docker cp` 进容器、`docker
exec` 执行。

### 4.2.1 起 sshd 容器（裸 ubuntu 镜像）

容器需要能从内部访问宿主机的 Vault。Linux 上 docker bridge 的网关
默认是 `172.17.0.1`，所以容器里的 helper 直接访问
`http://172.17.0.1:8200` 即可。

```bash
docker rm -f ssh-target-otp > /dev/null 2>&1 || true

docker run -d --name ssh-target-otp \
  -p 2223:22 \
  ubuntu:24.04 sleep infinity
```

> 这里先 `sleep infinity` 把容器 hold 住——下一小节先把 helper 装
> 进去、改完配置，再手动起 sshd。这样可以避免"sshd 已经在跑、PAM
> 还没改好"的中间态。

### 4.2.2 跑 setup-otp-target.sh 把 helper 与 PAM 配好

```bash
docker cp /root/setup-otp-target.sh ssh-target-otp:/root/setup-otp-target.sh

docker exec \
  -e VAULT_ADDR_FROM_CONTAINER=http://172.17.0.1:8200 \
  -e SSH_MOUNT_POINT=ssh \
  ssh-target-otp \
  bash /root/setup-otp-target.sh
```

正常会看到（**没有 `[ERROR]`**）：

```
--- vault-ssh-helper -verify-only ---
==> WARNING: Dev mode is enabled!
[some output] ... vault-ssh-helper verified successfully!
OTP target ready. Start sshd with: /usr/sbin/sshd -D
```

> 如果看到 `[ERROR]: unsupported scheme. use 'dev' mode`，说明
> helper 没启用 dev 模式——`vault-ssh-helper` 默认拒绝
> `http://` 的 Vault 地址（防止 OTP 明文上传），必须给它加 `-dev`
> 才行。脚本里 `-verify-only` 和 PAM 那条 `pam_exec.so` 调用 helper
> 都已经带上了 `-dev`。

> `-verify-only` 让 helper 自检 Vault 可达 + ssh 引擎挂载存在。如果
> 这里失败（`connection refused` 之类），多半是容器看不到宿主机
> Vault——检查 `VAULT_ADDR_FROM_CONTAINER` 是否真的能从容器内
> reach。

### 4.2.3 后台起 sshd

```bash
docker exec -d ssh-target-otp /usr/sbin/sshd -D -e

# 等 sshd 起来（确认 22 端口在监听）
sleep 2
docker exec ssh-target-otp ss -ltnp 2>/dev/null | grep :22
```

## 4.3 申请一次 OTP

OTP 跟特定**目标 IP** 绑定。容器里的 sshd 看到的客户端 IP 是 docker
网关 `172.17.0.1`（因为我们是从宿主机走端口映射进去的），所以申请时
也要指定这个 IP：

```bash
vault write ssh/creds/otp_key_role ip=172.17.0.1
```

返回里会有：

```
key            <一长串字符串——这就是一次性密码>
ip             172.17.0.1
username       ubuntu
key_type       otp
port           22
```

把 `key` 单独抓出来：

```bash
OTP=$(vault write -field=key ssh/creds/otp_key_role ip=172.17.0.1)
echo "申请到的 OTP: $OTP"
```

## 4.4 用 OTP 登录

正常人手输密码就行——`ssh -p 2223 ubuntu@127.0.0.1`，看到 `Password:`
提示时把 `$OTP` 粘进去。

为了脚本化，用 `sshpass`：

```bash
sshpass -p "$OTP" ssh \
    -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=keyboard-interactive,password \
    -o PubkeyAuthentication=no \
    -p 2223 ubuntu@127.0.0.1 \
    "whoami; hostname; echo --- helper log ---; cat /tmp/vault-ssh.log 2>/dev/null | tail -10"
```

应该看到类似：

```
ubuntu
<容器 ID>
--- helper log ---
... vault-ssh-helper: ... successful ...
```

## 4.5 验证"一次性"——用同一个 OTP 再登一次

```bash
sshpass -p "$OTP" ssh \
    -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=keyboard-interactive,password \
    -o PubkeyAuthentication=no \
    -p 2223 ubuntu@127.0.0.1 "whoami"
```

会失败：`Permission denied, please try again.` 然后掉到下一次提示。
Vault 在第一次验证时已经把这个 OTP **从 storage 里删掉了**，所以
helper 第二次去问 Vault 得到的是 `OTP not found`，PAM 直接拒。

> 这就是"One-Time" 这个词的字面意义——每次 SSH 登录都必须先回到
> Vault 走一次"申请新 OTP → 用完即焚"的流程。**Vault 是在线验证
> 方**，离线了所有 SSH 登录立刻失败，这跟 CA 模式的 sshd 本地
> 验证形成根本对比（[3.5 章 §7](/ch3-ssh) 那张选型表的最关键一行）。

## 4.6 试一下 cidr_list 拦截

申请一个 IP 不在 cidr_list 里的 OTP：

```bash
vault write ssh/creds/otp_key_role ip=8.8.8.8
```

会立刻返回 `Error writing data ... source IP 8.8.8.8 is not part of
allowed cidr blocks`。这条限制在 Vault 一侧就被拒了——OTP 根本签
不出来，更别提去登 8.8.8.8。

下一步做选型横向对比并清理资源。
