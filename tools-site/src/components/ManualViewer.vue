<script setup>
import { ref, watch, onMounted } from 'vue'
import { marked } from 'marked'

const props = defineProps({
  source: { type: String, required: true },
})

const html = ref('')

// 以 http(s) 开头或 .md 结尾视为远程/文件资源，需 fetch 加载；
// 否则当作内联 Markdown 文本直接渲染。
function isRemoteOrFile(s) {
  return /^https?:\/\//.test(s) || /\.md$/i.test(s)
}

async function render() {
  let md = props.source
  if (isRemoteOrFile(props.source)) {
    try {
      const url = props.source.startsWith('http')
        ? props.source
        : `${import.meta.env.BASE_URL}${props.source.replace(/^\//, '')}`
      const res = await fetch(url)
      md = await res.text()
    } catch (e) {
      md = '_手册加载失败，请检查链接或文件路径。_'
    }
  }
  html.value = marked.parse(md || '')
}

onMounted(render)
watch(() => props.source, render)
</script>

<template>
  <article
    class="md rounded-xl border border-slate-800 bg-slate-900/40 p-6"
    v-html="html"
  ></article>
</template>
