import { Box } from '@mui/material'
import { useTranslation } from 'react-i18next'

import { BasePage } from '@/components/base'
import { UsageWorkspace } from '@/components/usage/usage-workspace'

export default function UsagePage() {
  const { t } = useTranslation()
  return (
    <BasePage title={t('usage.title')}>
      <Box sx={{ p: { xs: 1.5, sm: 2.5 }, mx: 'auto', maxWidth: 1060 }}>
        <UsageWorkspace />
      </Box>
    </BasePage>
  )
}
