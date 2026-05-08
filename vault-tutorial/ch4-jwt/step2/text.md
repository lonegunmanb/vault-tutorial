# 第二步：配置 JWT auth 与 role 约束

这一节启用 Vault `auth/jwt`，把 Kubernetes ServiceAccount 签名公钥配置为信任根，并创建只允许 `demo/jwt-app` 使用 audience 为 `vault-jwt` 的 token 登录的 role。

## 2.1 准备教学用 secret 与 policy

先写入一个只允许 `jwt-app` 读取的 KV 数据。

```bash
vault kv put secret/jwt-app/config mode=jwt-auth audience=vault-jwt owner=demo-jwt-app
```

创建读取该路径的 policy。

```bash
cat > /root/jwt-app-read.hcl <<'EOF'
path "secret/data/jwt-app/config" {
  capabilities = ["read"]
}
EOF

vault policy write jwt-app-read /root/jwt-app-read.hcl
```

## 2.2 启用 JWT auth method

默认挂载路径是 `auth/jwt/`。

```bash
vault auth enable jwt
vault auth list | grep jwt
```

## 2.3 从 token 中提取 issuer

为了让 Vault 只接受本集群 issuer 签发的 token，从刚才的 JWT 中提取 `iss` 并保存到文件。

```bash
python3 - <<'PY'
import base64, json, pathlib

token = pathlib.Path('/root/jwt-app-token.txt').read_text().strip()
payload = token.split('.')[1]
payload += '=' * (-len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
pathlib.Path('/root/k8s-issuer.txt').write_text(claims['iss'])
print(claims['iss'])
PY
```

## 2.4 配置 JWT 签名验证来源

kubeadm 控制平面通常把 ServiceAccount 签名公钥放在 `/etc/kubernetes/pki/sa.pub`。把这份 PEM 公钥写入 Vault，并把 `bound_issuer` 设置为刚才提取的 issuer。

```bash
vault write auth/jwt/config \
  jwt_validation_pubkeys=@/etc/kubernetes/pki/sa.pub \
  bound_issuer="$(cat /root/k8s-issuer.txt)"

vault read auth/jwt/config
```

输出中应能看到 `bound_issuer` 与 `jwt_validation_pubkeys` 已配置。

## 2.5 创建 JWT role

role 约束写成 JSON 更清晰，尤其是 `bound_audiences`、`claim_mappings` 这类数组或 map 字段。官方文档也建议在 role 参数包含 map 值时，使用整段 JSON 写入，而不是逐个 CLI 参数拼接。

```bash
vault write auth/jwt/role/jwt-app - <<'EOF'
{
  "role_type": "jwt",
  "bound_audiences": ["vault-jwt"],
  "user_claim": "sub",
  "bound_subject": "system:serviceaccount:demo:jwt-app",
  "claim_mappings": {
    "iss": "issuer"
  },
  "policies": ["jwt-app-read"],
  "ttl": "10m"
}
EOF

vault read auth/jwt/role/jwt-app
```

这个 role 的含义是：只接受 `bound_audiences` 精确匹配 JWT `aud` 值、且 subject 精确等于 `system:serviceaccount:demo:jwt-app` 的 JWT；登录成功后，把 `iss` claim 复制到 metadata 的 `issuer` 字段，并签发带 `jwt-app-read` policy 的 Vault token。

## 2.6 这一步的核心闭环

到这里，Vault 已经具备离线校验 Kubernetes ServiceAccount Token 的能力：签名由 `/etc/kubernetes/pki/sa.pub` 验证，issuer 由 `bound_issuer` 限制，具体调用方由 role 的 audience 与 subject 限制。