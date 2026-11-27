import { equal } from 'node:assert/strict'
import { Buffer } from 'node:buffer'
import { spawn } from 'node:child_process'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import process from 'node:process'
import { setTimeout as delay } from 'node:timers/promises'
import { fileURLToPath, pathToFileURL } from 'node:url'

import { build } from 'vite'

const chrome = process.env.TUNNELMASTER_TEST_CHROME
if (!chrome)
  throw new Error('Set TUNNELMASTER_TEST_CHROME to a Chrome executable.')

const directory = await mkdtemp(join(tmpdir(), 'tunnelmaster-usage-'))
let browser
let exited
let timeout
let chromeLog = ''
try {
  const output = await build({
    configFile: false,
    logLevel: 'silent',
    resolve: { alias: { '@': resolve('src') } },
    define: {
      OS_PLATFORM: JSON.stringify(process.platform),
      'process.env.NODE_ENV': '"production"',
    },
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
  const shell = await readFile(
    new URL('../src/index.html', import.meta.url),
    'utf8',
  )
  await writeFile(
    page,
    shell
      .replace('<div id="root"></div>', '<div id="root"><main></main></div>')
      .replace(/<script type="module"[^>]*><\/script>/u, ''),
  )

  browser = spawn(
    chrome,
    [
      '--headless',
      '--remote-debugging-pipe',
      `--user-data-dir=${join(directory, 'profile')}`,
      '--enable-logging=stderr',
      '--no-first-run',
      '--disable-background-networking',
      '--disable-component-update',
      '--disable-extensions',
      '--disable-sync',
      '--window-size=320,440',
      'about:blank',
    ],
    {
      stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'],
    },
  )
  const [, , log, write, read] = browser.stdio
  log.setEncoding('utf8').on('data', (value) => {
    chromeLog = (chromeLog + value).slice(-4000)
  })
  exited = new Promise((done) => browser.once('close', done))

  const pending = new Map()
  let nextId = 0
  let buffer = ''
  let stopped
  const stop = (error) => {
    stopped = error
    for (const request of pending.values()) request.reject(error)
    pending.clear()
  }
  browser.once('error', stop)
  browser.once('close', (code, signal) => {
    stop(
      new Error(
        'Chromium closed before verification completed (' +
          (signal ?? code) +
          ')',
      ),
    )
  })
  write.on('error', stop)
  read.on('error', stop)
  read.setEncoding('utf8').on('data', (value) => {
    buffer += value
    let separator = buffer.indexOf('\0')
    while (separator >= 0) {
      const message = JSON.parse(buffer.slice(0, separator))
      buffer = buffer.slice(separator + 1)
      const request = pending.get(message.id)
      if (request) {
        pending.delete(message.id)
        if (message.error) request.reject(new Error(message.error.message))
        else request.resolve(message.result)
      }
      separator = buffer.indexOf('\0')
    }
  })

  const send = (method, params, sessionId) =>
    new Promise((resolve, reject) => {
      if (stopped) {
        reject(stopped)
        return
      }
      const id = ++nextId
      pending.set(id, { resolve, reject })
      write.write(JSON.stringify({ id, method, params, sessionId }) + '\0')
    })
  timeout = setTimeout(() => {
    stop(new Error('Chromium usage regression exceeded the 30-second deadline'))
    browser.kill()
  }, 30_000)

  const { targetId } = await send('Target.createTarget', { url: 'about:blank' })
  const { sessionId } = await send('Target.attachToTarget', {
    targetId,
    flatten: true,
  })
  const evaluate = (expression, awaitPromise = false) =>
    send(
      'Runtime.evaluate',
      { expression, awaitPromise, returnByValue: true },
      sessionId,
    )
  await send(
    'Emulation.setDeviceMetricsOverride',
    {
      width: 320,
      height: 440,
      deviceScaleFactor: 2,
      mobile: false,
    },
    sessionId,
  )
  const { errorText } = await send(
    'Page.navigate',
    { url: pathToFileURL(page).href },
    sessionId,
  )
  if (errorText) throw new Error(errorText)
  for (;;) {
    const loaded = await evaluate(
      'Boolean(document.querySelector("main"))',
    ).catch(() => null)
    if (loaded?.result?.value) break
    if (stopped) throw stopped
    await delay(25)
  }

  const expression =
    'import(URL.createObjectURL(new Blob([' +
    JSON.stringify(chunk.code) +
    '], { type: "text/javascript" }))).then(({ done }) => done)'
  const { result, exceptionDetails } = await evaluate(expression, true)
  if (exceptionDetails) {
    throw new Error(
      exceptionDetails.exception?.description ?? exceptionDetails.text,
    )
  }
  equal(
    result.value?.passed,
    true,
    result.value?.failure ?? 'The fixture did not finish',
  )
  if (process.env.TUNNELMASTER_USAGE_SCREENSHOT) {
    const measured = await evaluate(
      'Math.min(900, Math.ceil(document.querySelector("[data-usage-panel-content]").getBoundingClientRect().height + 30))',
    )
    await send(
      'Emulation.setDeviceMetricsOverride',
      {
        width: 320,
        height: measured.result.value,
        deviceScaleFactor: 2,
        mobile: false,
      },
      sessionId,
    )
    await evaluate(
      'new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))',
      true,
    )
    const screenshot = await send('Page.captureScreenshot', {}, sessionId)
    await writeFile(
      process.env.TUNNELMASTER_USAGE_SCREENSHOT,
      Buffer.from(screenshot.data, 'base64'),
    )
  }
  console.log('Usage browser regression passed')
} catch (error) {
  if (chromeLog) console.error(chromeLog)
  throw error
} finally {
  clearTimeout(timeout)
  browser?.kill()
  await exited
  await rm(directory, { recursive: true, force: true })
}
