# 实验：部署生产风格的 Vault

在本实验中，你将完成与生产环境最接近的 Vault 部署流程：

1. **从官方 Verified Publisher 镜像源拉取并验证 Vault 二进制**
2. **编写一份基于 Integrated Storage（Raft）的生产风格 HCL 配置**
3. **执行 `vault operator init` + `vault operator unseal`，亲手完成 Shamir 封印解封流程**
4. **直接观察存储目录里的二进制文件，验证 Barrier 加密效果**

完成本实验后，你会从"心智模型"层面真正理解为什么 Vault 启动时是 Sealed 状态、为什么 Unseal Key 必须由多人保管、为什么"存储后端被偷了也不会泄密"。
