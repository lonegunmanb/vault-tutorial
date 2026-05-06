# 第三步：使用 generate-root 生成应急 root token

本步骤演示 `operator generate-root` 的 OTP 流程。它需要达到 unseal key quorum，因此在本实验中需要提交两份 unseal keys。

先生成一个高熵 OTP，并用它启动 root token 生成流程。

```bash
source /root/operator-lab/single-env.sh

OTP=$(vault operator generate-root -generate-otp)
echo "$OTP" > generate-root-otp.txt

vault operator generate-root -init -otp="$OTP" -format=json | tee generate-root-init.json
NONCE=$(jq -r '.nonce' generate-root-init.json)
echo "$NONCE" > generate-root-nonce.txt
```

提交第一份 unseal key，观察进度尚未完成：

```bash
vault operator generate-root \
  -nonce="$(cat generate-root-nonce.txt)" \
  -format=json \
  "$(cat unseal-key-1.txt)" | tee generate-root-progress.json
```

提交第二份 unseal key，达到 quorum 后会得到 encoded token：

```bash
vault operator generate-root \
  -nonce="$(cat generate-root-nonce.txt)" \
  -format=json \
  "$(cat unseal-key-2.txt)" | tee generate-root-final.json
```

从最终输出中取出 encoded token，并用最初的 OTP 解码：

```bash
ENCODED_TOKEN=$(jq -r '.encoded_token' generate-root-final.json)
vault operator generate-root -decode="$ENCODED_TOKEN" -otp="$(cat generate-root-otp.txt)"
```

观察要点：`generate-root` 不是普通登录手段，而是应急恢复最高权限的流程；OTP 必须保留到最后解码；nonce 必须在每次提交 unseal key 时保持一致。

如果你只想查看或取消当前流程，可使用：

```bash
vault operator generate-root -status
vault operator generate-root -cancel
```