import { createServer } from 'node:http'
import { readFile } from 'node:fs/promises'
import { resolve, sep, extname } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(
  new URL('../../dist/export-tests/web/', import.meta.url),
)
const origin = 'http://127.0.0.1:47835'
let requests = []

const app = createServer(async (request, response) => {
  const path = decodeURIComponent(new URL(request.url, origin).pathname)
  if (path === '/health') {
    response.end('ready')
    return
  }
  const filename = resolve(root, `.${path}`)
  if (!filename.startsWith(resolve(root) + sep)) {
    response.writeHead(403).end()
    return
  }
  try {
    const data = await readFile(filename)
    const types = {
      '.html': 'text/html',
      '.js': 'application/javascript',
      '.wasm': 'application/wasm',
      '.pck': 'application/octet-stream',
    }
    response
      .writeHead(200, {
        'Content-Type': types[extname(filename)] ?? 'application/octet-stream',
        'Cache-Control': 'no-store',
      })
      .end(data)
  } catch {
    response.writeHead(404).end()
  }
})

const api = createServer(async (request, response) => {
  if (request.url === '/__requests') {
    response.setHeader('Content-Type', 'application/json')
    response.end(JSON.stringify(requests))
    return
  }
  if (request.url === '/__reset') {
    requests = []
    response.end('reset')
    return
  }
  let body = ''
  for await (const chunk of request) body += chunk
  requests.push({
    method: request.method,
    path: request.url,
    headers: request.headers,
    body: body ? JSON.parse(body) : null,
  })
  if (request.url.startsWith('/allowed/')) {
    response.setHeader('Access-Control-Allow-Origin', origin)
    response.setHeader('Vary', 'Origin')
    response.setHeader('Access-Control-Allow-Methods', 'POST')
    response.setHeader('Access-Control-Allow-Headers', 'Content-Type')
    response.setHeader('Access-Control-Max-Age', '0')
  }
  if (request.method === 'OPTIONS') {
    response.writeHead(204).end()
    return
  }
  response.setHeader('Content-Type', 'application/json')
  if (request.url === '/allowed/flags/?v=2') {
    response.end(
      JSON.stringify({
        flags: {
          'export-flag': {
            enabled: true,
            variant: 'browser',
            metadata: { payload: '{"source":"web"}' },
          },
        },
      }),
    )
  } else if (request.url === '/allowed/batch/') {
    response.end('{"status":1}')
  } else {
    response.writeHead(404).end('{}')
  }
})

api.listen(47836, '127.0.0.1', () => app.listen(47835, '127.0.0.1'))
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    app.close()
    api.close()
  })
}
