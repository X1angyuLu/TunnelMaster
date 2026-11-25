import RefreshOutlinedIcon from '@mui/icons-material/RefreshOutlined'
import {
  Alert,
  Box,
  Button,
  IconButton,
  LinearProgress,
  MenuItem,
  Paper,
  Stack,
  TextField,
  Tooltip,
  Typography,
} from '@mui/material'
import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'

import { tunnelmasterUsage, type UsageDoReport } from '@/services/cmds'
import { showNotice } from '@/services/notice-service'
import { useQuery } from '@/services/query-client'
import { openExternalUrl } from '@/utils/open-external-url'
import {
  formatBytes,
  formatGiB,
  formatMbps,
  formatPct,
  formatUTC,
  usageError,
  usageHasErrorCode,
} from '@/utils/usage-format'

import { UsageChart, type UsagePoint } from './usage-chart'
import { UsageMetric, UsageRangePicker } from './usage-controls'

const serverRanges = [
  [1, 'usage.range24h'],
  [7, 'usage.range7d'],
  [14, 'usage.range14d'],
] as const

type ServerDays = (typeof serverRanges)[number][0]
type ServerBucket = UsageDoReport['buckets'][number]

function bandwidthPoints(report: UsageDoReport) {
  const points = new Map<number, UsagePoint>()
  const series = [
    ['first', report.inbound.samples],
    ['second', report.outbound.samples],
  ] as const
  for (const [key, samples] of series) {
    for (const { timestamp, mbps } of samples) {
      if (timestamp == null || mbps == null) continue
      const point = points.get(timestamp) ?? {
        at: timestamp,
        first: null,
        second: null,
      }
      point[key] = mbps
      points.set(point.at, point)
    }
  }
  return [...points.values()].sort((a, b) => a.at - b.at)
}

type Props = {
  dropletId: string
  revision: number
  compact?: boolean
  refreshSettings: () => void
  selectDroplet: (id: string) => Promise<void>
}

