import { Box, Stack, Typography } from '@mui/material'
import { useTheme } from '@mui/material/styles'
import {
  useId,
  useState,
  type KeyboardEvent,
  type PointerEvent,
  type ReactNode,
} from 'react'
import { useTranslation } from 'react-i18next'

import { formatTime } from '@/utils/usage-format'

export type UsagePoint = {
  at: number
  first: number | null
  second: number | null
  detail?: ReactNode
}

type Props = {
  title: string
  firstLabel: string
  secondLabel: string
  points: UsagePoint[]
  from: number
  until: number
  bucketSeconds?: number
  formatValue: (value: number) => string
  compact?: boolean
}

const WIDTH = 720
const HEIGHT = 144
const X_TICKS = [0, 0.25, 0.5, 0.75, 1]

const closestIndex = (points: UsagePoint[], at: number) => {
  let left = 0
  let right = points.length - 1
  while (left < right) {
    const middle = Math.floor((left + right) / 2)
    if (points[middle].at < at) left = middle + 1
    else right = middle
  }
  const previous = left - 1
  return previous >= 0 && at - points[previous].at < points[left].at - at
    ? previous
    : left
}

const gapLimit = (points: UsagePoint[], bucketSeconds?: number) => {
  if (bucketSeconds) return bucketSeconds * 1.5
  const spacing = points
    .slice(1)
    .map(({ at }, i) => at - points[i].at)
    .sort((a, b) => a - b)
  return Math.max(
    90,
    Math.min(1800, (spacing[spacing.length >> 1] ?? 60) * 1.5),
  )
}

const seriesPath = (
  points: UsagePoint[],
  key: 'first' | 'second',
  x: (at: number) => number,
  y: (value: number) => number,
  limit: number,
) => {
  let previous: number | null = null
  let path = ''
  for (const point of points) {
    const value = point[key]
    if (value == null) {
      previous = null
      continue
    }
    const startsSegment = previous == null || point.at - previous > limit
    const location = `${x(point.at)} ${y(value)}`
    path += startsSegment ? `M${location}h.01` : `L${location}`
    previous = point.at
  }
  return path
}

