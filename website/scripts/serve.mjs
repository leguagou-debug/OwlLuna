import { createReadStream } from 'node:fs'
import { stat } from 'node:fs/promises'
import { createServer } from 'node:http'
import { extname, join, resolve, sep } from 'node:path'

export const basePath = process.env.BASE_PATH ?? ''
export const root = resolve('out')

const types = {
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.txt': 'text/plain; charset=utf-8',
  '.webp': 'image/webp',
  '.woff2': 'font/woff2',
  '.xml': 'application/xml',
}

async function find(pathname) {
  if (!pathname.startsWith(`${basePath}/`)) return null
  const file = join(root, decodeURIComponent(pathname.slice(basePath.length)))
  if (file !== root && !file.startsWith(root + sep)) return null
  const info = await stat(file).catch(() => null)
  if (info?.isDirectory()) return pathname.endsWith('/') ? find(`${pathname}index.html`) : { moved: `${pathname}/` }
  return info?.isFile() ? { file } : null
}

/** Serves `out/` under the base path as GitHub Pages does, so a link that leaves the base path out is a 404. */
export async function serveOut() {
  const server = createServer(async (request, response) => {
    const url = new URL(request.url, 'http://localhost')
    const found = await find(url.pathname)
    if (found?.moved) {
      response.writeHead(301, { location: found.moved + url.search }).end()
    } else if (found) {
      response.writeHead(200, { 'content-type': types[extname(found.file)] ?? 'application/octet-stream' })
      createReadStream(found.file).pipe(response)
    } else {
      response.writeHead(404).end()
    }
  })
  await new Promise((done) => server.listen(0, '127.0.0.1', done))
  return {
    origin: `http://127.0.0.1:${server.address().port}`,
    close: () => {
      server.closeAllConnections()
      return new Promise((done) => server.close(done))
    },
  }
}
