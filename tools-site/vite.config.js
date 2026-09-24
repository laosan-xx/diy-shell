import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// base: './' 让构建产物使用相对路径，方便部署到任意子目录/静态服务器
export default defineConfig({
  plugins: [vue()],
  base: './',
})
