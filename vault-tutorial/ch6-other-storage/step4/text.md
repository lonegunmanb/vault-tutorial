# 第四步：S3 后端 — 用 ministack 模拟 AWS S3 + 直接观察密文对象

[6.5 节 §8](/ch6-other-storage) 已经说明：S3 后端**不支持高可用**、由社区维护，把 Vault 数据落到 S3 桶里。本步通过本地 [MiniStack](https://github.com/ministackorg/ministack)（兼容 LocalStack 协议、监听 `:4566`）模拟 AWS S3 服务——配置思路与第 3 章 AWS 机密引擎实验完全一致：**Vault 与 AWS 之间是普通 HTTP API 调用，把 endpoint 指向本地 MiniStack 即可在零真实云成本的前提下完整跑通 S3 后端**。

## 4.1 启动 MiniStack 并预创建 S3 桶

```bash
./start-ministack.sh
```

脚本会拉起 `ministackorg/ministack`，监听 `127.0.0.1:4566`，等其健康后退出。镜像在准备阶段已经预拉过，启动只要 1–2 秒。

确认 MiniStack 上的 S3 服务可用：

```bash
curl -s http://127.0.0.1:4566/_localstack/health | jq '.services.s3'
```

应输出 `"available"`。

S3 后端**不会自动创建桶**——必须先在 MiniStack 上把 `vault-data` 桶建出来：

```bash
awslocal s3 mb s3://vault-data
awslocal s3 ls
```

第二条命令应列出刚创建的 `vault-data` 桶。

> 这里用的是 `awslocal` 包装器，等价于 `aws --endpoint-url=http://localhost:4566 ...`，避免每条命令都重复指定 endpoint。

## 4.2 查看预置配置文件

```bash
cat /root/vault-s3.hcl
```

关注其中：

```hcl
storage "s3" {
  access_key          = "test"
  secret_key          = "test"
  bucket              = "vault-data"
  endpoint            = "http://127.0.0.1:4566"
  region              = "us-east-1"
  s3_force_path_style = "true"
  disable_ssl         = "true"
}
```

三个与 MiniStack 强相关的字段：

- `endpoint = "http://127.0.0.1:4566"`：S3 API 的替代端点；正文 §8.2 已说明该字段对应官方文档的 `endpoint` 参数。
- `s3_force_path_style = "true"`：MiniStack 默认仅接受 path-style 寻址（`http://endpoint/bucket/key`），而非 host-style 的 `http://bucket.endpoint/key`，因此必须打开。
- `disable_ssl = "true"`：MiniStack 不监听 TLS，必须显式关闭 SSL。**生产 S3 上严禁关闭**。

## 4.3 启动 Vault 并初始化

```bash
./start-vault.sh s3
sleep 3
vault status || true

vault operator init -key-shares=1 -key-threshold=1 \
  -format=json > /root/init-s3.json

vault operator unseal "$(jq -r '.unseal_keys_b64[0]' /root/init-s3.json)"
export VAULT_TOKEN=$(jq -r '.root_token' /root/init-s3.json)
```

写入一条机密：

```bash
vault secrets enable -path=secret kv-v2
vault kv put secret/demo storage=s3 note="written-via-s3-backend"
vault kv get secret/demo
```

## 4.4 直接到 S3 桶里观察密文对象

```bash
awslocal s3api list-objects --bucket vault-data --query 'Contents[].Key' --output table | head -30
```

可以看到 Vault 把内部状态、policy、token、KV 数据全部以"key 即对象名"的方式拍平到了桶中——对象数会有几十甚至上百个。

挑一个对象下载来看头几个字节，确认它是密文：

```bash
SAMPLE=$(awslocal s3api list-objects --bucket vault-data --query 'Contents[0].Key' --output text)
echo "Sampling object: $SAMPLE"
awslocal s3 cp "s3://vault-data/${SAMPLE}" /tmp/vault-s3-sample.bin
xxd /tmp/vault-s3-sample.bin | head -5
```

输出全是不可读的字节——**S3 桶里能看到的只是密文，没有 unseal key 即使拿到桶的完整副本也无法还原任何机密内容**。这与 step3 在 PostgreSQL 表里看到的 `BYTEA` 列在本质上完全一致：Vault 加密屏障在外部存储后端上的物化形式不一样（行 vs 对象），但都只暴露密文。

## 4.5 重启 Vault 进程，确认 S3 后端持久化生效

```bash
pkill -f 'vault server'
sleep 2
./start-vault.sh s3
sleep 3

vault operator unseal "$(jq -r '.unseal_keys_b64[0]' /root/init-s3.json)"
export VAULT_TOKEN=$(jq -r '.root_token' /root/init-s3.json)

vault kv get secret/demo
```

数据仍然能读出来——但请回到 6.5 节正文 §8 中关于 HA 的判断：S3 后端**不支持高可用**，本步起的 Vault 只能以单节点形式运行，对外宣称 SLA 时不能把 S3 自身的 99.999999999% 耐久度等同于 Vault 集群的可用性。
