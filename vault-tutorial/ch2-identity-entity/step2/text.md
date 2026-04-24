# 第二步：不同 mount 上的 alias 不会自动合并

文档 §2.1 的核心论断：

> The alias name in combination with the authentication backend mount's
> accessor, serve as the unique identifier of an alias.

也就是说——Vault 区分 alias 用的是 (alias_name, mount_accessor) 这个
组合键。**同一个 alias 名字挂到两个不同 mount 上，对 Vault 而言是两
个完全不同的人**。我们来验证。

## 2.1 在第二个路径再起一个 userpass

```bash
vault auth enable -path=userpass-corp userpass

vault write auth/userpass-corp/users/alice \
  password=s3cr3t \
  token_policies=default
```

注意——这个 `alice` 跟 step1 那个 `alice` **重名但完全无关**，因为它
们挂在不同 mount accessor 上。

## 2.2 在新 mount 上登录，得到第二个 entity_id

```bash
vault login -format=json -method=userpass -path=userpass-corp \
  username=alice password=s3cr3t > /root/alice-corp-login.json

ENT_ID_CORP=$(jq -r .auth.entity_id /root/alice-corp-login.json)
ENT_ID_ORIG=$(jq -r .auth.entity_id /root/alice-login.json)

echo "step1 中 userpass/ 上的 alice → entity_id = $ENT_ID_ORIG"
echo "本步 userpass-corp/ 上的 alice → entity_id = $ENT_ID_CORP"
```

两个 `entity_id` 应该**完全不同**。Vault 替它们各建了一条 entity，
各挂了一条 alias，它们之间没有任何关联。

## 2.3 看清两个 mount 的 accessor

```bash
vault auth list -format=json \
  | jq '{userpass: ."userpass/".accessor, userpass_corp: ."userpass-corp/".accessor}'
```

这就是 §2.1 那条唯一键的另一半。**accessor 不同 → alias 唯一键不同 →
Vault 把它们当成两个不同的人**。即便 alias name 都叫 `alice` 也无关。

## 2.4 列一下，目前 Vault 里有几条 entity / alias

```bash
echo "所有 entity:"
vault list identity/entity/id
echo ""
echo "所有 alias:"
vault list identity/entity-alias/id
```

2 条 entity、2 条 alias——分裂状态。

**这一步的核心结论**：Vault **绝不会**根据"alias 名字看起来一样"就
自动归并身份，因为它没有任何依据知道两个外部账号是不是同一个人。要
归并必须由管理员显式操作——这就是下一步要做的事。

> 这个设计虽然麻烦，但其实是必要的安全前提。如果 Vault 自动按名字
> 合并，攻击者只要在某个新 enable 的 auth mount 上注册一个跟受害者
> 同名的账号，就直接拿到了受害者的所有策略。
