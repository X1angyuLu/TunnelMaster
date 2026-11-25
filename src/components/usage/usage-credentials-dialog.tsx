import {
  Alert,
  Button,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  LinearProgress,
  MenuItem,
  Stack,
  TextField,
} from '@mui/material'
import { useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'

import {
  tunnelmasterUsage,
  type UsageDoSettings,
  type UsageDroplet,
} from '@/services/cmds'
import { usageError, usageHasErrorCode } from '@/utils/usage-format'

type Props = {
  settings: UsageDoSettings | undefined
  onClose: () => void
  onChange: (write: () => Promise<UsageDoSettings>) => Promise<void>
}

export function UsageCredentialsDialog({ settings, onClose, onChange }: Props) {
  const { t } = useTranslation()
  const [dropletId, setDropletId] = useState(settings?.dropletId ?? '')
  const [token, setToken] = useState('')
  const [storage, setStorage] = useState(
    settings?.storage ??
      (settings?.keychainAvailable ? 'keychain' : 'localFile'),
  )
  const [droplets, setDroplets] = useState<UsageDroplet[]>()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string>()
  const [confirmRemove, setConfirmRemove] = useState(false)
  const parsedId = dropletId.trim()
  const canSaveToken = /^\d+$/.test(parsedId) && Boolean(token.trim())
  const canSwitch =
    !token.trim() &&
    storage === settings?.storage &&
    parsedId !== settings?.dropletId &&
    droplets?.some(({ id }) => id === parsedId)

  const loadDroplets = async () => {
    setBusy(true)
    setError(undefined)
    try {
      const available = await tunnelmasterUsage.listDroplets(
        token.trim() || undefined,
        settings?.dropletId ?? undefined,
      )
      setDroplets(available)
    } catch (failure) {
      setError(usageError(failure, t('usage.dropletsFailed')))
    } finally {
      setBusy(false)
    }
  }

  const runChange = async (write: () => Promise<UsageDoSettings>) => {
    setBusy(true)
    setError(undefined)
    try {
      await onChange(write)
      setToken('')
      onClose()
    } catch (failure) {
      setError(
        usageHasErrorCode(failure, 'digital_ocean_migration_keychain')
          ? t('usage.migrateKeychain')
          : usageError(failure, t('usage.saveFailed')),
      )
    } finally {
      setBusy(false)
    }
  }

  const save = (event: FormEvent) => {
    event.preventDefault()
    if (busy) return
    if (canSaveToken) {
      void runChange(() =>
        tunnelmasterUsage.saveCredentials(parsedId, token.trim(), storage),
      )
    } else if (canSwitch) {
      void runChange(() => tunnelmasterUsage.selectDroplet(parsedId))
    }
  }

  return (
    <Dialog
      open
      fullWidth
      maxWidth="xs"
      onClose={() => {
        if (!busy) onClose()
      }}
    >
      <form onSubmit={save}>
        <DialogTitle>{t('usage.settings')}</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ pt: 0.75 }}>
            {error && <Alert severity="error">{error}</Alert>}
            {busy && <LinearProgress />}
            {settings?.keychainAvailable && !settings.dropletId && (
              <Button
                type="button"
                disabled={busy}
                sx={{ alignSelf: 'flex-start' }}
                onClick={() =>
                  void runChange(tunnelmasterUsage.migrateCredentials)
                }
              >
                {t('usage.migrate')}
              </Button>
            )}
            <TextField
              size="small"
              label={t('usage.token')}
              type="password"
              autoComplete="off"
              value={token}
              disabled={busy}
              helperText={
                settings?.dropletId
                  ? t('usage.tokenReplace')
                  : t('usage.tokenHelp')
              }
              onChange={(event) => {
                setToken(event.target.value)
                setDroplets(undefined)
              }}
            />
            <Button
              type="button"
              onClick={() => void loadDroplets()}
              disabled={busy || (!token.trim() && !settings?.dropletId)}
              sx={{ alignSelf: 'flex-start' }}
            >
              {token.trim()
                ? t('usage.listWithToken')
                : t('usage.useExistingToken')}
            </Button>
            {droplets && droplets.length > 0 && (
              <TextField
                select
                size="small"
                label={t('usage.serverName')}
                value={
                  droplets.some(({ id }) => id === dropletId) ? dropletId : ''
                }
                disabled={busy}
                onChange={(event) => setDropletId(event.target.value)}
              >
                {droplets.map(({ id, name, region }) => (
                  <MenuItem key={id} value={id}>
                    {name} · {region} · #{id}
                  </MenuItem>
                ))}
              </TextField>
            )}
            {droplets?.length === 0 && (
              <Alert severity="info">{t('usage.noDroplets')}</Alert>
            )}
            <TextField
              size="small"
              label={t('usage.dropletId')}
              value={dropletId}
              disabled={busy}
              helperText={t('usage.dropletIdHelp')}
              slotProps={{ htmlInput: { inputMode: 'numeric' } }}
              onChange={(event) => setDropletId(event.target.value)}
            />
            <TextField
              select
              size="small"
              label={t('usage.storage')}
              value={storage}
              disabled={busy}
              helperText={
                storage === 'localFile' ? t('usage.fileNotice') : undefined
              }
              onChange={(event) =>
                setStorage(
                  event.target.value === 'keychain' ? 'keychain' : 'localFile',
                )
              }
            >
              {(settings?.keychainAvailable || storage === 'keychain') && (
                <MenuItem
                  value="keychain"
                  disabled={!settings?.keychainAvailable}
                >
                  {t('usage.keychain')}
                </MenuItem>
              )}
              <MenuItem value="localFile">{t('usage.localFile')}</MenuItem>
            </TextField>
            {settings?.dropletId && confirmRemove && (
              <Alert
                severity="warning"
                action={
                  <Button
                    color="error"
                    size="small"
                    disabled={busy}
                    onClick={() =>
                      void runChange(tunnelmasterUsage.clearCredentials)
                    }
                  >
                    {t('usage.disconnect')}
                  </Button>
                }
              >
                {t('usage.confirmRemove')}
              </Alert>
            )}
          </Stack>
        </DialogContent>
        <DialogActions sx={{ px: 3, pb: 2 }}>
          {settings?.dropletId && !confirmRemove && (
            <Button
              disabled={busy}
              color="error"
              onClick={() => setConfirmRemove(true)}
              sx={{ mr: 'auto' }}
            >
              {t('usage.disconnect')}
            </Button>
          )}
          <Button disabled={busy} onClick={onClose}>
            {t('usage.cancel')}
          </Button>
          <Button
            type="submit"
            variant="contained"
            disabled={(!canSaveToken && !canSwitch) || busy}
          >
            {t('usage.save')}
          </Button>
        </DialogActions>
      </form>
    </Dialog>
  )
}
