import AltRouteRounded from '@mui/icons-material/AltRouteRounded'
import HubOutlined from '@mui/icons-material/HubOutlined'
import PublicRounded from '@mui/icons-material/PublicRounded'
import SettingsOutlined from '@mui/icons-material/SettingsOutlined'
import {
  Box,
  Button,
  FormControlLabel,
  MenuItem,
  Stack,
  Switch,
  TextField,
  ToggleButton,
  ToggleButtonGroup,
  Tooltip,
  Typography,
} from '@mui/material'
import { useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'

import { useClashMode } from '@/hooks/use-clash'
import { useProfiles } from '@/hooks/use-profiles'
import { useSystemProxyState } from '@/hooks/use-system-proxy-state'
import { useSystemState } from '@/hooks/use-system-state'
import { useVerge } from '@/hooks/use-verge'
import { patchClashMode, tunnelmasterUsage } from '@/services/cmds'
import { mutate } from '@/services/mutate'
import { revalidateQueries, useQuery } from '@/services/query-client'
import { formatRate, usageError } from '@/utils/usage-format'

import { EgressProbe } from './egress-probe'

export function TrayConnection({
  onError,
  children,
}: {
  onError: (message: string | undefined) => void
  children: ReactNode
}) {
  const { t } = useTranslation()
  const { verge, patchVerge } = useVerge()
  const { profiles, current, patchProfiles } = useProfiles()
  const { indicator, toggleSystemProxy } = useSystemProxyState()
  const { runState, isTunModeAvailable, isLoading } = useSystemState()
  const { data: mode } = useClashMode()
  const [busy, setBusy] = useState(false)
  const live = useQuery({
    queryKey: ['usage', 'local', '60s'],
    queryFn: () => tunnelmasterUsage.localHistory('60s'),
    refetchInterval: 5000,
    refetchOnWindowFocus: true,
    retry: false,
  })
  const connected =
    !isLoading &&
    runState.mode !== 'NotRunning' &&
    (indicator || (isTunModeAvailable && verge?.enable_tun_mode))
  const tunEnabled = isTunModeAvailable && Boolean(verge?.enable_tun_mode)
  const choices =
    profiles?.items?.filter(
      (item) => item.uid && (item.type === 'local' || item.type === 'remote'),
    ) ?? []
  const perform = async (action: () => Promise<unknown>) => {
    if (busy) return
    setBusy(true)
    onError(undefined)
    try {
      await action()
    } catch (error) {
      onError(usageError(error, t('usage.actionFailed')))
    } finally {
      setBusy(false)
    }
  }
  const setMode = async (value: string) => {
    await mutate(() => patchClashMode(value), {
      id: 'patch-clash-mode',
      errorNotice: false,
    })
    await revalidateQueries([
      ['getClashMode'],
      ['getClashConfig'],
      ['getRuntimeConfig'],
    ])
  }
  const open = (page: '/settings' | '/rules' | '/connections' | '/profile') =>
    void perform(() => tunnelmasterUsage.open(page))

  return (
    <Stack spacing={1.5}>
      <Stack direction="row" spacing={1} sx={{ alignItems: 'center' }}>
        <PublicRounded
          sx={{
            fontSize: 20,
            color: connected ? 'info.main' : 'text.disabled',
          }}
        />
        <Box sx={{ flex: 1 }}>
          <Typography sx={{ fontSize: 13, fontWeight: 650 }}>
            TunnelMaster
          </Typography>
          <Typography variant="caption" color="text.secondary">
            {t(connected ? 'usage.connectedState' : 'usage.disconnectedState')}
          </Typography>
        </Box>
        <FormControlLabel
          sx={{ m: 0, gap: 0.5 }}
          label={
            <Typography variant="caption">{t('usage.systemProxy')}</Typography>
          }
          labelPlacement="start"
          control={
            <Switch
              size="small"
              checked={indicator}
              disabled={busy || isLoading || runState.opInFlight}
              onChange={(_, value) =>
                void perform(() => toggleSystemProxy(value))
              }
            />
          }
        />
      </Stack>
      {children}
      <Stack
        direction="row"
        sx={{
          gap: 2,
          pt: 1.5,
          borderTop: '1px solid',
          borderColor: 'divider',
          fontVariantNumeric: 'tabular-nums',
        }}
      >
        <Tooltip title={t('usage.downloadNow')}>
          <Typography variant="caption" color="text.secondary">
            ↓{' '}
            <Box component="span" sx={{ color: 'text.primary', fontWeight: 600 }}>
              {live.data?.sampling ? formatRate(live.data.current_download) : '—'}
            </Box>
          </Typography>
        </Tooltip>
        <Tooltip title={t('usage.uploadNow')}>
          <Typography variant="caption" color="text.secondary">
            ↑{' '}
            <Box component="span" sx={{ color: 'text.primary', fontWeight: 600 }}>
              {live.data?.sampling ? formatRate(live.data.current_upload) : '—'}
            </Box>
          </Typography>
        </Tooltip>
      </Stack>
      <TextField
        select
        size="small"
        variant="standard"
        value={current?.uid ?? ''}
        disabled={busy || !choices.length}
        onChange={(event) =>
          void perform(async () => {
            const result = await patchProfiles({ current: event.target.value })
            if (result.status !== 'valid')
              throw new Error(
                result.status === 'invalid'
                  ? result.message
                  : t('usage.actionBusy'),
              )
          })
        }
        slotProps={{
          select: { inputProps: { 'aria-label': t('usage.profile') } },
          input: { disableUnderline: true },
        }}
        sx={{ '& .MuiSelect-select': { py: 0.25, fontSize: 12 } }}
      >
        {choices.map((item) => (
          <MenuItem key={item.uid} value={item.uid ?? ''}>
            {item.name ?? item.uid}
          </MenuItem>
        ))}
      </TextField>
      <ToggleButtonGroup
        exclusive
        fullWidth
        size="small"
        aria-label={t('usage.proxyMode')}
        value={mode?.toLowerCase() ?? ''}
        disabled={
          busy ||
          isLoading ||
          runState.mode === 'NotRunning' ||
          runState.opInFlight
        }
        onChange={(_, value: string | null) => {
          if (value) void perform(() => setMode(value))
        }}
        sx={{ '& .MuiToggleButton-root': { py: 0.5, textTransform: 'none' } }}
      >
        <ToggleButton value="rule">{t('usage.ruleMode')}</ToggleButton>
        <ToggleButton value="global">{t('usage.globalMode')}</ToggleButton>
        <ToggleButton value="direct">{t('usage.directMode')}</ToggleButton>
      </ToggleButtonGroup>
      <Stack
        direction="row"
        sx={{ justifyContent: 'space-between', alignItems: 'center' }}
      >
        <EgressProbe compact={false} />
        {isTunModeAvailable ? (
          <FormControlLabel
            sx={{ m: 0 }}
            label={<Typography variant="caption">TUN</Typography>}
            labelPlacement="start"
            control={
              <Switch
                size="small"
                checked={tunEnabled}
                disabled={busy || runState.opInFlight}
                onChange={(_, value) =>
                  void perform(() => patchVerge({ enable_tun_mode: value }))
                }
              />
            }
          />
        ) : (
          <Tooltip title={t('usage.tunNeedsService')}>
            <Button
              size="small"
              disabled={busy}
              onClick={() => open('/settings')}
            >
              TUN · {t('usage.setupAction')}
            </Button>
          </Tooltip>
        )}
      </Stack>
      <Stack
        direction="row"
        sx={{
          justifyContent: 'space-between',
          '& .MuiButton-root': {
            minWidth: 0,
            px: 0.6,
            fontSize: 11,
            color: 'text.secondary',
            textTransform: 'none',
          },
          '& .MuiSvgIcon-root': { fontSize: 14 },
        }}
      >
        <Button size="small" disabled={busy} onClick={() => open('/profile')}>
          {t('usage.profilesAction')}
        </Button>
        <Button
          size="small"
          startIcon={<AltRouteRounded />}
          disabled={busy}
          onClick={() => open('/rules')}
        >
          {t('usage.rulesAction')}
        </Button>
        <Button
          size="small"
          startIcon={<HubOutlined />}
          disabled={busy}
          onClick={() => open('/connections')}
        >
          {t('usage.connectionsAction')}
        </Button>
        <Button
          size="small"
          startIcon={<SettingsOutlined />}
          disabled={busy}
          onClick={() => open('/settings')}
        >
          {t('usage.settingsAction')}
        </Button>
      </Stack>
    </Stack>
  )
}
