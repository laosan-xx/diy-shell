<script setup>
import { ref } from 'vue'
import { RouterLink } from 'vue-router'

defineProps({
  tool: { type: Object, required: true },
})

const imgError = ref(false)

function fmtStar(n) {
  if (n == null) return ''
  return n >= 1000 ? (n / 1000).toFixed(1) + 'k' : '' + n
}
</script>

<template>
  <RouterLink
    :to="`/tool/${tool.id}`"
    class="group block rounded-xl border border-slate-800 bg-slate-900/50 p-5 transition hover:border-emerald-500/60 hover:bg-slate-900"
  >
    <div class="flex items-center gap-3">
      <img
        v-if="tool.icon && !imgError"
        :src="tool.icon"
        :alt="tool.name"
        class="w-12 h-12 rounded-lg object-cover bg-slate-800"
        @error="imgError = true"
      />
      <div
        v-else
        class="w-12 h-12 shrink-0 rounded-lg bg-gradient-to-br from-emerald-500/30 to-sky-500/30 flex items-center justify-center font-bold text-emerald-200"
      >
        {{ tool.name.charAt(0) }}
      </div>

      <div class="min-w-0 flex-1">
        <h3 class="font-semibold truncate group-hover:text-emerald-300">{{ tool.name }}</h3>
        <div class="flex flex-wrap gap-1 mt-1">
          <span
            v-for="p in tool.platform"
            :key="p"
            class="text-[11px] px-1.5 py-0.5 rounded bg-slate-800 text-slate-400"
          >{{ p }}</span>
        </div>
      </div>

      <div class="text-right text-xs text-slate-500 shrink-0">
        <div v-if="tool.stars != null">★ {{ fmtStar(tool.stars) }}</div>
        <div v-if="tool.release" class="text-emerald-400 mt-0.5">{{ tool.release.tag }}</div>
      </div>
    </div>

    <p class="text-sm text-slate-400 mt-3 line-clamp-2">{{ tool.description }}</p>

    <div class="mt-4 text-sm text-emerald-400">查看详情 →</div>
  </RouterLink>
</template>
