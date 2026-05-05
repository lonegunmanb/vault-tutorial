# 第五步：用 `vault ssh` 登录 SSH OTP 目标容器

本步骤会启动一个独立容器作为 SSH 目标主机，并在容器内安装 `vault-ssh-helper`。随后使用 `vault ssh` 申请 OTP，并真正登录到这个容器中执行命令。

先确认客户端侧命令已经就绪。OTP 模式完整自动化需要本机有 `ssh`，并能通过 `sshpass` 把一次性密码交给 OpenSSH：

```bash
command -v ssh
command -v sshpass
```

再查看初始化阶段已经准备好的 SSH OTP 角色：

```bash
vault read ssh-otp/roles/training-otp
```

## 5.1 启动目标容器

先启动一个干净的 Ubuntu 容器。这个容器代表一台需要通过 SSH 登录的目标主机；实验不会修改宿主机的 sshd 配置。

```bash
docker rm -f ssh-target-otp > /dev/null 2>&1 || true

docker run -d --name ssh-target-otp \
  ubuntu:24.04 sleep infinity
```

把初始化脚本复制进容器，并让它安装 `vault-ssh-helper`、配置 PAM 和 sshd。容器访问宿主机 Vault 时使用 Docker bridge 网关地址 `172.17.0.1`：

```bash
docker cp /root/setup-otp-target.sh ssh-target-otp:/root/setup-otp-target.sh

docker exec \
  -e VAULT_ADDR_FROM_CONTAINER=http://172.17.0.1:8200 \
  -e SSH_MOUNT_POINT=ssh-otp \
  -e OTP_LOGIN_USER=vaultlab \
  ssh-target-otp \
  bash /root/setup-otp-target.sh
```

正常输出中应看到 `vault-ssh-helper verified successfully` 或相近的成功信息。它说明容器里的 helper 能访问 Vault，并能找到 `ssh-otp/` 挂载点。

启动容器里的 sshd，并等待进程出现：

```bash
docker exec -d ssh-target-otp /usr/sbin/sshd -D -e

for i in $(seq 1 30); do
  docker exec ssh-target-otp pgrep -x sshd > /dev/null 2>&1 && break
  sleep 1
done

docker exec ssh-target-otp pgrep -a sshd
```

## 5.2 用 `vault ssh` 真正登录

OTP 与目标主机 IP 绑定。这里的目标 IP 是容器自身的 Docker bridge 地址，而不是 `127.0.0.1`：

```bash
TARGET_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ssh-target-otp)
echo "目标容器 IP: $TARGET_IP"
```

现在使用 `vault ssh` 建立连接。命令会先向 `ssh-otp/creds/training-otp` 申请一次性密码，再调用本机 OpenSSH 登录容器：

```bash
vault ssh \
  -mode=otp \
  -mount-point=ssh-otp \
  -role=training-otp \
  -strict-host-key-checking=no \
  -user-known-hosts-file=/dev/null \
  vaultlab@$TARGET_IP \
  -o PreferredAuthentications=keyboard-interactive,password \
  -o PubkeyAuthentication=no \
  "whoami; hostname; echo --- helper log ---; tail -10 /tmp/vault-ssh.log 2>/dev/null"
```

输出中应看到远端用户 `vaultlab`、容器主机名，以及 helper 日志里的认证记录。这说明 `vault ssh` 已经完成了“向 Vault 申请 OTP → 调用 SSH → 目标容器用 helper 回调 Vault 校验 OTP → 登录成功”的闭环。

如果想进入交互式 shell，可以去掉最后的远端命令：

```bash
vault ssh \
  -mode=otp \
  -mount-point=ssh-otp \
  -role=training-otp \
  -strict-host-key-checking=no \
  -user-known-hosts-file=/dev/null \
  vaultlab@$TARGET_IP
```

进入后执行 `exit` 返回实验终端。

可以再查看 SSH 引擎自身的路径帮助：

```bash
vault path-help ssh-otp/creds/training-otp
```

这一阶段的关键点是：`vault ssh` 不是单纯的 SSH 包装器。OTP 模式下，它先与 Vault 的 SSH secrets engine 交互，取得一次性密码；目标主机上的 `vault-ssh-helper` 再把登录时收到的 OTP 交回 Vault 校验。Vault 在线、目标主机 helper 配置正确、OTP 与目标 IP 匹配，三者同时满足，登录才会成功。