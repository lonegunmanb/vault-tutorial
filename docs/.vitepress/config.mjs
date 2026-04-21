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
             { text: '2.1 "Dev" 开发模式的适用边界与安全风险预警', link: '/ch2-dev-mode' }
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
