import { readdir } from 'node:fs/promises'
import AxeBuilder from '@axe-core/playwright'
import { chromium } from 'playwright-core'
import { basePath, root, serveOut } from './serve.mjs'

const pages = (await readdir(root, { recursive: true }))
  .filter((file) => file.endsWith('index.html') && !/^(_|404)/.test(file))
  .map((file) => `/${file.slice(0, -'index.html'.length)}`)
  .sort()

/** Scrolls to the foot and back so everything revealed on the way in has arrived. */
async function arriveAll() {
  const wait = (ms) => new Promise((done) => setTimeout(done, ms))
  const waiting = () =>
    [...document.querySelectorAll('[style*="opacity: 0"][style*="translate"]')].filter(
      (element) => !element.closest('[aria-hidden="true"]'),
    )
  await wait(1000)
  for (let y = 0; y < document.documentElement.scrollHeight; y += innerHeight / 2) {
    scrollTo(0, y)
    await wait(60)
  }
  for (const element of waiting()) {
    element.scrollIntoView({ block: 'center' })
    await wait(200)
  }
  scrollTo(0, 0)
  await wait(1200)
}

async function check(context, colorScheme, path) {
  const page = await context.newPage()
  const missing = []
  page.on('response', (response) => {
    if (response.status() >= 400) missing.push(`${response.status()} ${response.url().replace(server.origin, '')}`)
  })
  await page.goto(`${server.origin}${basePath}${path}`, { waitUntil: 'networkidle' })
  await page.evaluate(arriveAll)
  const { violations } = await new AxeBuilder({ page }).analyze()
  await page.close()
  if (missing.length) return [`${path} in ${colorScheme} did not load all its files:\n  ${missing.join('\n  ')}`]
  return violations
    .filter((violation) => violation.impact === 'serious' || violation.impact === 'critical')
    .map((violation) =>
      [
        `${path} in ${colorScheme}: ${violation.id} (${violation.impact}), ${violation.help}`,
        violation.helpUrl,
        ...violation.nodes.map((node) => node.target.join(' ')),
      ].join('\n  '),
    )
}

const server = await serveOut()
const browser = await chromium.launch({ channel: 'chrome' })
const found = []

for (const colorScheme of ['light', 'dark']) {
  const context = await browser.newContext({ colorScheme, reducedMotion: 'reduce' })
  found.push(...(await Promise.all(pages.map((path) => check(context, colorScheme, path)))).flat())
  await context.close()
}

await browser.close()
await server.close()
for (const report of found) console.error(report)
console.log(`${pages.length} pages checked in light and dark, ${found.length} serious or critical violations.`)
if (found.length) process.exitCode = 1