export function ServerUsage({
  dropletId,
  revision,
  compact = false,
  refreshSettings,
  selectDroplet,
}: Props) {
  const { t } = useTranslation()
  const [days, setDays] = useState<ServerDays>(1)
  const [selecting, setSelecting] = useState(false)
  const [selectionError, setSelectionError] = useState<string>()
  const forceRefreshRef = useRef(false)
  const droplets = useQuery({
    queryKey: ['usage', 'do-droplets', dropletId, revision],
    queryFn: () => tunnelmasterUsage.listDroplets(undefined, dropletId),
    refetchOnWindowFocus: true,
    staleTime: 60_000,
    retry: false,
  })
  const transfer = useQuery({
    queryKey: ['usage', 'do-monthly', dropletId, revision],
    queryFn: () =>
      tunnelmasterUsage.monthly(dropletId, forceRefreshRef.current),
    refetchInterval: 5 * 60_000,
    refetchOnWindowFocus: true,
    retry: false,
  })
  const bandwidth = useQuery({
    queryKey: ['usage', 'do-report', dropletId, revision, days],
    queryFn: () =>
      tunnelmasterUsage.report(days, dropletId, forceRefreshRef.current),
    refetchInterval: 2 * 60_000,
    refetchOnWindowFocus: true,
    retry: false,
  })

  const settingsChanged = [
    droplets.error,
    transfer.error,
    bandwidth.error,
  ].some((error) => usageHasErrorCode(error, 'digital_ocean_settings_changed'))
  useEffect(() => {
    if (settingsChanged) refreshSettings()
  }, [settingsChanged, refreshSettings])

  const monthly = transfer.data
  const report = bandwidth.data
  const overAllowance = (monthly?.remainingGib ?? 0) < 0
  const remaining =
    monthly?.remainingGib == null ? null : Math.abs(monthly.remainingGib)
  const shareOfAllowance =
    monthly?.outboundGib != null &&
    monthly.remainingGib != null &&
    monthly.projectedAllowanceGib != null &&
    monthly.projectedAllowanceGib > 0
      ? Math.min(
          100,
          (100 * monthly.outboundGib) / monthly.projectedAllowanceGib,
        )
      : null
  const options = droplets.data ?? []
  const fallbackId = !options.some(({ id }) => id === dropletId)

  const onSelect = async (id: string) => {
    if (selecting || id === dropletId) return
    setSelecting(true)
    setSelectionError(undefined)
    try {
      await selectDroplet(id)
    } catch (failure) {
      setSelectionError(usageError(failure, t('usage.saveFailed')))
    } finally {
      setSelecting(false)
    }
  }

  const refresh = async () => {
    forceRefreshRef.current = true
    try {
      await Promise.allSettled([transfer.refetch(), bandwidth.refetch()])
    } finally {
      forceRefreshRef.current = false
    }
  }

  const chartTitle = compact
    ? t('usage.serverVolume')
    : t('usage.serverHistory')
  const bucketDetail = (bucket: ServerBucket) => {
    const duration = Math.max(1, bucket.until - bucket.start)
    const coverage = (seconds: number | null) =>
      seconds == null
        ? '—'
        : formatPct(Math.min(Math.max(0, seconds) / duration, 1))
    return (
      <>
        {!compact && (
          <Typography variant="caption" color="text.secondary">
            {formatUTC(bucket.start)} – {formatUTC(bucket.until)} UTC
          </Typography>
        )}
        <Typography variant="caption" color="text.secondary">
          {t('usage.inboundCoverage', {
            percent: coverage(bucket.inboundCoveredSeconds),
          })}
          {!compact && ` · ${formatBytes(bucket.inboundBytes)}`}
        </Typography>
        <Typography variant="caption" color="text.secondary">
          {t('usage.outboundCoverage', {
            percent: coverage(bucket.outboundCoveredSeconds),
          })}
          {!compact && ` · ${formatBytes(bucket.outboundBytes)}`}
        </Typography>
      </>
    )
  }
  let points: UsagePoint[] = []
  if (report && compact) {
    points = report.buckets
      .filter(
        (bucket) => bucket.inboundBytes != null || bucket.outboundBytes != null,
      )
      .map((bucket) => ({
        at: bucket.start,
        first: bucket.inboundBytes,
        second: bucket.outboundBytes,
        detail: bucketDetail(bucket),
      }))
  } else if (report) {
    const details = report.buckets.map((bucket) => ({
      start: bucket.start,
      until: bucket.until,
      detail: bucketDetail(bucket),
    }))
    points = bandwidthPoints(report).map((point) => ({
      ...point,
      detail: details.find(
        ({ start, until }) =>
          start <= point.at &&
          (point.at < until || (point.at === until && until === report.until)),
      )?.detail,
    }))
  }

  return (
    <Stack spacing={compact ? 1 : 2}>
      <Stack
        direction="row"
        spacing={compact ? 0.2 : 0.75}
        sx={{ alignItems: 'center' }}
      >
        <TextField
          select
          size="small"
          label={t('usage.serverName')}
          value={dropletId}
          disabled={selecting || options.length === 0}
          onChange={(event) => void onSelect(event.target.value)}
          sx={{
            flex: 1,
            minWidth: 0,
            maxWidth: compact ? undefined : 420,
            '& .MuiSelect-select': { textOverflow: 'ellipsis' },
          }}
        >
          {fallbackId && (
            <MenuItem value={dropletId}>Droplet #{dropletId}</MenuItem>
          )}
          {options.map(({ id, name, region }) => (
            <MenuItem value={id} key={id}>
              {name || `Droplet #${id}`} · {region} · #{id}
            </MenuItem>
          ))}
        </TextField>
        <Tooltip title={t('usage.refreshDroplets')}>
          <span>
            <IconButton
              aria-label={t('usage.refreshDroplets')}
              size="small"
              disabled={selecting || droplets.isFetching}
              onClick={() => void droplets.refetch()}
            >
              <RefreshOutlinedIcon fontSize="small" />
            </IconButton>
          </span>
        </Tooltip>
      </Stack>
      {selectionError && <Alert severity="error">{selectionError}</Alert>}
      {droplets.error != null && (
        <Alert severity="warning" sx={{ py: compact ? 0 : undefined }}>
          {t('usage.dropletsFailed')}
        </Alert>
      )}
      {(droplets.isPending || selecting) && (
        <LinearProgress aria-label={t('usage.loading')} />
      )}

      <Paper
        variant="outlined"
        sx={{ p: compact ? 1 : 2, borderRadius: compact ? 2 : 3 }}
      >
        <Stack spacing={compact ? 0.65 : 1.35}>
          <Typography
            variant={compact ? 'subtitle2' : 'subtitle1'}
            component="h2"
            sx={{ fontWeight: 650 }}
          >
            {t('usage.monthTitle')}
          </Typography>
          <Box
            sx={{
              display: 'grid',
              gridTemplateColumns: compact
                ? 'repeat(2, minmax(0, 1fr))'
                : 'repeat(auto-fit, minmax(min(100%, 142px), 1fr))',
              gap: compact ? 0.5 : 1.4,
            }}
          >
            <UsageMetric
              label={t('usage.monthUsed')}
              value={formatGiB(monthly?.outboundGib)}
              compact={compact}
            />
            <UsageMetric
              label={
                overAllowance ? t('usage.monthOver') : t('usage.monthRemaining')
              }
              value={formatGiB(remaining)}
              emphasized={overAllowance}
              compact={compact}
            />
            {!compact && (
              <>
                <UsageMetric
                  label={t('usage.accrued')}
                  value={formatGiB(monthly?.accruedGib)}
                />
                <UsageMetric
                  label={t('usage.projected')}
                  value={formatGiB(monthly?.projectedAllowanceGib)}
                />
              </>
            )}
          </Box>
          {transfer.isPending && !monthly && (
            <LinearProgress aria-label={t('usage.loading')} />
          )}
          {shareOfAllowance != null && (
            <LinearProgress
              aria-label={t('usage.monthUsed')}
              variant="determinate"
              value={Math.max(0, shareOfAllowance)}
              color={overAllowance ? 'warning' : 'primary'}
              sx={{ borderRadius: 3 }}
            />
          )}
          {transfer.error != null && (
            <Alert severity="warning" sx={{ py: compact ? 0 : undefined }}>
              {usageError(transfer.error, t('usage.monthUnavailable'))}
            </Alert>
          )}
          {monthly && (
            <Typography variant="caption" color="text.secondary">
              {compact
                ? 'UTC'
                : `${formatUTC(monthly.monthStart)} – ${formatUTC(monthly.asOf)} UTC`}
              {' · '}
              {monthly.coverage
                ? t('usage.coverage', { percent: formatPct(monthly.coverage) })
                : t('usage.noCoverage')}
            </Typography>
          )}
          {!compact && monthly && (
            <Typography variant="caption" color="text.secondary">
              {monthly.planGib == null
                ? t('usage.planUnavailable')
                : t('usage.nominal', { amount: formatGiB(monthly.planGib) })}
            </Typography>
          )}
          {monthly?.coverage != null &&
            monthly.coverage > 0 &&
            monthly.coverage < 0.95 &&
            !compact && (
              <Typography variant="caption" color="text.secondary">
                {t('usage.coverageWarning')}
              </Typography>
            )}
          {!compact && (
            <Stack
              direction="row"
              spacing={1}
              sx={{
                alignItems: 'center',
                justifyContent: 'space-between',
                flexWrap: 'wrap',
              }}
            >
              <Typography variant="caption" color="text.secondary">
                {t('usage.allowanceNote')}
              </Typography>
              <Button
                size="small"
                onClick={() =>
                  void openExternalUrl(
                    'https://cloud.digitalocean.com/account/billing',
                  ).catch(showNotice.error)
                }
              >
                {t('usage.billing')}
              </Button>
            </Stack>
          )}
        </Stack>
      </Paper>

      <Paper
        variant="outlined"
        sx={{ p: compact ? 1 : 2, borderRadius: compact ? 2 : 3 }}
      >
        <Stack spacing={compact ? 0.5 : 1.25}>
          <Stack
            direction="row"
            spacing={compact ? 0.4 : 1}
            useFlexGap
            sx={{
              justifyContent: 'space-between',
              alignItems: 'center',
              flexWrap: 'wrap',
            }}
          >
            <Typography
              variant={compact ? 'subtitle2' : 'subtitle1'}
              component="h2"
              sx={{ fontWeight: 650 }}
            >
              {chartTitle}
            </Typography>
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.25 }}>
              <UsageRangePicker<ServerDays>
                options={serverRanges}
                value={days}
                setValue={setDays}
              />
              <Tooltip title={t('usage.refresh')}>
                <span>
                  <IconButton
                    aria-label={t('usage.refresh')}
                    size="small"
                    disabled={transfer.isFetching || bandwidth.isFetching}
                    onClick={() => void refresh()}
                  >
                    <RefreshOutlinedIcon fontSize="small" />
                  </IconButton>
                </span>
              </Tooltip>
            </Box>
          </Stack>
          {bandwidth.error != null && (
            <Alert severity="warning" sx={{ py: compact ? 0 : undefined }}>
              {usageError(bandwidth.error, t('usage.unavailable'))}
            </Alert>
          )}
          {bandwidth.isPending && !report && (
            <LinearProgress aria-label={t('usage.loading')} />
          )}
          {compact && report && (
            <Typography variant="caption" color="text.secondary">
              {t(days === 1 ? 'usage.hourlyUTC' : 'usage.dailyUTC')}
            </Typography>
          )}
          {!compact && report && (
            <Box
              sx={{
                display: 'grid',
                gridTemplateColumns: 'repeat(2, minmax(0, 1fr))',
                gap: 1,
              }}
            >
              <UsageMetric
                label={t('usage.inboundEstimate')}
                value={formatBytes(report.inbound.estimatedBytes)}
              />
              <UsageMetric
                label={t('usage.outboundEstimate')}
                value={formatBytes(report.outbound.estimatedBytes)}
              />
            </Box>
          )}
          {(!bandwidth.isPending || report) && (
            <UsageChart
              key={days}
              title={chartTitle}
              firstLabel={t(
                compact ? 'usage.inboundEstimate' : 'usage.inbound',
              )}
              secondLabel={t(
                compact ? 'usage.outboundEstimate' : 'usage.outbound',
              )}
              points={points}
              from={report?.from ?? 0}
              until={report?.until ?? 0}
              bucketSeconds={compact ? report?.bucketSeconds : undefined}
              formatTimestamp={compact ? formatUTC : undefined}
              formatValue={compact ? formatBytes : formatMbps}
              compact={compact}
            />
          )}
          {!compact && (
            <Typography variant="caption" color="text.secondary">
              {t('usage.aboutServer')}
            </Typography>
          )}
        </Stack>
      </Paper>
    </Stack>
  )
}
