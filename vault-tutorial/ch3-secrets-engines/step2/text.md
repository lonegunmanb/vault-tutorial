# 第二步：路径大小写敏感与挂载点前缀冲突

3.1 章节列出过两条**很容易踩坑**的硬性规则。这一步亲手让 Vault 拒绝两类非法操作，把规则刻进肌肉记忆。

## 2.1 路径**大小写敏感**

Vault 把挂载路径当作普通字符串处理——`kv` 与 `KV` 是两个完全不同的 Path。来挂两个只有大小写不同的路径：

```bash
vault secrets enable -path=case-test -version=2 kv
vault secrets enable -path=Case-Test -version=2 kv
```

两条命令**都会成功**，因为 Vault 把它们看成两个不同的挂载点：

```bash
vault secrets list -format=json | jq '
  to_entries
  | map(select(.key | test("^[Cc]ase-[Tt]est/$")))
  | map({path: .key, accessor: .value.accessor})
'
```

输出两条不同的 Accessor，证明它们是两个独立实例。

往两个实例分别写数据：

```bash
vault kv put case-test/sample value=lower
vault kv put Case-Test/sample value=UPPER
```

读出来：

```bash
echo "lower-case mount: $(vault kv get -field=value case-test/sample)"
echo "Mixed-case mount: $(vault kv get -field=value Case-Test/sample)"
```

输出：

```
lower-case mount: lower
Mixed-case mount: UPPER
```

**两套数据互不干扰**。如果你在 Policy 里写错了大小写，得到的不是 ACL 命中失败，而是数据打到了"另一个挂载点"上——更隐蔽，也更危险。

> **生产经验**：项目里强制约定挂载路径全部使用小写（或全部带破折号的 kebab-case），并用 lint 检查 Policy 文件中的路径写法，避免大小写漂移。

清理一下，方便后续步骤：

```bash
vault secrets disable case-test/
vault secrets disable Case-Test/
```

> 注意 `disable` 是销毁式卸载——上面的 `case-test/sample` 与 `Case-Test/sample` 在执行 `disable` 后会**永久消失**。第三步会专门验证这一点。

## 2.2 挂载点不能互为前缀

来挂一个深路径：

```bash
vault secrets enable -path=apps/team-a/kv -version=2 kv
```

这是合法的——`apps/team-a/kv/` 下面没有任何已存在的挂载点。

接下来尝试挂一个**作为它前缀**的路径：

```bash
vault secrets enable -path=apps -version=2 kv
```

Vault 会拒绝：

```
Error enabling: ... existing mount at apps/team-a/kv ...
```

错误信息会明确告诉你是因为 `apps/` 会"包住"已存在的 `apps/team-a/kv/`。

反过来也不行——如果先挂浅路径，再尝试在它下面挂深路径：

```bash
vault secrets enable -path=projects -version=2 kv
vault secrets enable -path=projects/secrets -version=2 kv
```

第二条同样会失败。

但**同级不同名**完全没有问题，3.1 章节里的例子是合法的：

```bash
vault secrets enable -path=apps/team-a/kv-other -version=2 kv
```

```bash
vault secrets list -format=json | jq 'keys[] | select(startswith("apps/"))'
```

输出：

```
"apps/team-a/kv-other/"
"apps/team-a/kv/"
```

两个同级路径和平共存。

> **Vault 的设计本意**：Router 在分发请求时按"最长前缀匹配"找到唯一挂载点。如果允许嵌套挂载，Router 就要面对"路径前缀有歧义、不知道分发给谁"的问题。这条规则保证 Router 永远只能找到**唯一**的挂载点。

清理：

```bash
vault secrets disable apps/team-a/kv/
vault secrets disable apps/team-a/kv-other/
vault secrets disable projects/
```
