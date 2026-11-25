import { equal } from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import process from 'node:process'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { promisify } from 'node:util'

import { build } from 'vite'

const chrome = process.env.TUNNELMASTER_TEST_CHROME
if (!chrome)
  throw new Error('Set TUNNELMASTER_TEST_CHROME to a Chrome executable.')

const directory = await mkdtemp(join(tmpdir(), 'tunnelmaster-usage-'))
try {
  const output = await build({
    configFile: false,
    logLevel: 'silent',
    resolve: { alias: { '@': resolve('src') } },
    define: { OS_PLATFORM: JSON.stringify(process.platform) },
    build: {
      write: false,
      lib: {
        entry: fileURLToPath(
          new URL(
            '../src/components/usage/usage.browser-fixture.tsx',
            import.meta.url,
          ),
        ),
        formats: ['es'],
      },
      rollupOptions: { output: { codeSplitting: false } },
    },
  })
  const chunk = output[0]?.output.find(
    (file) => file.type === 'chunk' && file.isEntry,
  )
  if (!chunk) throw new Error('Missing fixture entry')
  const page = join(directory, 'index.html')
  await writeFile(
    page,
    `<!doctype html><meta charset="utf-8"><main></main><script type="module">${chunk.code.replaceAll(/<\/script/giu, '<\\/script')}</script>`,
  )
  const { stdout } = await promisify(execFile)(
    chrome,
    [
      '--headless',
      `--user-data-dir=${join(directory, 'profile')}`,
      '--no-first-run',
      '--disable-background-networking',
      '--disable-component-update',
      '--disable-extensions',
      '--disable-sync',
      '--window-size=402,510',
      '--dump-dom',
      '--virtual-time-budget=6000',
      pathToFileURL(page).href,
    ],
    { timeout: 20_000, maxBuffer: 3_000_000 },
  )
  const failure = stdout.match(/<pre id="failure">([^<]*)<\/pre>/u)?.[1]
  equal(
    stdout.includes('data-result="passed"'),
    true,
    failure ?? 'The fixture did not finish',
  )
  console.log('Usage browser regression passed')
} finally {
  await rm(directory, { recursive: true, force: true })
}
