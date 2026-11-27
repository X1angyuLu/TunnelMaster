import { GlobalStyles, Paper, ThemeProvider, createTheme } from '@mui/material'
import { LogicalSize } from '@tauri-apps/api/dpi'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { useEffect, useMemo, useRef } from 'react'

import { UsageWorkspace } from '@/components/usage/usage-workspace'

import { useCustomTheme, useLoadingOverlay } from './_layout/hooks'

export default function UsageTrayPage() {
  const containerRef = useRef<HTMLElement>(null)
  useEffect(() => {
    const panel = containerRef.current
    const content = panel?.querySelector('[data-usage-workspace]')
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
        .setSize(new LogicalSize(364, height))
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
        info: { main: dark ? '#75c4d0' : '#33899b' },
        secondary: { main: dark ? '#e5b08c' : '#bc7952' },
        divider: dark ? 'rgba(255,255,255,.10)' : 'rgba(0,0,0,.08)',
      },
      components: {
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
          p: 1.75,
          borderRadius: '12px',
          border: '1px solid',
          borderColor: 'divider',
          bgcolor:
            theme.palette.mode === 'dark'
              ? 'rgba(29,30,34,.84)'
              : 'rgba(250,250,252,.87)',
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
        <UsageWorkspace compact />
      </Paper>
    </ThemeProvider>
  )
}
