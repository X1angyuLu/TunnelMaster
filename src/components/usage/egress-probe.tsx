import PublicRounded from '@mui/icons-material/PublicRounded'
import { Button, Stack, Tooltip, Typography } from '@mui/material'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'

import type { EgressProbe as ProbeResult } from '@/services/bindings'
import { tunnelmasterUsage } from '@/services/cmds'

export function EgressProbe({ compact }: { compact: boolean }) {
  const { t } = useTranslation()
  const [report, setReport] = useState<ProbeResult | null>(null)
  const [busy, setBusy] = useState(false)
  const [failed, setFailed] = useState(false)

  const probe = async () => {
    setBusy(true)
    setFailed(false)
    setReport(null)
    try {
      setReport(await tunnelmasterUsage.probeEgress())
    } catch {
      setFailed(true)
    } finally {
      setBusy(false)
    }
  }

  const label = [report?.ip, report?.country].filter(Boolean).join(' · ')
  return (
    <Stack
      sx={{
        alignItems: compact ? 'flex-end' : 'flex-start',
        minWidth: 0,
      }}
    >
      <Tooltip title={t('usage.egressHint')}>
        <Button
          size="small"
          loading={busy}
          onClick={() => void probe()}
          startIcon={<PublicRounded />}
          aria-label={t('usage.egressCheck')}
          sx={{
            maxWidth: compact ? '148px' : '240px',
            minWidth: 0,
            textTransform: 'none',
          }}
        >
          <Typography variant="caption" noWrap>
            {label || t('usage.egressCheck')}
          </Typography>
        </Button>
      </Tooltip>
      {failed && (
        <Typography role="status" variant="caption" color="error">
          {t('usage.egressFailed')}
        </Typography>
      )}
    </Stack>
  )
}
