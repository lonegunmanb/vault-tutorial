# 第五步：用 `vault ssh` 生成 SSH OTP 凭据

本步骤不会真正连接远程主机，而是使用 `vault ssh -no-exec` 观察 SSH OTP 模式如何向 SSH 机密引擎申请一次性登录凭据。

先查看已准备好的 SSH OTP 角色：

```bash
vault read ssh-otp/roles/training-otp
```

执行 `vault ssh`，指定 OTP 模式、挂载点、角色，并使用 `-no-exec` 阻止 CLI 真正调用 SSH 建立连接：

```bash
vault ssh \
  -mode=otp \
  -mount-point=ssh-otp \
  -role=training-otp \
  -no-exec \
  vaultlab@127.0.0.1
```

输出中应能看到 Vault 为该次登录生成的凭据或连接相关信息。由于使用了 `-no-exec`，本步骤只验证 Vault 侧凭据生成流程，不要求本机真的运行可登录的 SSH 服务端。

可以再查看 SSH 引擎自身的路径帮助：

```bash
vault path-help ssh-otp/creds/training-otp
```

这一阶段的关键点是：`vault ssh` 不是单纯的 SSH 包装器。它先与 Vault 的 SSH secrets engine 交互，取得 OTP、动态凭据或签名证书，然后才把结果交给本地 `ssh` 程序使用。