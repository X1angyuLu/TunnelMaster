const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB']
const quantity = new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 })
const gibibytes = new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 })
const percentage = new Intl.NumberFormat(undefined, {
  style: 'percent',
  maximumFractionDigits: 1,
})
const dateTime = new Intl.DateTimeFormat(undefined, {
  month: 'short',
  day: 'numeric',
  hour: '2-digit',
  minute: '2-digit',
})
const utcTime = new Intl.DateTimeFormat(undefined, {
  timeZone: 'UTC',
  month: 'short',
  day: 'numeric',
  hour: '2-digit',
  minute: '2-digit',
})

export const formatBytes = (value?: number | null) => {
  if (value == null || !Number.isFinite(value)) return '—'
  const scale = Math.max(
    0,
    Math.min(Math.floor(Math.log2(Math.abs(value)) / 10), units.length - 1),
  )
  return `${quantity.format(value / 1024 ** scale)} ${units[scale]}`
}

export const formatRate = (bytes: number) => `${formatBytes(bytes)}/s`
export const formatMbps = (value: number) => `${quantity.format(value)} Mbps`
export const formatGiB = (value?: number | null) =>
  value == null ? '—' : `${gibibytes.format(value)} GiB`
export const formatPct = (value: number) => percentage.format(value)
export const formatTime = (value: number) => dateTime.format(value * 1000)
export const formatUTC = (value: number) => utcTime.format(value * 1000)

export const formatDuration = (seconds: number | null) => {
  if (seconds == null) return '—'
  if (seconds < 60) return `${Math.floor(seconds)} s`
  const minutes = Math.floor(seconds / 60)
  const hours = Math.floor(minutes / 60)
  return hours > 0 ? `${hours} h ${minutes % 60} min` : `${minutes} min`
}

export const usageError = (error: unknown, fallback: string) => {
  if (typeof error === 'string') return error
  if (error instanceof Error) return error.message
  if (typeof error === 'object' && error && 'detail' in error) {
    if (typeof error.detail === 'string') return error.detail
  }
  return fallback
}

export const usageHasErrorCode = (error: unknown, code: string) =>
  typeof error === 'object' &&
  error != null &&
  'code' in error &&
  error.code === code
