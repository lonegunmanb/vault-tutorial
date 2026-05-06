# 实验说明

本实验与第 5 章的 dev mode 实验不同：本实验采用**非 dev 模式**启动 Vault，因此你必须先准备一份配置文件，再用 `vault server -config=...` 启动；启动后 Vault 处于 sealed 状态，需要先初始化、再解封，最后才能正常使用。

实验开始时，环境已为你完成下列准备：

- 安装好 `vault` 命令；
- 在 `/root/vault.hcl` 中预置一份最小可启动的配置文件，使用 `raft` 存储后端；
- 创建数据目录 `/opt/vault/data`；
- 把 `VAULT_ADDR=http://127.0.0.1:8200` 写入 `/etc/profile.d/vault.sh`，新开 shell 可直接生效。

Vault 进程**尚未**启动；请按照后续步骤亲手启动并解封。
