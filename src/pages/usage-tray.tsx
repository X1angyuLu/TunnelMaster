import { Paper, ThemeProvider } from '@mui/material'

import { UsageWorkspace } from '@/components/usage/usage-workspace'
import { useVisibility } from '@/hooks/use-visibility'

import { useCustomTheme } from './_layout/hooks'

export default function UsageTrayPage() {
  const { theme } = useCustomTheme()
  const visible = useVisibility()
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
        {visible && <UsageWorkspace compact />}
      </Paper>
    </ThemeProvider>
  )
}
