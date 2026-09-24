<script setup>
const props = defineProps({
  video: { type: Object, required: true },
})

// type 显式指定优先；否则按扩展名推断是否为本地视频文件
function isFile(v) {
  if (v.type) return v.type === 'file'
  return /\.(mp4|webm|ogg|mov)$/i.test(v.url)
}
</script>

<template>
  <div class="rounded-xl border border-slate-800 bg-slate-900/40 overflow-hidden">
    <div class="aspect-video bg-black">
      <iframe
        v-if="!isFile(video)"
        :src="video.url"
        class="w-full h-full"
        frameborder="0"
        allowfullscreen
        allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
      ></iframe>
      <video
        v-else
        :src="video.url"
        controls
        class="w-full h-full"
      ></video>
    </div>
    <div class="px-4 py-2 text-sm text-slate-300">{{ video.title }}</div>
  </div>
</template>
