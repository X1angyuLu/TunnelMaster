import { mockIPC, mockWindows } from '@tauri-apps/api/mocks'
import i18next from 'i18next'
import { createRoot } from 'react-dom/client'
import { initReactI18next } from 'react-i18next'
import { SWRConfig } from 'swr'

import usage from '@/locales/en/usage.json'

import { UsageWorkspace } from './usage-workspace'

const day = 86_400
const now = 1_800_000_000
const yearStart = now - 365 * day
const download = (at: number, bytes: number, connections: number) => ({
  start: at,
  upload: bytes / 2,
  download: bytes,
  samples: 1,
  connected_seconds: 3_600,
  peak_download_rate: 120_000,
  peak_upload_rate: 20_000,
  peak_connections: connections,
  sessions_started: 1,
})
const settings = {
  dropletId: '123',
  storage: 'keychain',
  keychainAvailable: true,
}
let hidden = false
let serverForceCount = 0
let settingsStorage = settings.storage
let requestedRange = ''
let openedMain = false
let probed = false
mockWindows('usage-tray')
mockIPC((command, payload) => {
  const args = payload as { range?: string; force?: boolean; storage?: string }
  switch (command) {
    case 'get_tunnelmaster_do_settings':
      return { ...settings, storage: settingsStorage }
    case 'set_tunnelmaster_do_storage':
      settingsStorage = args.storage ?? ''
      return { ...settings, storage: settingsStorage }
    case 'list_tunnelmaster_do_droplets':
      return [{ id: settings.dropletId, name: 'Test Droplet', region: 'sfo2' }]
    case 'get_tunnelmaster_do_monthly_transfer':
      if (args.force) serverForceCount += 1
      return {
        monthStart: now - day,
        asOf: now,
        outboundGib: 15,
        coverage: 1,
        remainingGib: 85,
      }
    case 'get_tunnelmaster_do_report':
      if (args.force) serverForceCount += 1
      return {
        from: now - day,
        until: now,
        bucketSeconds: 3600,
        inbound: { samples: [] },
        outbound: { samples: [] },
        buckets: [
          {
            start: now - 3600,
            until: now,
            inboundBytes: 524_288,
            outboundBytes: 1_048_576,
            inboundCoveredSeconds: 1800,
            outboundCoveredSeconds: 3500,
          },
        ],
      }
    case 'tunnelmaster_local_history': {
      requestedRange = args.range ?? ''
      const live = requestedRange === '60s'
      const annual = requestedRange === '365d'
      const from = live
        ? now - 60
        : annual
          ? yearStart
          : requestedRange === '90d'
            ? now - 90 * day
            : now - 3_600
      return {
        from,
        until: now,
        bucket_seconds: live
          ? 5
          : annual || requestedRange === '90d'
            ? day
            : 300,
        sampled_at: now,
        current_download: 320,
        current_upload: 100,
        sampling: true,
        live_rates: [
          { at: now - 10, download: 80, upload: 20 },
          { at: now - 5, download: 160, upload: 40 },
        ],
        previous: live ? null : { upload: 1_048_576, download: 2_097_152 },
        buckets: live
          ? []
          : annual
            ? [
                download(yearStart + 20 * day, 4096, 3),
                download(yearStart + 300 * day, 8192, 9),
              ]
            : [download(from, 8192, 9)],
      }
    }
    case 'plugin:window|hide':
      hidden = true
      return
    case 'open_tunnelmaster_usage':
      openedMain = true
      return
    case 'probe_tunnelmaster_egress':
      probed = true
      return { ip: '203.0.113.7', country: 'US' }
  }
  throw new Error(`Unexpected command ${command}`)
})

const check = (condition: unknown, label: string) => {
  if (!condition) throw new Error(label)
}
const button = (text: string) =>
  [...document.querySelectorAll('button')].find(
    (item) => item.textContent?.trim() === text,
  )
const chart = () =>
  document.querySelector<SVGSVGElement>('svg[aria-describedby]')
const summary = () => {
  const id = chart()?.getAttribute('aria-describedby')
  return id ? document.getElementById(id)?.textContent : ''
}
const waitFor = async (condition: () => unknown, label: string) => {
  for (let retry = 0; retry < 80; retry += 1) {
    if (condition()) return
    await new Promise<void>((resolve) => setTimeout(resolve, 25))
  }
  throw new Error(label)
}

