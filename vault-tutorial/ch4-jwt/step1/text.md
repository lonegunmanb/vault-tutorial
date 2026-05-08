# 第一步：观察 Kubernetes ServiceAccount JWT

这一节先不配置 Vault，而是观察 Kubernetes 发给 ServiceAccount 的 JWT。理解令牌中的 `iss`、`sub`、`aud` 与 `exp` 后，后续 Vault role 的每一个约束都会更容易理解。

## 1.1 创建实验 namespace 与 ServiceAccount

创建一个名为 `demo` 的 namespace，以及名为 `jwt-app` 的 ServiceAccount。

```bash
kubectl create namespace demo
kubectl create serviceaccount jwt-app -n demo
```

## 1.2 生成短生命期 ServiceAccount Token

使用 TokenRequest 方式签发一枚 audience 为 `vault-jwt`、有效期为 10 分钟的 token，并保存到文件中。

```bash
kubectl create token jwt-app -n demo --audience=vault-jwt --duration=10m > /root/jwt-app-token.txt
cut -c 1-80 /root/jwt-app-token.txt && echo "..."
```

这枚 token 之后会被直接提交给 Vault 的 `auth/jwt/login` 端点。

## 1.3 解码 JWT payload

JWT 由 header、payload、signature 三段组成。下面只解码 payload，不校验签名。

```bash
python3 - <<'PY'
import base64, json, pathlib

token = pathlib.Path('/root/jwt-app-token.txt').read_text().strip()
payload = token.split('.')[1]
payload += '=' * (-len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
print(json.dumps({
    'iss': claims.get('iss'),
    'sub': claims.get('sub'),
    'aud': claims.get('aud'),
    'exp': claims.get('exp'),
    'kubernetes.io': claims.get('kubernetes.io'),
}, indent=2, ensure_ascii=False))
PY
```

你应能看到类似信息：`sub` 是 `system:serviceaccount:demo:jwt-app`，`aud` 包含 `vault-jwt`，`exp` 是过期时间戳。下一步会把这些值写进 Vault role 约束。

## 1.4 查看 Kubernetes OIDC discovery 信息

Kubernetes 可以暴露 OIDC discovery 元数据。这里读取 issuer 与 JWKS URI，帮助你理解 Kubernetes 为什么能作为 JWT issuer。

```bash
kubectl get --raw /.well-known/openid-configuration | jq '{issuer, jwks_uri}'
```

如果要查看 JWKS 中的公钥描述，可以把 discovery 中的 `jwks_uri` 转换为 Kubernetes API 的相对路径后读取。

```bash
JWKS_PATH=$(kubectl get --raw /.well-known/openid-configuration | jq -r '.jwks_uri' | sed -E 's#^https?://[^/]+##')
kubectl get --raw "$JWKS_PATH" | jq '.keys[0] | {kid, kty, alg, use}'
```

本实验后续不直接使用 OIDC discovery 配置 Vault，而是读取 kubeadm 控制平面上的 `/etc/kubernetes/pki/sa.pub` 作为静态公钥；这样可以避免实验中处理集群内部 DNS 与证书信任问题。

## 1.5 这一步的核心闭环

你已经拿到一枚真实 Kubernetes ServiceAccount Token，并确认它是一枚带 issuer、subject、audience 与过期时间的 JWT。Vault 的 JWT auth 会围绕这些 claim 和签名公钥做认证决策。