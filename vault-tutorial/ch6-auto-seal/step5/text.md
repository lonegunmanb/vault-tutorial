# 第五步：杀掉 KMS 流量代理，复现 KMS 不可达的故障路径

[6.3 节 §4](/ch6-auto-seal) 的论断之二："开源版只用 KMS 解封根密钥，KMS 的可用性窗口仅限于 Vault 启动这一瞬间。一旦 Vault 解封成功，根密钥就驻留进程内存，KMS 短暂宕机不会立刻让正在运行的 Vault 拒绝服务；只有当 Vault 进程**重启**且此时 KMS 不可达，才会卡在 sealed 状态无法启动。"本步把这两半都演示一遍。

> **本步为什么不直接 `docker stop localstack`？** LocalStack 社区版默认不持久化 KMS 状态——容器一停，[Step 1](#) 创建的 KMS 密钥与别名就消失了，`Step 4.2` 解封时使用的那把密钥也再也找不回，复盘路径会被一连串次要细节淹没。改成杀掉 [Step 2.1](#) 架设的 `socat` 代理就干净多了：LocalStack 自身完好，KMS 密钥纹丝不动，Vault 端只是网络上看不到 KMS——这正是真实生产环境中 KMS 服务暂时不可达时的网络观感。

## 5.1 半场 A：KMS "不可达"但 Vault 进程还在跑——业务不受影响

先确认 Vault 当前在跑且 unsealed：

```bash
vault status | grep -E '^(Initialized|Sealed)'
```

往一个临时挂载的 KV 引擎写一条数据，作为后续的可读探针：

```bash
vault secrets enable -path=kv kv-v2 || true
vault kv put kv/canary value=before-kms-unreachable
```

现在**杀掉 KMS 流量代理**：

```bash
KMS_PROXY_PID=$(cat /var/run/kms-proxy.pid)
echo "killing kms-proxy pid=$KMS_PROXY_PID"
kill "$KMS_PROXY_PID"
sleep 1
ss -lntp | grep ':14566' || echo "no longer listening on 14566 (expected)"
```

`:14566` 端口应当不再被任何进程占用——从 Vault 的视角看，它配置文件里那个 KMS 端点已经"失联"了。冒烟一下：

```bash
curl -s -o /dev/null -w 'HTTP %{http_code}\n' --connect-timeout 2 \
    http://127.0.0.1:14566/_localstack/health || echo "connect refused (expected)"
```

应输出 `connect refused`——Vault 此刻去调 KMS 的话同样会被 connect refused 打回。

LocalStack 自身仍然完好：

```bash
curl -s http://127.0.0.1:4566/_localstack/health | jq '.services.kms'
awslocal kms list-aliases | jq '.Aliases[] | select(.AliasName=="alias/vault-classroom-unseal")'
```

这两行依然返回正常结果——说明 KMS 状态丝毫未损，"不可达"完全发生在网络层。

此时 Vault 进程**仍然在跑**——根密钥早已驻留在 Vault 进程内存里，KMS 链路中断不会立刻让正在运行的 Vault 拒绝服务。验证：

```bash
vault status | grep -E '^(Sealed)'
vault kv get kv/canary
```

`Sealed: false`，且 KV 读取返回 `value: before-kms-unreachable`——业务读写完全不受 KMS "宕机"影响。这就是 §4 中"KMS 的可用性窗口仅限于启动这一瞬间"在开源版上的具体含义。

## 5.2 半场 B：Vault 重启 + KMS 仍不可达 → 启动失败

继续保持 KMS 代理处于已被杀状态，把 Vault 进程也 kill 掉：

```bash
pkill -f 'vault server' 2>/dev/null || true
sleep 1
ss -lntp | grep ':8200' || echo "vault no longer listening on 8200 (expected)"
```

> 这里改用 `pkill -f 'vault server'` 而非 `kill "$(cat /tmp/vault.pid)"`：实验过程中 Vault 进程可能已被你换过几次，PID 文件未必准确；按进程名匹配更稳妥。

再次启动 Vault：

```bash
source /etc/profile.d/vault.sh
source /etc/profile.d/aws.sh
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &
sleep 3
```

观察 Vault 日志：

```bash
tail -50 /var/log/vault.log
```

你会看到 Vault 进程在尝试调 KMS 时直接失败——日志中会出现连接被拒绝（`connection refused`）、`error fetching AWS KMS wrapping key information` 一类的错误信息。Vault 进程应当已经退出。

```bash
vault status || true
ps -ef | grep -E 'vault server' | grep -v grep || echo "no vault process (expected)"
```

CLI 端会报 `connection refused` 一类的错误（因为 Vault 进程已退出，`:8200` 没人监听）—— 与 [Step 4.4](#) 的 `Sealed: false` 形成鲜明对比。

> 这个对照实验直观地刻画了 **KMS 在 Vault 启动那一瞬间的强依赖性质**：auto-unseal 是把"信任根的可用性"委托给 KMS；只要 Vault 进程有重启需求，KMS 就必须可达。生产部署中应据此为 KMS 设置高可用架构，并把 KMS 的 SLO 纳入 Vault 自身可用性 SLO 的依赖项。

## 5.3 复原现场：把代理拉回来，Vault 应当干净恢复

把 socat 代理重新启动起来——参数与 [Step 2.1](#) 一致：

```bash
nohup socat -d \
    TCP-LISTEN:14566,bind=127.0.0.1,fork,reuseaddr \
    TCP:127.0.0.1:4566 \
    > /var/log/kms-proxy.log 2>&1 &
echo $! > /var/run/kms-proxy.pid

sleep 1
ss -lntp | grep ':14566'
curl -s http://127.0.0.1:14566/_localstack/health | jq '.services.kms'
```

代理重新 LISTEN 在 `:14566`，且能透传 LocalStack 的健康响应。

由于 LocalStack 一直没被动过，KMS 密钥与 alias 仍然存在；Vault 当前的 raft 数据目录里那把根密钥**就是**用这把 KMS 密钥加密的——此刻把 Vault 起来即可干净恢复，**不需要**重新 init、不需要任何手工 unseal 步骤：

```bash
pkill -f 'vault server' 2>/dev/null || true
sleep 1

source /etc/profile.d/vault.sh
source /etc/profile.d/aws.sh
nohup vault server -config=/root/vault.hcl > /var/log/vault.log 2>&1 &

for i in $(seq 1 15); do
  ss -lntp | grep -q ':8200' && { echo "vault listening"; break; }
  sleep 1
done

vault status | grep -E '^(Initialized|Sealed|Seal Type)' || tail -30 /var/log/vault.log
```

应回到 `Initialized=true`、`Sealed=false`、`Seal Type=awskms`——Vault 又一次完成了 auto-unseal。再读一次 [5.1](#) 里写入的 canary 验证业务数据也未受任何影响：

```bash
vault kv get kv/canary
```

应仍然返回 `value: before-kms-unreachable`。

## 5.4 这一步的核心闭环

通过把 KMS 流量代理当成可宕机的中转层，我们把"KMS 不可达"与"KMS 状态丢失"两个原本耦合在一起的现象彻底解耦：本步只演示前者。Vault 在 KMS 不可达时若不重启则业务完全不受影响（开源版语义）；一旦重启且 KMS 仍不可达就会启动失败；KMS 一旦恢复，Vault 重启即可干净 auto-unseal——既无需重新 init，也无需任何手工 unseal。这两半合起来给出 §4 中那条边界结论的完整验证。
