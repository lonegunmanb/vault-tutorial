# 第一步：启动 LocalStack 并在其上创建 KMS 密钥

[6.3 节正文](/ch6-auto-seal) 已说明：`seal "awskms"` 在 Vault 启动时会调用 AWS KMS 的 `kms:Encrypt` / `kms:Decrypt` / `kms:DescribeKey` 三个 API 解密根密钥。本步把"AWS KMS"换成跑在本机的 LocalStack——同样讲 KMS API，Vault 端的 auto-unseal 流程就能在本地完整跑通。

## 1.1 启动 LocalStack（仅启 KMS 子服务）

LocalStack 通过 `SERVICES` 环境变量控制启用哪些 AWS 子服务；本实验只需要 `kms`。

```bash
docker run -d --name localstack \
  -p 4566:4566 \
  -e SERVICES=kms \
  localstack/localstack:3
```

镜像在准备阶段已预拉。等容器健康：

```bash
sleep 5
curl -s http://127.0.0.1:4566/_localstack/health | jq '.services.kms'
```

应输出 `"available"` 或 `"running"`——LocalStack 的 KMS 子服务已就绪。

## 1.2 用 awscli 直连 LocalStack 验证 KMS 可用

实验环境已把 `AWS_ACCESS_KEY_ID=test` / `AWS_SECRET_ACCESS_KEY=test` / `AWS_DEFAULT_REGION=us-east-1` 持久化到 shell 环境；LocalStack 接受任意 SigV4 签名，但 awscli 自身仍要看到一对 key 才肯发请求。先用 `awslocal`（实验环境预装的便捷命令；等价于 `aws --endpoint-url=http://127.0.0.1:4566 --region us-east-1`）确认 KMS 列表为空：

```bash
awslocal kms list-keys
```

应输出形如 `{"Keys": []}` 的空集合——干净的初始状态。

## 1.3 创建一把对称加密用 KMS 密钥

```bash
CREATE_OUT=$(awslocal kms create-key \
    --description "Vault auto-unseal demo key" \
    --key-usage ENCRYPT_DECRYPT)
echo "$CREATE_OUT" | jq '.KeyMetadata | {KeyId, Arn, KeyState, KeyUsage}'

KMS_KEY_ID=$(echo "$CREATE_OUT" | jq -r '.KeyMetadata.KeyId')
echo "KMS_KEY_ID=$KMS_KEY_ID"
```

`KeyState` 应当是 `Enabled`，`KeyUsage` 应当是 `ENCRYPT_DECRYPT`——这正是 [6.3 节 §10](/ch6-auto-seal) 中 Vault 所需 `kms:Encrypt` / `kms:Decrypt` / `kms:DescribeKey` 三个动作能在其上工作的密钥类型。

## 1.4 给密钥加一个 alias

[6.3 节 §11](/ch6-auto-seal) 提到：在 `kms_key_id` 字段中**优先使用 alias 而非具体 key ID**，可以让密钥轮转时不必改动 Vault 配置文件。我们把刚才的密钥挂上 `alias/vault-classroom-unseal`：

```bash
awslocal kms create-alias \
    --alias-name alias/vault-classroom-unseal \
    --target-key-id "$KMS_KEY_ID"

awslocal kms list-aliases | jq '.Aliases[] | select(.AliasName=="alias/vault-classroom-unseal")'
```

输出应包含 `AliasName` 与 `TargetKeyId`，且 `TargetKeyId` 与上一步的 `$KMS_KEY_ID` 一致。

## 1.5 端到端冒烟：手动跑一次 Encrypt / Decrypt

在让 Vault 上场之前，先用 `awslocal` 自己跑一次完整的 Encrypt → Decrypt 闭环，确认这把 alias 真的能加解密：

```bash
ENCRYPTED=$(awslocal kms encrypt \
    --key-id alias/vault-classroom-unseal \
    --plaintext "$(echo -n 'hello vault' | base64)" \
    --query CiphertextBlob --output text)
echo "Ciphertext (base64): $ENCRYPTED"

awslocal kms decrypt \
    --ciphertext-blob "$ENCRYPTED" \
    --query Plaintext --output text \
    | base64 -d
echo
```

最后一行应输出 `hello vault`。如果这一步通不过，后续 Vault 也一定起不来——必须先把这里跑顺。

## 1.6 把 KMS_KEY_ID 持久化，方便后续步骤使用

虽然后面 Step 2 写进 `vault.hcl` 的是 alias 而非 key ID，但持久化一份 ID 便于排错时回查：

```bash
echo "export KMS_KEY_ID=${KMS_KEY_ID}" >> /etc/profile.d/aws.sh
```

## 1.7 这一步的核心闭环

LocalStack 的 KMS 子服务已在本机 `:4566` 监听；一把 `Enabled` 状态的对称加密密钥已经创建并挂上了 `alias/vault-classroom-unseal`；端到端 Encrypt → Decrypt 已经手动跑通。下一步把 Vault 接上来。
