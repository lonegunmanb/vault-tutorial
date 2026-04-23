# 第五步：前缀撤销——事故响应里的核武器

文档 §6 描述的入侵响应场景：

> 你发现一个内部服务被入侵了，攻击者可能拷贝了它过去 2 小时内通过
> Vault 拿到的所有 AWS 临时凭据。

`vault lease revoke -prefix` 让你**一句话**清空一类租约。

## 5.1 准备「事故现场」

模拟这一类被入侵角色——签 5 份凭据，让它们都进 lease 表：

```bash
for i in 1 2 3 4 5; do
  vault read database/creds/readonly > /dev/null
done
```

确认 Postgres 里有 5 个临时用户：

```bash
docker exec -i learn-postgres \
  psql -U root -c "SELECT count(*) FROM pg_user WHERE usename LIKE 'v-%';"
```

确认 Vault lease 表里也有 5 条：

```bash
vault list sys/leases/lookup/database/creds/readonly
```

## 5.2 一句核按钮

事故来了。我们要把 `database/creds/readonly` 这个角色**历史上签出去
的所有还在租约表里的凭据**全部连根拔起：

```bash
vault lease revoke -prefix -sync database/creds/readonly/
```

> `-prefix` 表示按前缀批量撤销；`-sync` 表示同步等待引擎完成所有撤销
> 动作再返回（默认是异步）。生产环境如果租约数量极大，建议不带 `-sync`
> 让 Vault 后台慢慢做，避免请求超时。

立刻看 Postgres：

```bash
docker exec -i learn-postgres \
  psql -U root -c "SELECT usename FROM pg_user WHERE usename LIKE 'v-%';"
```

5 个用户**全部消失**。lease 表也空了：

```bash
vault list sys/leases/lookup/database/creds/readonly 2>&1 || echo "(已清空)"
```

## 5.3 前缀的粒度可以更粗

`-prefix` 不要求精确到角色——它沿着 `sys/leases/lookup/` 这棵树
向下覆盖一切。比如要把整个 database 引擎下所有角色历史上签出去的
凭据全部清空：

```bash
# 慎用，影响范围 = database 引擎下所有角色
vault lease revoke -prefix -sync database/creds/
```

或者把整个 database 挂载点的所有租约（包括其他类型路径）一起清：

```bash
vault lease revoke -prefix -sync database/
```

实战中常见的几个粒度：

| 场景 | 前缀 |
| --- | --- |
| 单个角色被入侵 | `database/creds/readonly/` |
| 单个引擎挂载点被入侵 | `database/` 或 `aws/` |
| 单个 Token 被入侵 | 直接 `vault token revoke <token>`（见第 4 步） |
| 整个 namespace 被入侵 | `vault lease revoke -prefix -sync <ns>/` |

## 5.4 这一招与"统一中心"的呼应

回到 §1 那句：

> Vault 把过去散在应用、运维脚本、cron job 里的过期逻辑，
> **收敛到了 Vault 内部一个统一的过期管理器**。

第 5 步演示的就是这个收敛带来的最大红利——**事故响应不再需要"先去
列哪些密码受影响、再去登录哪些系统执行清理"**，而是一句基于路径前缀
的命令，让 Vault 替你完成所有目标系统侧的清理动作。

这是租约机制和 KV 静态存储**最不可比拟**的能力差异。

---

## 实验小结

到这里，理论文档 §3-§6 的四个边界条件你都亲手跑过了：

1. **lease_id 的前缀结构** —— Step 1
2. **max_lease_ttl 的硬天花板** —— Step 2
3. **increment 是从现在算（可主动缩短）** —— Step 3
4. **Token revoke 的级联清理** —— Step 4
5. **前缀撤销的批量回收** —— Step 5

下一节我们将进入 2.4 章 Token 与认证的本质——**Token 树状结构**正是
让第 4 步那个"父 Token revoke 时级联清理子租约"成为可能的底层数据结构。
