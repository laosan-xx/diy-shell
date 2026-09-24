<script setup>
import { RouterLink, RouterView } from 'vue-router'
</script>

<template>
  <div class="min-h-screen flex flex-col">
    <header class="border-b border-slate-800 bg-slate-900/60 backdrop-blur sticky top-0 z-10">
      <div class="max-w-6xl mx-auto px-4 h-16 flex items-center justify-between">
        <RouterLink to="/" class="text-lg font-bold tracking-tight">
          <span class="text-emerald-400">Tool</span>Box
        </RouterLink>
        <nav class="text-sm text-slate-400 hidden sm:block">
          代理工具 · 下载 / 手册 / 视频
        </nav>
      </div>
    </header>

    <main class="flex-1 w-full max-w-6xl mx-auto px-4 py-8">
      <RouterView />
    </main>

    <footer class="border-t border-slate-800 text-center text-xs text-slate-500 py-6">
      资源来自官方公开链接，仅供学习交流使用
    </footer>
  </div>
</template>
