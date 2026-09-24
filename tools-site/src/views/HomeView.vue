<script setup>
import { ref, computed, onMounted } from 'vue'
import ToolCard from '../components/ToolCard.vue'
import { enrichTool, clearGitHubCache } from '../github.js'

const enriched = ref([])
const loading = ref(true)
const activePlatform = ref('全部')

const platforms = computed(() => {
  const set = new Set(['全部'])
  enriched.value.forEach((t) => t.platform?.forEach((p) => set.add(p)))
  return [...set]
})

const filtered = computed(() =>
  activePlatform.value === '全部'
    ? enriched.value
    : enriched.value.filter((t) => t.platform?.includes(activePlatform.value)),
)

async function loadAll() {
  loading.value = true
  try {
    const res = await fetch(`${import.meta.env.BASE_URL}data/tools.json`)
    const data = await res.json()
    const list = data.tools || []
    enriched.value = await Promise.all(list.map((t) => enrichTool(t)))
  } catch (e) {
    enriched.value = []
  }
  loading.value = false
}

function refresh() {
  clearGitHubCache()
  loadAll()
}

onMounted(loadAll)
</script>

<template>
  <section>
    <div class="flex items-end justify-between mb-8 gap-4 flex-wrap">
      <div>
        <h1 class="text-2xl font-bold">常用代理工具</h1>
        <p class="text-slate-400 mt-1">下载客户端、查看操作手册与视频教程（数据实时来自 GitHub）</p>
      </div>
      <button
        @click="refresh"
        :disabled="loading"
        class="text-sm px-3 py-1.5 rounded-lg border border-slate-700 hover:border-emerald-500 transition disabled:opacity-50"
      >
        {{ loading ? '加载中…' : '↻ 刷新数据' }}
      </button>
    </div>

    <div class="flex flex-wrap gap-2 mb-6">
      <button
        v-for="p in platforms"
        :key="p"
        @click="activePlatform = p"
        :class="[
          'px-3 py-1.5 rounded-full text-sm border transition',
          activePlatform === p
            ? 'bg-emerald-500/20 border-emerald-500 text-emerald-300'
            : 'border-slate-700 text-slate-300 hover:border-slate-500',
        ]"
      >
        {{ p }}
      </button>
    </div>

    <div v-if="loading" class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
      <div
        v-for="n in 4"
        :key="n"
        class="h-36 rounded-xl border border-slate-800 bg-slate-900/40 animate-pulse"
      ></div>
    </div>
    <div v-else-if="enriched.length" class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
      <ToolCard v-for="t in filtered" :key="t.id" :tool="t" />
    </div>
    <p v-else class="text-slate-500">暂无工具数据，请检查 data/tools.json。</p>
  </section>
</template>
