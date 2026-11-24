<script setup>
import { computed, onMounted, ref, watch } from 'vue'
import { withBase } from 'vitepress'
import { sources } from '../sources.mjs'

const props = defineProps({
  id: { type: String, required: true },
  start: { type: Number, default: 0 },
  lines: { type: Number, default: 6 },
})

const entry = computed(() => sources[props.id])
const from = computed(() => props.start || entry.value?.[1])
const through = computed(() => from.value + props.lines - 1)
const code = ref('')
const unavailable = ref(false)
const dev = import.meta.env.DEV

onMounted(() => {
  if (!dev) return
  watch(() => [props.id, from.value, props.lines], async ([id, start, lines], _, onCleanup) => {
    if (!entry.value) return
    const abort = new AbortController()
    onCleanup(() => abort.abort())
    code.value = ''
    unavailable.value = false
    try {
      const url = withBase('/__reader/' + id) + '?start=' + start + '&lines=' + lines
      const response = await fetch(url, { signal: abort.signal })
      if (!response.ok) throw new Error('源码不可用')
      const snippet = await response.text()
      if (!abort.signal.aborted) code.value = snippet
    } catch {
      if (!abort.signal.aborted) unavailable.value = true
    }
  }, { immediate: true })
})
</script>

<template>
  <figure v-if="entry" class="source-excerpt">
    <figcaption><code>{{ entry[0] }}:{{ from }}–{{ through }}</code></figcaption>
    <pre v-if="code"><code>{{ code }}</code></pre>
    <p v-else-if="!dev">在项目的本地开发预览中，此处会直接显示 SDK 原文。</p>
    <p v-else-if="unavailable">当前 SDK 中未能读取这段源码。</p>
    <p v-else>正在读取本地源码…</p>
  </figure>
</template>

<style scoped>
.source-excerpt { margin: 1em 0; }
figcaption { font-size: .875em; overflow-wrap: anywhere; }
pre { overflow-x: auto; padding: .8em; border-radius: 6px; background: var(--vp-code-block-bg); }
pre code { padding: 0; background: transparent; }
.source-excerpt p { font-size: .875em; color: var(--vp-c-text-2); }
</style>
