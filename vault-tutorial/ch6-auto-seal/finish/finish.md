# 实验完成

恭喜你完成本节实验。在本实验中，你已经：

- 在 LocalStack 上启用 KMS 子服务，创建了一把对称加密密钥并挂上 alias `alias/vault-classroom-unseal`，并通过 awscli 端到端 Encrypt / Decrypt 验证密钥可用；
- 在原本只声明 `storage` / `listener` 的 `vault.hcl` 上追加了一个 `seal "awskms"` 块，其中通过 `endpoint` 把 KMS API 调用重定向到 LocalStack、通过 `env://...` 间接值引用注入访问凭据，并以 alias 而非具体 key ID 填写 `kms_key_id`；
- 执行 `vault operator init -recovery-shares=5 -recovery-threshold=3`，亲眼观察到返回数据中 `unseal_keys_b64` 为空、`recovery_keys_b64` 长度为 5——印证 auto-unseal 模式下 init 生成的是 recovery keys 而非 unseal keys；
- 强行 `kill` Vault 进程后再次启动，**完全不输入任何解封分片**也回到 `Sealed=false` 状态——auto-unseal 在重启场景下真正工作；
- 把 LocalStack 容器停掉，确认正在运行的 Vault 进程不受影响（业务 KV 读写依然正常）；进一步 kill Vault 后再启动，复现 "KMS 不可达 → Vault 卡 sealed 启动失败" 的故障路径，体会 KMS 在启动瞬间的强依赖性质。

下一节将在配置文件深化方向上继续前进，讲解 Vault 的另一个核心存储后端话题——Integrated Storage (Raft) 协议的深度细节。
