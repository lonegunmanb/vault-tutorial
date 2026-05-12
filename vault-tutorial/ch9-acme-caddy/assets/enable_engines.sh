#!/bin/bash
# 一键搭好两级 PKI（根 CA pki/ + 中间 CA pki_int/）。
# 与 HashiCorp 官方 pki-acme-caddy 教程同名脚本逻辑一致，差异只有：
#   - issuer 名换成 root-2024（图省事，可以是任意字符串）；
#   - cluster path / aia_path 换成 http://127.0.0.1:8200/...
#     （官方用的是 docker bridge 上的 10.1.1.100，本实验用 host 网络）；
#   - 角色 max_ttl 设为 720h（30 天），符合 ACME 协议『短 TTL + 频繁续期』理念。
#
# 运行：cd /root/pki && ./enable_engines.sh
set -euxo pipefail

cd "$(dirname "$0")"

# 1) 启用根 CA：pki/
vault secrets enable pki
vault secrets tune -max-lease-ttl=87600h pki

# 2) 在根 CA 上自签一张根证书；落盘到 root_2024_ca.crt 供 curl --cacert 使用
vault write -field=certificate pki/root/generate/internal \
   common_name="learn.internal" \
   issuer_name="root-2024" \
   ttl=87600h > root_2024_ca.crt

# 3) 配置根 CA 的 cluster 路径（影响后续 AIA / CRL / OCSP URL 模板）
vault write pki/config/cluster \
   path=http://127.0.0.1:8200/v1/pki \
   aia_path=http://127.0.0.1:8200/v1/pki

vault write pki/roles/2024-servers \
   allow_any_name=true \
   no_store=false

vault write pki/config/urls \
   issuing_certificates="{{cluster_aia_path}}/issuer/{{issuer_id}}/der" \
   crl_distribution_points="{{cluster_aia_path}}/issuer/{{issuer_id}}/crl/der" \
   ocsp_servers="{{cluster_path}}/ocsp" \
   enable_templating=true

# 4) 启用中间 CA：pki_int/
vault secrets enable -path=pki_int pki
vault secrets tune -max-lease-ttl=43800h pki_int

# 5) 中间 CA 生成 CSR、提交给根 CA 签名、把签好的证书写回中间 CA
vault write -format=json pki_int/intermediate/generate/internal \
   common_name="learn.internal Intermediate Authority" \
   issuer_name="learn-intermediate" \
   | jq -r '.data.csr' > pki_intermediate.csr

vault write -format=json pki/root/sign-intermediate \
   issuer_ref="root-2024" \
   csr=@pki_intermediate.csr \
   format=pem_bundle ttl="43800h" \
   | jq -r '.data.certificate' > intermediate.cert.pem

vault write pki_int/intermediate/set-signed certificate=@intermediate.cert.pem

# 6) 配置中间 CA 的 cluster 路径——ACME directory 会根据这里的 path
#    返回 newAccount / newOrder / newNonce 等绝对 URL
vault write pki_int/config/cluster \
   path=http://127.0.0.1:8200/v1/pki_int \
   aia_path=http://127.0.0.1:8200/v1/pki_int

# 7) 中间 CA 上的签发角色：max_ttl=720h（30 天），allow_any_name=true 让
#    实验里的 caddy.local 这种非真实域名也能签出来
vault write pki_int/roles/learn \
   issuer_ref="$(vault read -field=default pki_int/config/issuers)" \
   allow_any_name=true \
   max_ttl="720h" \
   no_store=false

vault write pki_int/config/urls \
   issuing_certificates="{{cluster_aia_path}}/issuer/{{issuer_id}}/der" \
   crl_distribution_points="{{cluster_aia_path}}/issuer/{{issuer_id}}/crl/der" \
   ocsp_servers="{{cluster_path}}/ocsp" \
   enable_templating=true

echo "✅ 两级 PKI 已就绪：根 CA (pki/) + 中间 CA (pki_int/)"
echo "   根 CA 证书已落盘：$(pwd)/root_2024_ca.crt"
