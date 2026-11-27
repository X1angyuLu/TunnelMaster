import RefreshOutlinedIcon from '@mui/icons-material/RefreshOutlined'
import {
  Alert,
  Box,
  IconButton,
  LinearProgress,
  Paper,
  Stack,
  Tooltip,
  Typography,
} from '@mui/material'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'

import { tunnelmasterUsage } from '@/services/cmds'
import { useQuery } from '@/services/query-client'
import {
  formatBytes,
  formatDuration,
  formatRate,
  formatTime,
  usageError,
} from '@/utils/usage-format'

import { UsageChart, type UsagePoint } from './usage-chart'
import { UsageMetric, UsageRangePicker } from './usage-controls'

const ranges = [
  ['60s', 'usage.range60s'],
  ['60m', 'usage.range60m'],
  ['24h', 'usage.range24h'],
  ['7d', 'usage.range7d'],
  ['14d', 'usage.range14d'],
  ['30d', 'usage.range30d'],
  ['90d', 'usage.range90d'],
  ['365d', 'usage.range365d'],
] as const

type LocalRange = (typeof ranges)[number][0]
const refreshIntervals: Record<LocalRange, number> = {
  '60s': 5000,
  '60m': 5000,
  '24h': 8000,
  '7d': 15_000,
  '14d': 30_000,
  '30d': 45_000,
  '90d': 60_000,
  '365d': 60_000,
}

export function LocalUsage({ compact = false }: { compact?: boolean }) {
  const { t } = useTranslation()
  const [range, setRange] = useState<LocalRange>(compact ? '60m' : '24h')
  const { data, error, isPending, isFetching, refetch } = useQuery({
    queryKey: ['usage', 'local', range],
    queryFn: () => tunnelmasterUsage.localHistory(range),
    refetchInterval: refreshIntervals[range],
    refetchOnWindowFocus: true,
    retry: false,
  })
  const live = range === '60s'
  const title = t(live ? 'usage.liveHistory' : 'usage.localHistory')
  const buckets = data?.buckets.filter(({ samples }) => samples > 0) ?? []
  const totals = buckets.reduce(
    (total, bucket) => ({
      download: total.download + bucket.download,
      upload: total.upload + bucket.upload,
    }),
    { download: 0, upload: 0 },
  )
  const historyPoints: UsagePoint[] = buckets.map((bucket) => ({
    at: bucket.start,
    first: bucket.download,
    second: bucket.upload,
    detail: (
      <>
        <Typography color="text.secondary" variant="caption">
          {t('usage.connected')} {formatDuration(bucket.connected_seconds)}
        </Typography>
        <Typography color="text.secondary" variant="caption">
          {t('usage.peakDown')} {formatRate(bucket.peak_download_rate)}
        </Typography>
        <Typography color="text.secondary" variant="caption">
          {t('usage.peakUp')} {formatRate(bucket.peak_upload_rate)}
        </Typography>
        {bucket.peak_connections != null && (
          <Typography color="text.secondary" variant="caption">
            {t('usage.peakConnections')} {bucket.peak_connections}
          </Typography>
        )}
        {bucket.sessions_started > 0 && (
          <Typography color="text.secondary" variant="caption">
            {t('usage.sessions')} {bucket.sessions_started}
          </Typography>
        )}
      </>
    ),
  }))

  const livePoints: UsagePoint[] = (data?.live_rates ?? []).map((rate) => ({
    at: rate.at,
    first: rate.download,
    second: rate.upload,
  }))
  const previous = data?.previous
  return (
    <Stack spacing={compact ? 1 : 2}>
      <Stack
        direction="row"
        spacing={0.5}
        sx={{ alignItems: 'center', justifyContent: 'space-between' }}
      >
        <UsageRangePicker<LocalRange>
          options={ranges}
          value={range}
          setValue={setRange}
        />
        <Tooltip title={t('usage.refresh')}>
          <span>
            <IconButton
              aria-label={t('usage.refresh')}
              size="small"
              disabled={isFetching}
              onClick={() => void refetch()}
            >
              <RefreshOutlinedIcon fontSize="small" />
            </IconButton>
          </span>
        </Tooltip>
      </Stack>
      {error != null && (
        <Alert severity="warning">
          {usageError(error, t('usage.unavailable'))}
        </Alert>
      )}
      {isPending && !data && <LinearProgress aria-label={t('usage.loading')} />}
      <Paper
        variant="outlined"
        data-usage-section={compact || undefined}
        sx={{
          p: compact ? 1 : 2,
          borderRadius: compact ? 2 : 3,
          display: 'grid',
          gridTemplateColumns: compact
            ? 'repeat(2, minmax(0, 1fr))'
            : 'repeat(auto-fit, minmax(min(100%, 118px), 1fr))',
          gap: compact ? 0.85 : 1.5,
        }}
      >
        <UsageMetric
          label={t('usage.downloadNow')}
          value={data?.sampling ? formatRate(data.current_download) : '—'}
          compact={compact}
        />
        <UsageMetric
          label={t('usage.uploadNow')}
          value={data?.sampling ? formatRate(data.current_upload) : '—'}
          compact={compact}
        />
        {!live && (
          <>
            <UsageMetric
              label={t('usage.downloadTotal')}
              value={formatBytes(buckets.length ? totals.download : null)}
              compact={compact}
            />
            <UsageMetric
              label={t('usage.uploadTotal')}
              value={formatBytes(buckets.length ? totals.upload : null)}
              compact={compact}
            />
          </>
        )}
        {previous && (
          <Typography
            variant="caption"
            color="text.secondary"
            sx={{ gridColumn: '1 / -1' }}
          >
            {t('usage.previousPeriod', {
              down: formatBytes(previous.download),
              up: formatBytes(previous.upload),
            })}
          </Typography>
        )}
      </Paper>
      <Paper
        variant="outlined"
        data-usage-section={compact || undefined}
        sx={{ p: compact ? 1 : 2, borderRadius: compact ? 2 : 3 }}
      >
        <Stack spacing={compact ? 0.5 : 1.25}>
          <Stack
            direction="row"
            spacing={1}
            sx={{ alignItems: 'baseline', flexWrap: 'wrap' }}
          >
            <Typography
              variant={compact ? 'subtitle2' : 'subtitle1'}
              component="h2"
              sx={{ fontWeight: 650 }}
            >
              {title}
            </Typography>
            {!compact && (
              <Typography variant="caption" color="text.secondary">
                {t(live ? 'usage.sampledRates' : 'usage.bucketVolume')}
              </Typography>
            )}
          </Stack>
          {(!isPending || data) && (
            <UsageChart
              key={range}
              title={title}
              firstLabel={t('usage.download')}
              secondLabel={t('usage.upload')}
              points={live ? livePoints : historyPoints}
              from={data?.from ?? 0}
              until={data?.until ?? 0}
              bucketSeconds={data?.bucket_seconds}
              formatValue={live ? formatRate : formatBytes}
              compact={compact}
            />
          )}
          {!compact && (
            <Box>
              <Typography
                variant="caption"
                color="text.secondary"
                sx={{ display: 'block' }}
              >
                {t(live ? 'usage.liveScope' : 'usage.localScope')}
              </Typography>
              <Typography variant="caption" color="text.secondary">
                {data?.sampled_at != null
                  ? t('usage.lastSample', { time: formatTime(data.sampled_at) })
                  : t('usage.samplingPaused')}
              </Typography>
            </Box>
          )}
        </Stack>
      </Paper>
    </Stack>
  )
}