async function run() {
  await i18next.use(initReactI18next).init({
    lng: 'en',
    resources: { en: { translation: { usage } } },
  })
  const container = document.querySelector('main')
  if (!container) throw new Error('Missing fixture root')
  const root = createRoot(container)
  root.render(
    <SWRConfig value={{ provider: () => new Map() }}>
      <UsageWorkspace compact />
    </SWRConfig>,
  )
  await waitFor(
    () => document.body.textContent?.includes('Test Droplet · sfo2'),
    'Configured server and region not visible in tray',
  )
  await waitFor(
    () =>
      summary()?.includes('Inbound coverage 50%') &&
      summary()?.includes('1 MiB'),
    'Server volume and coverage not visible together',
  )
  const refreshButton = () =>
    document.querySelector<HTMLButtonElement>('button[aria-label="Refresh"]')
  await waitFor(
    () => refreshButton()?.disabled === false,
    'Server refresh remained disabled',
  )
  refreshButton()?.click()
  await waitFor(
    () => serverForceCount === 2,
    'Manual refresh did not force new server data',
  )
  check(!probed, 'Showing the panel started an exit IP probe')
  button('This device')?.click()
  await waitFor(() => button('1 year'), 'One-year range missing in tray')
  document
    .querySelector<HTMLButtonElement>('button[aria-label="Test exit IP"]')
    ?.click()
  await waitFor(
    () => document.body.textContent?.includes('203.0.113.7 · US'),
    'Manual exit probe did not show the mocked IP and country',
  )
  button('90 d')?.click()
  await waitFor(
    () =>
      requestedRange === '90d' &&
      document.body.textContent?.includes(
        'Previous period · ↓ 2 MiB · ↑ 1 MiB',
      ),
    '90-day view or previous-period totals are missing',
  )
  button('60 s')?.click()
  await waitFor(
    () =>
      requestedRange === '60s' &&
      chart()?.getAttribute('aria-label')?.startsWith('Live traffic') &&
      summary()?.includes('160 B/s'),
    'Live view did not show the most recent 60-second rate sample',
  )
  button('1 year')?.click()
  await waitFor(
    () => requestedRange === '365d' && chart(),
    'Could not request one-year history in tray',
  )
  await waitFor(
    () => summary()?.includes('Peak connections 9'),
    'Latest sample details not visible',
  )
  const yearly = chart()
  check(yearly != null, 'Year chart missing')
  if (yearly == null) return
  const bounds = yearly.getBoundingClientRect()
  check(bounds.width > 0, 'Year chart has no painted width')
  yearly.dispatchEvent(
    new PointerEvent('pointermove', {
      bubbles: true,
      clientX: bounds.left + (bounds.width * 20) / 365,
      clientY: bounds.top + bounds.height / 2,
      pointerType: 'mouse',
    }),
  )
  await waitFor(
    () => summary()?.includes('Peak connections 3'),
    'Pointer hover did not change the detail in place',
  )
  yearly.dispatchEvent(
    new PointerEvent('pointermove', {
      bubbles: true,
      clientX: bounds.left + bounds.width / 2,
      clientY: bounds.top + bounds.height / 2,
      pointerType: 'mouse',
    }),
  )
  await waitFor(
    () => summary()?.includes('No samples'),
    'Missing samples appeared as traffic',
  )
  yearly.focus()
  yearly.dispatchEvent(
    new KeyboardEvent('keydown', { key: 'Home', bubbles: true }),
  )
  await waitFor(
    () => summary()?.includes('Peak connections 3'),
    'Keyboard sample selection did not update the details',
  )
  yearly.dispatchEvent(
    new KeyboardEvent('keydown', {
      key: 'Escape',
      bubbles: true,
      cancelable: true,
    }),
  )
  await waitFor(
    () => hidden,
    'Escape did not hide the tray with a selected chart sample',
  )
  check(!openedMain, 'Inspecting tray history opened the main window')
  root.render(<UsageWorkspace key="full" />)
  await waitFor(
    () => button('DigitalOcean settings')?.disabled === false,
    'DigitalOcean settings were unavailable',
  )
  button('DigitalOcean settings')?.click()
  await waitFor(
    () => document.querySelector('[role="dialog"]'),
    'Settings dialog did not appear',
  )
  const picker = [
    ...document.querySelectorAll<HTMLElement>('[role="combobox"]'),
  ].find((item) => item.textContent === 'macOS Keychain')
  picker?.dispatchEvent(
    new MouseEvent('mousedown', { bubbles: true, button: 0 }),
  )
  await waitFor(
    () => document.querySelector('[role="option"][data-value="localFile"]'),
    'Token storage list did not appear',
  )
  document
    .querySelector<HTMLElement>('[role="option"][data-value="localFile"]')
    ?.click()
  await waitFor(
    () => button('Save')?.disabled === false,
    'Storage change required re-entering the saved token',
  )
  document
    .querySelector('[role="dialog"] form')
    ?.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
  await waitFor(
    () => settingsStorage === 'localFile',
    'Saved credential storage was not switched',
  )
}

void run().then(
  () => {
    document.documentElement.dataset.result = 'passed'
  },
  (error: unknown) => {
    document.documentElement.dataset.result = 'failed'
    const details = document.createElement('pre')
    details.id = 'failure'
    details.textContent = String(error)
    document.body.append(details)
  },
)
