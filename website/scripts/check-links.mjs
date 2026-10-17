import { LinkChecker } from 'linkinator'
import { basePath, serveOut } from './serve.mjs'

const server = await serveOut()
const site = process.env.NEXT_PUBLIC_SITE_URL?.replace(/\/$/, '')
const ours = [server.origin, site].filter(Boolean)

const { links } = await new LinkChecker().check({
  path: `${server.origin}${basePath}/`,
  recurse: true,
  checkCss: true,
  checkFragments: true,
  urlRewriteExpressions: site
    ? [{ pattern: new RegExp(`^${RegExp.escape(site)}(?=/|$)`), replacement: `${server.origin}${basePath}` }]
    : [],
  linksToSkip: async (link) => !ours.some((start) => link.startsWith(start)),
})
await server.close()

const checked = links.filter((link) => link.state !== 'SKIPPED')
const broken = Map.groupBy(
  checked.filter((link) => link.state === 'BROKEN'),
  (link) => link.url.replace(server.origin, ''),
)
for (const [url, found] of broken) {
  const why = found[0].status === 200 ? 'No such anchor' : found[0].status || 'Failed'
  console.error(`${why}: ${url}\n${found.map((link) => `  on ${link.parent.replace(server.origin, '')}`).join('\n')}`)
}
console.log(`${checked.length} links in out/ checked, ${broken.size} broken. Links off the site are not checked.`)
if (broken.size) process.exitCode = 1
