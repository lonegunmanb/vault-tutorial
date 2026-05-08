# 第三步：登录 Vault 并验证 audience/subject

这一节用正确 token 登录 Vault，再故意制造错误 audience 与错误 subject，观察 role 约束如何拒绝不符合条件的 JWT。

## 3.1 使用正确 token 登录 Vault

把第一步保存的 ServiceAccount Token 提交给 `auth/jwt/login`。

```bash
vault write -format=json auth/jwt/login \
  role=jwt-app \
  jwt=@/root/jwt-app-token.txt | tee /root/jwt-login.json | jq '.auth | {policies, metadata, lease_duration, renewable}'
```

输出中应能看到 `jwt-app-read` policy，metadata 中应包含 role 以及从 `iss` claim 映射来的 `issuer`。

## 3.2 使用新 Vault token 读取 secret

登录响应中的 `auth.client_token` 才是访问 Vault 的凭据。下面用它读取教学 secret。

```bash
VAULT_TOKEN="$(jq -r '.auth.client_token' /root/jwt-login.json)" \
  vault kv get secret/jwt-app/config
```

如果能看到 `mode=jwt-auth` 等字段，说明 Kubernetes JWT 已成功转换为受 policy 限制的 Vault token。

## 3.3 验证错误 audience 会被拒绝

重新签发一枚 subject 正确但 audience 错误的 token。

```bash
kubectl create token jwt-app -n demo --audience=not-vault --duration=10m > /root/wrong-audience-token.txt
vault write auth/jwt/login role=jwt-app jwt=@/root/wrong-audience-token.txt
```

这条命令应失败，因为 role 的 `bound_audiences` 只允许 `vault-jwt`。

## 3.4 验证错误 subject 会被拒绝

创建同一 namespace 中的另一个 ServiceAccount，并给它签发 audience 正确的 token。

```bash
kubectl create serviceaccount other-app -n demo
kubectl create token other-app -n demo --audience=vault-jwt --duration=10m > /root/wrong-subject-token.txt
vault write auth/jwt/login role=jwt-app jwt=@/root/wrong-subject-token.txt
```

这条命令应失败，因为 token 的 `sub` 是 `system:serviceaccount:demo:other-app`，不等于 role 的 `bound_subject`。

## 3.5 查看登录 token 的元数据

使用 root token 查询刚才签发出的 Vault token，观察 metadata。

```bash
vault token lookup "$(jq -r '.auth.client_token' /root/jwt-login.json)" | grep -E 'policies|meta|ttl|display_name'
```

JWT role 的约束只影响能否登录；登录成功后，Vault token 的可用范围仍然由 policy、TTL、renewable 等 Vault 自身字段决定。

## 3.6 这一步的核心闭环

你已经验证：签名正确但 audience 错误会失败，签名正确但 subject 错误也会失败。JWT auth 的安全边界来自“可信签名 + 精确 claim 约束 + Vault policy”三者共同作用。