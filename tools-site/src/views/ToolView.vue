<script setup>
import { ref, onMounted, watch } from 'vue'
import { useRoute, RouterLink } from 'vue-router'
import ManualViewer from '../components/ManualViewer.vue'
import VideoPlayer from '../components/VideoPlayer.vue'
import { enrichTool, getReadme, withProxy } from '../github.js'

const route = useRoute()
const tool = ref(null)
const manualSource = ref('')
const imgError = ref(false)

// 下载代理：默认优先加速；用户偏好记忆在 localStorage
const proxyDomain = ref('')
const useProxy = ref(localStorage.getItem('dl_proxy') !== 'off')

function setProxy(v) {
  useProxy.value = v
  localStorage.setItem('dl_proxy', v ? 'on' : 'off')
}
function proxied(url) {
  return useProxy.value && proxyDomain.value ? withProxy(url, proxyDomain.value) : url
}

function fmtSize(n) {
  if (n == null) return ''
  const units = ['B', 'KB', 'MB', 'GB']
  let i = 0
  while (n >= 1024 && i < units.length - 1) {
    n /= 1024
    i++
  }
  return (i ? n.toFixed(1) : n) + units[i]
}

async function load() {
  tool.value = null
  manualSource.value = ''
  imgError.value = false
  try {
    const res = await fetch(`${import.meta.env.BASE_URL}data/tools.json`)
    const data = await res.json()
    proxyDomain.value = data.proxy?.domain || ''
    const base = (data.tools || []).find((t) => t.id === route.params.id)
    if (!base) {
      tool.value = null
      return
    }
    const e = await enrichTool(base)
    tool.value = e

    // 手册：若声明 readme:true 则拉取仓库 README，否则用手动 manual 字段
    if (e.readme) {
      const [o, r] = e.repo.split('/')
      try {
        manualSource.value = await getReadme(o, r, e.defaultBranch)
      } catch (err) {
        manualSource.value = e.manual || ''
      }
    } else {
      manualSource.value = e.manual || ''
    }
  } catch (e) {
    tool.value = null
  }
}

onMounted(load)
watch(() => route.params.id, load)
</script>

<template>
  <div v-if="!tool" class="text-slate-400">未找到该工具，或加载中…</div>

  <div v-else class="space-y-10">
    <RouterLink to="/" class="inline-block text-sm text-slate-400 hover:text-emerald-300">
      ← 返回工具列表
    </RouterLink>

    <header class="flex items-center gap-4">
      <img
        v-if="tool.icon && !imgError"
        :src="tool.icon"
        :alt="tool.name"
        class="w-16 h-16 rounded-xl object-cover bg-slate-800"
        @error="imgError = true"
      />
      <div
        v-else
        class="w-16 h-16 shrink-0 rounded-xl bg-gradient-to-br from-emerald-500/30 to-sky-500/30 flex items-center justify-center text-2xl font-bold text-emerald-200"
      >
        {{ tool.name.charAt(0) }}
      </div>
      <div>
        <h1 class="text-2xl font-bold flex items-center gap-2">
          {{ tool.name }}
          <span v-if="tool.stars != null" class="text-sm font-normal text-slate-400">★ {{ tool.stars }}</span>
        </h1>
        <p class="text-slate-400 mt-1">{{ tool.description }}</p>
        <p
          v-if="tool.release"
          class="text-xs text-slate-500 mt-1"
        >最新版本 {{ tool.release.tag }} · 更新于 {{ new Date(tool.release.publishedAt).toLocaleDateString() }}</p>
      </div>
    </header>

    <!-- 下载：自动来自 GitHub Release assets，可切换官方/加速地址 -->
    <section>
      <h2 class="text-lg font-semibold mb-3 flex items-center gap-2">📥 下载</h2>

      <div v-if="proxyDomain" class="flex items-center gap-2 mb-4 text-sm">
        <span class="text-slate-400">下载源：</span>
        <button
          @click="setProxy(false)"
          :class="!useProxy
            ? 'bg-emerald-500/20 border-emerald-500 text-emerald-300'
            : 'border-slate-700 text-slate-300 hover:border-slate-500'"
          class="px-3 py-1.5 rounded-lg border transition"
        >官方原地址</button>
        <button
          @click="setProxy(true)"
          :class="useProxy
            ? 'bg-emerald-500/20 border-emerald-500 text-emerald-300'
            : 'border-slate-700 text-slate-300 hover:border-slate-500'"
          class="px-3 py-1.5 rounded-lg border transition"
        >加速 ({{ proxyDomain }})</button>
      </div>

      <div v-if="tool.release && tool.release.assets.length" class="flex flex-col gap-2 sm:flex-row sm:flex-wrap">
        <a
          v-for="a in tool.release.assets"
          :key="a.url"
          :href="proxied(a.url)"
          target="_blank"
          rel="noopener noreferrer"
          class="px-4 py-2 rounded-lg bg-emerald-600 hover:bg-emerald-500 text-white text-sm font-medium transition"
        >
          {{ a.name }} <span class="opacity-75">({{ fmtSize(a.size) }})</span> ↗
        </a>
      </div>
      <p v-else class="text-sm text-slate-500 mb-2">
        暂未获取到 Release，请前往仓库下载。
      </p>
      <a
        :href="proxied((tool.htmlUrl || '#') + '/releases')"
        target="_blank"
        rel="noopener noreferrer"
        class="inline-block mt-2 px-4 py-2 rounded-lg border border-slate-700 hover:border-emerald-500 text-sm transition"
      >
        查看所有版本 ↗
      </a>
    </section>

    <!-- 操作手册：手动维护，或 readme:true 时用仓库 README -->
    <section v-if="manualSource">
      <h2 class="text-lg font-semibold mb-3 flex items-center gap-2">📖 操作手册</h2>
      <ManualViewer :source="manualSource" />
    </section>

    <!-- 视频教程：手动维护 -->
    <section v-if="tool.videos && tool.videos.length">
      <h2 class="text-lg font-semibold mb-3 flex items-center gap-2">🎬 视频教程</h2>
      <div class="grid gap-4 sm:grid-cols-2">
        <VideoPlayer v-for="(v, i) in tool.videos" :key="i" :video="v" />
      </div>
    </section>
  </div>
</template>