export function UsageChart({
  title,
  firstLabel,
  secondLabel,
  points,
  from,
  until,
  bucketSeconds,
  formatValue,
  compact = false,
}: Props) {
  const { t } = useTranslation()
  const theme = useTheme()
  const inspectorId = useId()
  const [hover, setHover] = useState<number | null>(null)
  const [pin, setPin] = useState<number | null>(null)

  if (!points.length) {
    return (
      <Box
        sx={{
          minHeight: compact ? 72 : 150,
          display: 'grid',
          placeItems: 'center',
        }}
      >
        <Typography color="text.secondary" variant="body2">
          {t('usage.empty')}
        </Typography>
      </Box>
    )
  }

  const colors = [theme.palette.info.main, theme.palette.secondary.main]
  const limit = gapLimit(points, bucketSeconds)
  const start = Math.min(from, points[0].at)
  const end = Math.max(until, points[points.length - 1].at, start + 1)
  const span = end - start
  const peak = points.reduce(
    (max, point) => Math.max(max, point.first ?? 0, point.second ?? 0),
    1,
  )
  const x = (value: number) => ((value - start) / span) * WIDTH
  const y = (value: number) => HEIGHT - 4 - (value / peak) * (HEIGHT - 8)
  const index = closestIndex(points, hover ?? pin ?? end)
  const selected = points[index]
  const inGap = hover != null && Math.abs(selected.at - hover) > limit / 2

  const onPointerMove = (event: PointerEvent<SVGSVGElement>) => {
    const bounds = event.currentTarget.getBoundingClientRect()
    if (bounds.width <= 0) return
    const fraction = (event.clientX - bounds.left) / bounds.width
    setHover(start + span * Math.min(1, Math.max(0, fraction)))
  }

  const onKeyDown = (event: KeyboardEvent<SVGSVGElement>) => {
    const next = {
      ArrowLeft: Math.max(0, index - 1),
      ArrowRight: Math.min(points.length - 1, index + 1),
      Home: 0,
      End: points.length - 1,
    }[event.key]
    if (event.key === 'Escape' && pin != null) {
      event.preventDefault()
      setPin(null)
      return
    }
    if (next === undefined) return
    event.preventDefault()
    setHover(null)
    setPin(points[next].at)
  }

  return (
    <Stack spacing={compact ? 0.25 : 0.75}>
      <Stack
        direction="row"
        spacing={1.5}
        sx={{ alignItems: 'center', flexWrap: 'wrap' }}
      >
        {[firstLabel, secondLabel].map((label, i) => (
          <Stack
            key={label}
            direction="row"
            spacing={0.5}
            sx={{ alignItems: 'center' }}
          >
            <Box
              sx={{
                width: 7,
                height: 7,
                borderRadius: '50%',
                bgcolor: colors[i],
              }}
            />
            <Typography color="text.secondary" variant="caption">
              {label}
            </Typography>
          </Stack>
        ))}
        {!compact && (
          <Typography
            color="text.secondary"
            variant="caption"
            sx={{ ml: 'auto' }}
          >
            {formatValue(peak)}
          </Typography>
        )}
      </Stack>
      <Box
        sx={{
          height: compact ? 83 : 'clamp(134px, 24vh, 244px)',
          borderRadius: 1.5,
          overflow: 'hidden',
          backgroundColor: 'action.hover',
          '& svg:focus-visible': {
            outline: `2px solid ${theme.palette.primary.main} !important`,
            outlineOffset: -2,
          },
        }}
      >
        <svg
          aria-label={`${title}. ${t('usage.chartInstructions')}`}
          aria-describedby={inspectorId}
          role="group"
          tabIndex={0}
          viewBox={`0 0 ${WIDTH} ${HEIGHT}`}
          preserveAspectRatio="none"
          width="100%"
          height="100%"
          style={{ cursor: 'crosshair', display: 'block' }}
          onPointerMove={onPointerMove}
          onPointerLeave={() => setHover(null)}
          onClick={() => {
            if (!inGap) setPin(pin === selected.at ? null : selected.at)
          }}
          onKeyDown={onKeyDown}
        >
          {X_TICKS.map((tick) => (
            <line
              key={tick}
              x1={tick * WIDTH}
              x2={tick * WIDTH}
              y1={0}
              y2={HEIGHT}
              stroke={theme.palette.divider}
              vectorEffect="non-scaling-stroke"
            />
          ))}
          {[0.25, 0.5, 0.75].map((tick) => (
            <line
              key={tick}
              y1={tick * HEIGHT}
              y2={tick * HEIGHT}
              x1={0}
              x2={WIDTH}
              stroke={theme.palette.divider}
              vectorEffect="non-scaling-stroke"
            />
          ))}
          {(['first', 'second'] as const).map((key, i) => (
            <path
              key={key}
              d={seriesPath(points, key, x, y, limit)}
              fill="none"
              stroke={colors[i]}
              strokeWidth={1.7}
              strokeLinecap="round"
              strokeLinejoin="round"
              vectorEffect="non-scaling-stroke"
            />
          ))}
          {!inGap && (
            <line
              x1={x(selected.at)}
              x2={x(selected.at)}
              y1={0}
              y2={HEIGHT}
              stroke={theme.palette.text.secondary}
              strokeDasharray="3 3"
              vectorEffect="non-scaling-stroke"
            />
          )}
        </svg>
      </Box>
      {!compact && (
        <Stack direction="row" sx={{ justifyContent: 'space-between' }}>
          <Typography color="text.secondary" variant="caption">
            {formatTime(start)}
          </Typography>
          <Typography color="text.secondary" variant="caption">
            {formatTime(end)}
          </Typography>
        </Stack>
      )}
      <Stack
        id={inspectorId}
        aria-live={pin != null && hover == null ? 'polite' : 'off'}
        direction="row"
        spacing={1.25}
        useFlexGap
        sx={{
          alignItems: 'center',
          flexWrap: 'wrap',
          fontVariantNumeric: 'tabular-nums',
        }}
      >
        {inGap ? (
          <Typography color="text.secondary" variant="caption">
            {t('usage.empty')}
          </Typography>
        ) : (
          <>
            <Typography color="text.secondary" variant="caption">
              {formatTime(selected.at)}
            </Typography>
            {[selected.first, selected.second].map((value, i) => (
              <Typography
                key={i === 0 ? firstLabel : secondLabel}
                variant="caption"
                sx={{ color: colors[i] }}
              >
                {i === 0 ? firstLabel : secondLabel}{' '}
                {value == null ? '—' : formatValue(value)}
              </Typography>
            ))}
            {!compact && selected.detail}
          </>
        )}
      </Stack>
    </Stack>
  )
}
