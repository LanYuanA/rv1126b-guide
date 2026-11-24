import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { sources } from './sources.mjs'

// 只在本地开发模式读取选定的 SDK 源码片段，静态构建不依赖 SDK。
export function localSourceReader() {
  const sdk = new URL('../../atk_dlrv1126b_linux6.1_sdk/', import.meta.url)
  return {
    name: 'rv1126b-local-source',
    apply: 'serve',
    configureServer(server) {
      server.middlewares.use(async (req, res, next) => {
        const [path, query] = (req.url || '').split('?')
        const match = path.match(/^(?:\/rv1126b)?\/__reader\/([a-z0-9-]+)$/)
        if (!match || !Object.hasOwn(sources, match[1])) return next()
        const [file, start] = sources[match[1]]
        res.setHeader('Content-Type', 'text/plain; charset=utf-8')
        res.setHeader('Cache-Control', 'no-store')
        try {
          const content = await readFile(fileURLToPath(new URL(file, sdk)), 'utf8')
          const lines = content.split('\n')
          if (query) {
            const params = new URLSearchParams(query)
            const first = Number(params.get('start'))
            const count = Number(params.get('lines'))
            if (!Number.isInteger(first) || first < Math.max(1, start - 20) ||
                first > start + 90 || first > lines.length ||
                !Number.isInteger(count) || count < 1 || count > 10) {
              res.statusCode = 400
              res.end('源码显示范围无效。')
              return
            }
            res.end(lines.slice(first - 1, first - 1 + count).join('\n'))
            return
          }
          const lo = Math.max(0, start - 6)
          const excerpt = lines.slice(lo, start + 90).map((line, i) => (lo + i + 1) + '  ' + line)
          res.end([file + ':' + start, '', ...excerpt].join('\n'))
        } catch {
          res.statusCode = 404
          res.end('未找到本机 SDK 文件。请核对工作区内的 SDK 路径和版本。')
        }
      })
    },
  }
}
