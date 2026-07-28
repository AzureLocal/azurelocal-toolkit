import { defineConfig } from 'vitepress'

export default defineConfig({
  ignoreDeadLinks: true,
  base: '/azurelocal-toolkit/',
  title: "Azure Local Toolkit",
  description: "Governed centrally by HCS Platform Engineering standards",
  themeConfig: {
    nav: {"link":"/","text":"Home"},
    sidebar: {"link":"/","text":"Home"},
    socialLinks: [
      { icon: 'github', link: 'https://github.com/AzureLocal/azurelocal-toolkit' }
    ],
    footer: {
      message: 'Released under the MIT License.',
      copyright: 'Copyright © Hybrid Cloud Solutions & AzureLocal'
    }
  }
})




