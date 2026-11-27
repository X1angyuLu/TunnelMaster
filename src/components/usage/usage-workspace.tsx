import CloseOutlinedIcon from '@mui/icons-material/CloseOutlined'
import OpenInNewOutlinedIcon from '@mui/icons-material/OpenInNewOutlined'
import SettingsOutlinedIcon from '@mui/icons-material/SettingsOutlined'
import {
  Alert,
  Button,
  IconButton,
  LinearProgress,
  Paper,
  Stack,
  ToggleButton,
  ToggleButtonGroup,
  Tooltip,
  Typography,
} from '@mui/material'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { useCallback, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'

import { tunnelmasterUsage, type UsageDoSettings } from '@/services/cmds'
import { mutate } from '@/services/mutate'
import {
  revalidateQuery,
  setCacheData,
  useQuery,
} from '@/services/query-client'
import { usageError } from '@/utils/usage-format'

import { EgressProbe } from './egress-probe'
import { LocalUsage } from './local-usage'
import { ServerUsage } from './server-usage'
import { UsageCredentialsDialog } from './usage-credentials-dialog'

type View = 'local' | 'server'
const settingsKey = ['usage', 'do-settings'] as const
const refreshSettings = () => void revalidateQuery(settingsKey)

export function UsageWorkspace({ compact = false }: { compact?: boolean }) {
  const { t } = useTranslation()
  const [selection, setSelection] = useState<View>()
  const [configuring, setConfiguring] = useState(false)
  const [revision, setRevision] = useState(0)
  const [openError, setOpenError] = useState<string>()
  const settings = useQuery({
    queryKey: settingsKey,
    queryFn: tunnelmasterUsage.settings,
    refetchOnWindowFocus: true,
    retry: false,
  })
  const dropletId = settings.data?.dropletId
  const view = selection ?? (compact && dropletId ? 'server' : 'local')

  const updateCredentials = async (write: () => Promise<UsageDoSettings>) => {
    const result = await mutate(write, {
      id: 'tunnelmaster-do-credentials',
      errorNotice: false,
    })
    if (result.ok) {
      await setCacheData(settingsKey, result.value)
      setRevision((value) => value + 1)
      setSelection('server')
    }
  }

  const openDashboard = async () => {
    setOpenError(undefined)
    try {
      await tunnelmasterUsage.open()
    } catch (failure) {
      setOpenError(usageError(failure, t('usage.unavailable')))
    }
  }

  const closeTray = useCallback(async () => {
    try {
      await getCurrentWindow().hide()
    } catch (failure) {
      setOpenError(usageError(failure, t('usage.unavailable')))
    }
  }, [t])

  useEffect(() => {
    if (!compact) return
    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === 'Escape' && !event.defaultPrevented) {
        event.preventDefault()
        void closeTray()
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [closeTray, compact])

  return (
    <Stack spacing={compact ? 1 : 2} data-usage-workspace>
      <Stack
        direction="row"
        spacing={1}
        sx={{ alignItems: 'center', justifyContent: 'space-between' }}
      >
        <ToggleButtonGroup
          size="small"
          exclusive
          aria-label={t('usage.title')}
          value={view}
          onChange={(_event, selection: View | null) => {
            if (selection) setSelection(selection)
          }}
          sx={{
            '& .MuiToggleButton-root': {
              px: compact ? 0.9 : 1.5,
              py: 0.45,
              textTransform: 'none',
            },
          }}
        >
          <ToggleButton value="local">{t('usage.local')}</ToggleButton>
          <ToggleButton value="server">{t('usage.server')}</ToggleButton>
        </ToggleButtonGroup>
        {view === 'local' && !compact && <EgressProbe compact={false} />}
        {compact ? (
          <Stack direction="row" spacing={0.5}>
            <Tooltip title={t('usage.open')}>
              <IconButton
                aria-label={t('usage.open')}
                size="small"
                onClick={() => void openDashboard()}
              >
                <OpenInNewOutlinedIcon fontSize="small" />
              </IconButton>
            </Tooltip>
            <Tooltip title={t('usage.done')}>
              <IconButton
                aria-label={t('usage.done')}
                size="small"
                onClick={() => void closeTray()}
              >
                <CloseOutlinedIcon fontSize="small" />
              </IconButton>
            </Tooltip>
          </Stack>
        ) : (
          <Button
            onClick={() => setConfiguring(true)}
            disabled={settings.isPending}
            startIcon={<SettingsOutlinedIcon fontSize="small" />}
          >
            {t('usage.settings')}
          </Button>
        )}
      </Stack>
      {openError && <Alert severity="error">{openError}</Alert>}
      {view === 'local' ? (
        <LocalUsage compact={compact} />
      ) : settings.error != null && !settings.data ? (
        <Alert
          severity="warning"
          action={
            <Button size="small" onClick={() => void settings.refetch()}>
              {t('usage.refresh')}
            </Button>
          }
        >
          {usageError(settings.error, t('usage.serverSettingsError'))}
        </Alert>
      ) : settings.isPending ? (
        <LinearProgress aria-label={t('usage.loading')} />
      ) : dropletId ? (
        <ServerUsage
          key={`${dropletId}:${revision}`}
          dropletId={dropletId}
          revision={revision}
          compact={compact}
          refreshSettings={refreshSettings}
          selectDroplet={(id) =>
            updateCredentials(() => tunnelmasterUsage.selectDroplet(id))
          }
        />
      ) : (
        <Paper
          variant="outlined"
          sx={{ p: compact ? 1.5 : 2.5, borderRadius: 3 }}
        >
          <Stack spacing={1.25} sx={{ alignItems: 'flex-start' }}>
            <Typography color="text.secondary" variant="body2">
              {t('usage.setup')}
            </Typography>
            <Button
              size="small"
              variant="contained"
              onClick={() => {
                if (compact) void openDashboard()
                else setConfiguring(true)
              }}
            >
              {compact ? t('usage.open') : t('usage.configure')}
            </Button>
          </Stack>
        </Paper>
      )}
      {configuring && (
        <UsageCredentialsDialog
          settings={settings.data}
          onClose={() => setConfiguring(false)}
          onChange={updateCredentials}
        />
      )}
    </Stack>
  )
}
