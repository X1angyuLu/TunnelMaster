import {
  Alert,
  GlobalStyles,
  Paper,
  Stack,
  ThemeProvider,
  createTheme,
} from '@mui/material'
import { LogicalSize } from '@tauri-apps/api/dpi'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'

import { TrayConnection } from '@/components/usage/tray-connection'
import { UsageWorkspace } from '@/components/usage/usage-workspace'
import { useEventBus } from '@/services/bus'

import { useCustomTheme, useLoadingOverlay } from './_layout/hooks'

export default function UsageTrayPage() {
  const containerRef = useRef<HTMLElement>(null)
  const [error, setError] = useState<string>()
  useEventBus(
    useCallback(([status, message]: [string, string]) => {
      if (status === 'error') setError(message)
    }, []),
  )
  useEffect(() => {
    const panel = containerRef.current
    const content = panel?.querySelector('[data-usage-panel-content]')
    if (!panel || !content) return
    let previous = 0
    const observer = new ResizeObserver(() => {
      const style = getComputedStyle(panel)
      const padding =
        parseFloat(style.paddingTop) + parseFloat(style.paddingBottom) + 2
      const height = Math.min(
        screen.availHeight - 48,
        Math.max(
          300,
          Math.ceil(content.getBoundingClientRect().height + padding),
        ),
      )
      if (height === previous) return
      previous = height
      void getCurrentWindow()
        .setSize(new LogicalSize(320, height))
        .catch(console.error)
    })
    observer.observe(content)
    return () => observer.disconnect()
  }, [])
  const { theme } = useCustomTheme()
  const panelTheme = useMemo(() => {
    const dark = theme.palette.mode === 'dark'
    return createTheme(theme, {
      typography: {
        fontFamily:
          '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif',
        fontSize: 13,
        caption: { fontSize: 11, lineHeight: 1.45 },
        subtitle2: { fontSize: 12, fontWeight: 600 },
        body2: { fontSize: 12 },
      },
      palette: {
        primary: { main: dark ? '#75c4d0' : '#33899b' },
        info: { main: dark ? '#75c4d0' : '#33899b' },
        secondary: { main: dark ? '#e5b08c' : '#bc7952' },
        text: {
          primary: dark ? '#f1f3f2' : '#292b2a',
          secondary: dark ? '#afb6b5' : '#777e7d',
        },
        divider: dark ? 'rgba(255,255,255,.10)' : 'rgba(0,0,0,.08)',
      },
      components: {
        MuiButton: {
          styleOverrides: {
            root: { textTransform: 'none', fontSize: 12, minWidth: 0 },
          },
        },
        MuiPaper: {
          styleOverrides: {
            outlined: { background: 'transparent', border: 0, borderRadius: 0 },
          },
        },
        MuiToggleButtonGroup: {
          styleOverrides: {
            root: {
              padding: 2,
              borderRadius: 7,
              background: dark ? '#ffffff12' : '#00000009',
            },
          },
        },
        MuiToggleButton: {
          styleOverrides: {
            root: {
              border: '0 !important',
              borderRadius: '5px !important',
              fontSize: 11,
              lineHeight: 1.5,
              color: theme.palette.text.secondary,
              '&.Mui-selected': {
                color: theme.palette.text.primary,
                background: dark ? '#ffffff20' : '#fff',
              },
            },
          },
        },
        MuiIconButton: {
          styleOverrides: {
            root: {
              padding: 4,
              borderRadius: 6,
              '& .MuiSvgIcon-root': { fontSize: 17 },
            },
          },
        },
        MuiOutlinedInput: {
          styleOverrides: {
            root: {
              fontSize: 12,
              borderRadius: 6,
              background: dark ? '#ffffff09' : '#00000004',
            },
            notchedOutline: { borderColor: theme.palette.divider },
          },
        },
      },
    })
  }, [theme])
  useLoadingOverlay(Boolean(theme))
  return (
    <ThemeProvider theme={panelTheme}>
      <GlobalStyles
        styles={{
          'html, body, #root': { background: 'transparent !important' },
          body: { overflow: 'hidden' },
        }}
      />
      <Paper
        ref={containerRef}
        component="main"
        elevation={0}
        data-usage-panel
        sx={{
          height: '100dvh',
          boxSizing: 'border-box',
          overflowY: 'auto',
          p: 2,
          borderRadius: '16px',
          bgcolor:
            theme.palette.mode === 'dark'
              ? 'rgba(24,26,30,.22) !important'
              : 'rgba(255,255,255,.28) !important',
          '& [data-usage-section]': {
            border: 0,
            borderRadius: 0,
            px: 0,
            py: 1.25,
            borderBottom: '1px solid',
            borderColor: 'divider',
          },
          '& [data-usage-section]:last-child': { borderBottom: 0, pb: 0 },
        }}
      >
        <Stack spacing={1.5} data-usage-panel-content>
          <TrayConnection onError={setError}>
            {error && (
              <Alert severity="warning" sx={{ py: 0 }}>
                {error}
              </Alert>
            )}
            <UsageWorkspace compact />
          </TrayConnection>
        </Stack>
      </Paper>
    </ThemeProvider>
  )
}
