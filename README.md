# Vault 交互式教程

基于 VitePress + Killercoda 的零成本交互式 HashiCorp Vault 教程（中文）。

- 前端：VitePress 静态站点，部署到 GitHub Pages
- 实验环境：Killercoda 沙盒（Ubuntu + Vault），提供真实终端和 Vault CLI
- CI/CD：推送 `main` 分支自动构建部署

## 本地开发

```bash
npm install
npm run dev          # 启动 VitePress 开发服务器
npm run sync-sidebar # 添加/删除 docs/*.md 后手动同步侧边栏
```

## 构建与预览

```bash
npm run build    # 产物输出到 docs/.vitepress/dist/（自动运行 sidebar + setup 同步）
npm run preview  # 本地预览构建产物
```

推送到 `main` 分支会触发 GitHub Actions 自动部署到 GitHub Pages。

## 项目结构

```
docs/                          # VitePress 内容（Markdown 教程章节）
  .vitepress/
    config.mjs                 # VitePress 配置（侧边栏自动管理）
    components/
      KillercodaEmbed.vue      # Killercoda 实验链接按钮组件
      SponsorBanner.vue        # 全局致谢横幅
    theme/
      index.js                 # 主题入口
      Layout.vue               # 自定义布局（注入 SponsorBanner）
vault-tutorial/                # Killercoda 场景定义
  structure.json               # 场景列表
  vault-basics/                # 每个场景一个目录
scripts/
  setup-common.sh              # 共享环境初始化脚本（唯一编辑源）
  sync-setup-common.mjs        # 将 setup-common.sh 复制到各场景 assets/
  sync-sidebar.mjs             # 从 docs/*.md frontmatter 自动生成侧边栏
```

## 添加新章节

1. 在 `docs/` 下新建 `.md` 文件，添加 frontmatter：

```markdown
---
order: 10        # 侧边栏排序
title: 章节标题   # 可选
---
```

2. 运行 `npm run sync-sidebar` 更新侧边栏（或推送到 main 自动触发）。

## Killercoda 场景

场景定义位于 `vault-tutorial/` 目录。将此仓库关联到 [Killercoda Creator](https://killercoda.com/creator) 账号后，需要手动在 Killercoda 上同步一次内容。

`scripts/setup-common.sh` 是所有场景共用的环境初始化脚本，运行 `npm run sync-setup` 可将其同步到各场景的 `assets/` 目录。
