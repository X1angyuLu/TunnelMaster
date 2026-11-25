import {
  Alert,
  Button,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  FormControlLabel,
  MenuItem,
  Stack,
  Switch,
  TextField,
} from '@mui/material'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'

import {
  getTunnelMasterRules,
  saveTunnelMasterRules,
  type TunnelMasterRules,
} from '@/services/cmds'
import { mutate } from '@/services/mutate'
import { errorDetail } from '@/services/notice-service'

const aiDomains = [
  'openai.com',
  'chatgpt.com',
  'oaistatic.com',
  'oaiusercontent.com',
  'oaistatsig.com',
  'anthropic.com',
  'claude.ai',
  'claude.com',
  'claudeusercontent.com',
]

interface Draft {
  direct: string
  proxy: string
  china: boolean
  unmatched: TunnelMasterRules['unmatched']
}

const tokens = (text: string): string[] =>
  text.split(/[\s,，]+/u).filter(Boolean)

export function TunnelMasterRulesDialog({
  index,
  onClose,
}: {
  index: string
  onClose: () => void
}) {
  const { t } = useTranslation()
  const [draft, setDraft] = useState<Draft>()
  const [failure, setFailure] = useState<string>()
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    let active = true
    void getTunnelMasterRules(index)
      .then((rules) => {
        if (!active) return
        if (!rules) {
          setFailure(t('profiles.tunnelmaster.unavailable'))
          return
        }
        setDraft({
          direct: rules.directDomains.join('\n'),
          proxy: rules.proxyDomains.join('\n'),
          china: rules.chinaIpDirect,
          unmatched: rules.unmatched,
        })
      })
      .catch((error: unknown) => {
        if (active) setFailure(errorDetail(error))
      })
    return () => {
      active = false
    }
  }, [index, t])

  const save = async () => {
    if (!draft || saving) return
    setSaving(true)
    setFailure(undefined)
    try {
      const result = await mutate(
        () =>
          saveTunnelMasterRules(index, {
            directDomains: tokens(draft.direct),
            proxyDomains: tokens(draft.proxy),
            chinaIpDirect: draft.china,
            unmatched: draft.unmatched,
          }),
        { id: `save-profile-file:${index}`, errorNotice: false },
      )
      if (result.ok && result.value.status === 'valid') {
        onClose()
      } else {
        setFailure(t('profiles.tunnelmaster.notApplied'))
      }
    } catch (error) {
      setFailure(errorDetail(error))
    } finally {
      setSaving(false)
    }
  }

  return (
    <Dialog open fullWidth maxWidth="sm" onClose={saving ? undefined : onClose}>
      <DialogTitle>{t('profiles.tunnelmaster.rules')}</DialogTitle>
      <DialogContent dividers>
        <Stack spacing={2}>
          {failure && <Alert severity="error">{failure}</Alert>}
          {!draft && !failure && <CircularProgress size={24} />}
          {draft && (
            <>
              <TextField
                select
                label={t('profiles.tunnelmaster.unmatched')}
                value={draft.unmatched}
                disabled={saving}
                onChange={(event) =>
                  setDraft({
                    ...draft,
                    unmatched:
                      event.target.value === 'wireguard'
                        ? 'wireguard'
                        : 'direct',
                  })
                }
              >
                <MenuItem value="direct">
                  {t('profiles.tunnelmaster.direct')}
                </MenuItem>
                <MenuItem value="wireguard">WireGuard</MenuItem>
              </TextField>
              <FormControlLabel
                label={t('profiles.tunnelmaster.chinaDirect')}
                control={
                  <Switch
                    disabled={saving}
                    checked={draft.china}
                    onChange={(_, china) => setDraft({ ...draft, china })}
                  />
                }
              />
              <TextField
                multiline
                minRows={3}
                maxRows={7}
                disabled={saving}
                label={t('profiles.tunnelmaster.directDomains')}
                value={draft.direct}
                helperText={t('profiles.tunnelmaster.domainHint')}
                onChange={(event) =>
                  setDraft({ ...draft, direct: event.target.value })
                }
              />
              <TextField
                multiline
                minRows={3}
                maxRows={7}
                disabled={saving}
                label={t('profiles.tunnelmaster.proxyDomains')}
                value={draft.proxy}
                onChange={(event) =>
                  setDraft({ ...draft, proxy: event.target.value })
                }
              />
              <Button
                size="small"
                sx={{ alignSelf: 'flex-start' }}
                disabled={saving}
                onClick={() =>
                  setDraft({
                    ...draft,
                    proxy: [
                      ...new Set([...tokens(draft.proxy), ...aiDomains]),
                    ].join('\n'),
                  })
                }
              >
                {t('profiles.tunnelmaster.addAiDomains')}
              </Button>
            </>
          )}
        </Stack>
      </DialogContent>
      <DialogActions>
        <Button disabled={saving} onClick={onClose}>
          {t('shared.actions.cancel')}
        </Button>
        <Button
          variant="contained"
          loading={saving}
          disabled={!draft}
          onClick={() => void save()}
        >
          {t('shared.actions.save')}
        </Button>
      </DialogActions>
    </Dialog>
  )
}
