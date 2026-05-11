# 第 3 步：撤销应用 Token——验证『没有 Vault，一个字也读不出』

前两步用的是 dev 模式 Vault 的 `root` Token，权限过大、不能反映真实部署。本步要做的事情：

1. 写一份只允许做 transit/encrypt/payments、transit/decrypt/payments、transit/rewrap/payments 三件事的最小策略；
2. 创建一个绑定了这条策略的『应用专用』Token；
3. 用这个 Token 重启 Gin 应用；
4. **吊销这个 Token**；再次访问读取接口，观察应用立即收到 Vault 返回的 `403 permission denied` 与应用本身回写给客户端的 `502`。

这一步把 9.2 节正文里的核心论断——「Vault 是这套数据的最终单点开关，离开了 Vault 一个字也读不出」——变成可在终端里直接复现的现象。

## 3.1 写一份『只能加解密 payments 这一把密钥』的最小策略

```bash
cat > /root/eaas-policy.hcl <<'EOF'
path "transit/encrypt/payments" { capabilities = ["update"] }
path "transit/decrypt/payments" { capabilities = ["update"] }
path "transit/rewrap/payments"  { capabilities = ["update"] }
EOF

vault policy write eaas-app /root/eaas-policy.hcl
vault policy read eaas-app
```

注意三条规则都只授权 `update` 这一个动作（`transit/encrypt/<key>` 等接口在 Vault 里都是写类型操作）。这样即使应用 Token 被偷走，攻击者也**只能围绕 `payments` 这一把密钥做加 / 解密**——既不能换密钥、不能创建新密钥、也不能读其他路径的任何机密。这正是 [2.6 节](/ch2-policies) 介绍的『最小权限策略』在具体应用场景里的落地。

## 3.2 创建一个绑定了 `eaas-app` 策略的 Token

```bash
APP_TOKEN=$(vault token create -policy=eaas-app -ttl=24h -format=json \
  | jq -r .auth.client_token)
echo "APP_TOKEN=$APP_TOKEN"
```

把它打印出来，便于一眼看到下一步把哪个 Token 注入了应用。

## 3.3 用 `APP_TOKEN` 重启应用

先停掉第 1 步以 `root` Token 启动的旧实例：

```bash
pkill -x app
sleep 1
ps -ef | grep -E '[a]pp$' || echo '✅ 旧应用进程已退出'
```

然后用 `APP_TOKEN` 启动新实例（注意把 `DATABASE_URL` 也带上，让应用连得上 PostgreSQL）：

```bash
cd /root/eaas-app
DATABASE_URL="$DATABASE_URL" \
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$APP_TOKEN \
  nohup ./app > app.log 2>&1 &
echo $! > app.pid
sleep 2
tail -n 5 app.log
```

预期最后一行仍是 `[GIN-debug] Listening and serving HTTP on :8080`。

验证应用此时仍能正常工作：

```bash
curl -s http://127.0.0.1:8080/payments | head -c 200
echo
```

应当仍能看到带明文 `cc_info` 的列表——这证明 `eaas-app` 策略已经够用，没有给应用多余的权限、也没有少给应用必需的权限。

## 3.4 吊销 `APP_TOKEN`、再次请求

这是本步的高潮——模拟运维人员在审计中发现一个『应用 Token 疑似泄露』并立刻吊销它的场景：

```bash
vault token revoke "$APP_TOKEN"
echo '--- 立即再读一次 ---'
curl -s -w "\nHTTP %{http_code}\n" http://127.0.0.1:8080/payments
```

预期：Vault 在 `revoke` 之后毫秒级生效，下一次读请求时应用通过 `transit/decrypt/payments` 调用返回的状态码就变成 `403`，应用本身把这条错误转换成给客户端的 `502 Bad Gateway`。最终终端输出形如：

```
{"error":"vault transit/decrypt/payments -\u003e HTTP 403: {\"errors\":[\"2 errors occurred:\\n\\t* permission denied\\n\\t* invalid token\\n\\n\"]}\n"}
HTTP 502
```

业务读链路被一键切断。PostgreSQL 里的 `payments` 表没有任何变化、依然完整地存在那里——但**没有 Vault，它一个字也读不出**。

## 3.5 把应用恢复到可工作状态（便于后续清理）

为了不让最后一步把应用留在崩溃状态，给它发一个新 Token、再次确认能读：

```bash
NEW_TOKEN=$(vault token create -policy=eaas-app -ttl=1h -format=json \
  | jq -r .auth.client_token)
pkill -x app; sleep 1
cd /root/eaas-app
DATABASE_URL="$DATABASE_URL" \
  VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$NEW_TOKEN \
  nohup ./app > app.log 2>&1 &
echo $! > app.pid
sleep 2
curl -s http://127.0.0.1:8080/payments | head -c 200
echo
```

应当再次看到带明文 `cc_info` 的列表——证明业务并没有因为一次 Token 吊销而需要触碰任何业务数据库；只要给一个新的、合法的 Token，整条业务链路立即重新可用。

---

## ✅ 验收

- [ ] `vault policy read eaas-app` 显示三条 `update` 规则
- [ ] 用 `APP_TOKEN` 启动的应用能正常 `GET /payments`
- [ ] `vault token revoke "$APP_TOKEN"` 之后，下一次 `GET /payments` 立即得到 `HTTP 502`，且响应里夹带 Vault 的 `permission denied` 文本
- [ ] 给应用发一个新 Token、重启之后业务立即恢复，PostgreSQL 表内容无任何变动

至此完成本实验全部三步：从『建立 EaaS 闭环』到『无中断密钥轮转』再到『以 Token 吊销作为最终单点开关』，9.2 节正文中所有关键论断都已在终端里得到亲手验证。
