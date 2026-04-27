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
  ubuntu:24.04 sleep infinity
```

> 这里**不映射端口**——后面 §4.4 我们会用容器的内部 IP 直接 ssh
> 进去（vault-ssh-helper 校验 OTP 时是用"目标主机本机网卡 IP"
> 做匹配，所以走 docker 内部 IP 比走 `127.0.0.1:2223` 端口映射
> 简单得多）。
>
> 同时先 `sleep infinity` 把容器 hold 住——下一小节先把 helper 装
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

OTP 跟特定**目标主机 IP** 绑定——这里的"目标 IP"指的是 **sshd
（也就是 helper）所在主机的本机 IP**，不是客户端的 source IP。
helper 在容器里跑，会拿 OTP 里的 IP 去对**自己本地网卡**，对不上
就拒：

```
[ERROR]: IP did not match any of the network interface addresses.
```

所以要先拿到容器自己的 IP（典型是 `172.17.0.2`），再用它申请 OTP：

```bash
TARGET_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ssh-target-otp)
echo "目标容器 IP: $TARGET_IP"

vault write ssh/creds/otp_key_role ip=$TARGET_IP
```

返回里会有：

```
key            <一长串字符串——这就是一次性密码>
ip             172.17.0.2
username       ubuntu
key_type       otp
port           22
```

把 `key` 单独抓出来：

```bash
OTP=$(vault write -field=key ssh/creds/otp_key_role ip=$TARGET_IP)
echo "申请到的 OTP: $OTP"
```

> ⚠️ 别用 `ip=127.0.0.1` 或 `ip=172.17.0.1`（docker 网关）——那是
> 客户端到达容器的"路径"，不是容器的接口地址。helper 校验的是
> "OTP IP ∈ 我自己的网卡地址集合"，所以必须用容器本机 IP。

## 4.4 用 OTP 登录

直连容器 IP 走 SSH（不走 127.0.0.1:2223 那条端口映射，因为
helper 已经认了 `$TARGET_IP`）：

```bash
sshpass -p "$OTP" ssh \
    -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=keyboard-interactive,password \
    -o PubkeyAuthentication=no \
    ubuntu@$TARGET_IP \
    "whoami; hostname; echo --- helper log ---; cat /tmp/vault-ssh.log 2>/dev/null | tail -10"
```

应该看到类似：

```
ubuntu
<容器 ID>
--- helper log ---
*** <时间戳> ***
... ==> WARNING: Dev mode is enabled!
... [INFO] using SSH mount point: ssh
... [INFO] using namespace:
... [INFO] ubuntu@172.17.0.2 authenticated!
```

最后那行 `[INFO] ubuntu@<IP> authenticated!` 就是 helper 把 OTP
交给 Vault、Vault 验过后销毁、helper 返回 PAM_SUCCESS 的成功标志。

> 想"必须从 127.0.0.1:2223 端口映射进"也行，但要让 helper 信
> 任来自 `172.17.0.1`（docker 网关）这条 source IP，得在
> `/etc/vault-ssh-helper.d/config.hcl` 里加
> `allowed_cidr_list = "172.17.0.0/16"` 并申请 OTP 时用网关 IP。
> 实验里走容器 IP 直连最简单。

## 4.5 验证"一次性"——用同一个 OTP 再登一次

```bash
sshpass -p "$OTP" ssh \
    -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=keyboard-interactive,password \
    -o PubkeyAuthentication=no \
    -o NumberOfPasswordPrompts=1 \
    ubuntu@$TARGET_IP "whoami"
echo "ssh exit code: $?"
```

会失败：

```
ubuntu@172.17.0.2: Permission denied (keyboard-interactive).
ssh exit code: 255
```

> 加 `NumberOfPasswordPrompts=1` 是关键——`sshpass` 只会自动喂
> 第一次密码提示，sshd 第一次拒绝后还会再 prompt 一次让你重试，
> 这时 sshpass 没东西可填，ssh 就会**默默断开**、什么都不打印。
> 限定"只能 prompt 一次"后失败信息才会按时打到 stderr。

容器里看一眼 helper 日志，能看到这次的拒绝痕迹：

```bash
docker exec ssh-target-otp tail -5 /tmp/vault-ssh.log
```

会看到类似：

```
URL: PUT http://172.17.0.1:8200/v1/ssh/verify
Code: 400. Errors:

* OTP not found
```

Vault 在 4.4 第一次验证时已经把这个 OTP **从 storage 里删掉了**，
所以 helper 第二次去 `/v1/ssh/verify` 问 Vault，Vault 直接返回 400
+ `OTP not found`，PAM 那条 `auth requisite` 立刻拒。

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
