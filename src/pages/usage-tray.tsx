import { Paper, ThemeProvider } from '@mui/material'

import { UsageWorkspace } from '@/components/usage/usage-workspace'

import { useCustomTheme, useLoadingOverlay } from './_layout/hooks'

export default function UsageTrayPage() {
  const { theme } = useCustomTheme()
  useLoadingOverlay(Boolean(theme))
  return (
    <ThemeProvider theme={theme}>
      <Paper
        component="main"
        square
        elevation={0}
        sx={{
          height: '100dvh',
          boxSizing: 'border-box',
          overflowY: 'auto',
          p: 1.25,
        }}
      >
        <UsageWorkspace compact />
      </Paper>
    </ThemeProvider>
  )
}
