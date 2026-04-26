import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'Vault 交互式教程',
  description: '基于 Killercoda 的零成本交互式 HashiCorp Vault 教程',
  base: '/vault-tutorial/',
  lang: 'zh-CN',
  sitemap: {
    hostname: 'https://lonegunmanb.github.io/vault-tutorial/'
  },

  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><text y=".9em" font-size="90">🔐</text></svg>' }],
  ],

  themeConfig: {
    nav: [
      { text: '首页', link: '/' },
      { text: '开始学习', link: '/intro' },
    ],

    // @auto-sidebar-start
    sidebar: [
      {
        text: '教程章节',
        items: [
         { text: '课程介绍', link: '/intro' },
         { text: '什么是现代意义上的 Vault', link: '/what-is-vault' },
         {
           text: '第 2 章：核心机制与高级状态机概念',
           collapsed: false,
           items: [
             { text: '2.1 "Dev" 开发模式的适用边界与安全风险预警', link: '/ch2-dev-mode' },
             { text: '2.2 封印与解封（Seal/Unseal）机制的密码学底层原理', link: '/ch2-seal-unseal' },
             { text: '2.3 租约（Lease）、无感续期与强制撤销的生命周期管理', link: '/ch2-lease' },
             { text: '2.4 认证（Authentication）与令牌（Tokens）树状层级关系本质', link: '/ch2-auth-tokens' },
             { text: '2.5 身份实体（Identity Entity）：打通多维度认证源的元数据中心', link: '/ch2-identity-entity' },
             { text: '2.6 细粒度策略（Policies）与合规性密码策略（Password Policies）编写指南', link: '/ch2-policies' },
             { text: '2.7 响应封装（Response Wrapping）与防篡改一次性数据传递', link: '/ch2-response-wrapping' }
           ]
         },
         {
           text: '第 3 章：核心机密引擎管理体系 (Secret Engines)',
           collapsed: false,
           items: [
             { text: '3.1 机密引擎概览：路由、生命周期与 Barrier View', link: '/ch3-secrets-engines' },
             { text: '3.2 Key/Value (KV v2) 引擎：版本控制的现代静态机密存储', link: '/ch3-kv-v2' },
             { text: '3.3 AWS 机密引擎：动态 IAM 凭据与租约即生命周期', link: '/ch3-aws' },
             { text: '3.4 Cubbyhole 机密引擎：每个 Token 一个私人储物柜', link: '/ch3-cubbyhole' }
           ]
         },
         {
           text: '第 5 章：现代命令行工具与高级管理实战 (CLI)',
           collapsed: false,
           items: [
             { text: '5.7 底层引擎挂载点无损热迁移（Mount Migration）技术剖析', link: '/ch5-mount-migration' }
           ]
         }
        ],
      },
    ],
    // @auto-sidebar-end

    socialLinks: [
      { icon: 'github', link: 'https://github.com/lonegunmanb/vault-tutorial' },
    ],

    outline: { label: '本页目录' },
    docFooter: { prev: '上一章', next: '下一章' },
    darkModeSwitchLabel: '主题',
    sidebarMenuLabel: '菜单',
    returnToTopLabel: '回到顶部',
  },
})
