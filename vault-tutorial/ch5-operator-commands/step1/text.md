# 第一步：初始化一个未初始化的 Vault

先启动一个本地文件存储 Vault。它监听 `127.0.0.1:8300`，启动后处于“尚未初始化”的状态。

```bash
cd /root/operator-lab
./start-single.sh
export VAULT_ADDR='http://127.0.0.1:8300'
```

查看初始化状态：

```bash
vault operator init -status
echo "exit code = $?"
```

如果输出的退出码是 `2`，表示 Vault 尚未初始化。现在用 3 份 unseal keys、2 份阈值初始化它，并把 JSON 输出保存下来，便于后续步骤继续使用。

```bash
vault operator init \
  -key-shares=3 \
  -key-threshold=2 \
  -format=json | tee init.json
```

把 root token 和 unseal keys 提取出来。生产环境中不应把这些材料放在普通文件中；本实验只为了降低学习摩擦。

```bash
jq -r '.root_token' init.json > root-token.txt
jq -r '.unseal_keys_b64[0]' init.json > unseal-key-1.txt
jq -r '.unseal_keys_b64[1]' init.json > unseal-key-2.txt
jq -r '.unseal_keys_b64[2]' init.json > unseal-key-3.txt
```

第 2.2 节已经专门练习过封印与解封，本实验不再让你重复执行对应命令。运行辅助脚本激活本地 Vault，并加载后续步骤需要的环境变量。

```bash
./activate-single.sh
source /root/operator-lab/single-env.sh
vault status
```

最后确认当前 token 可用，后续步骤会用它执行管理操作。

```bash
vault token lookup | head -20
```

观察要点：`operator init` 只应执行一次；初始化输出中的 root token 与 unseal keys 是最高敏感级别材料；本实验后续聚焦 operator 的其他运维能力。