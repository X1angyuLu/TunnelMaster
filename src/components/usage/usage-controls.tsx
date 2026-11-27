import { Box, ToggleButton, ToggleButtonGroup, Typography } from '@mui/material'
import { useTranslation } from 'react-i18next'

import type { TranslationKey } from '@/types/generated/i18n-keys'

type RangeOption<T> = readonly [value: T, label: TranslationKey]

export function UsageRangePicker<T extends string | number>({
  options,
  value,
  setValue,
}: {
  options: readonly RangeOption<T>[]
  value: T
  setValue: (value: T) => void
}) {
  const { t } = useTranslation()
  return (
    <ToggleButtonGroup
      aria-label={t('usage.range')}
      size="small"
      exclusive
      value={value}
      onChange={(_event, selection: T | null) => {
        if (selection != null) setValue(selection)
      }}
      sx={{
        alignSelf: 'flex-start',
        maxWidth: '100%',
        overflowX: 'auto',
        '& .MuiToggleButton-root': {
          whiteSpace: 'nowrap',
          px: 1,
          py: 0.45,
          minWidth: 42,
          textTransform: 'none',
        },
      }}
    >
      {options.map(([option, label]) => (
        <ToggleButton value={option} key={option}>
          {t(label)}
        </ToggleButton>
      ))}
    </ToggleButtonGroup>
  )
}

export function UsageMetric({
  label,
  value,
  compact,
  emphasized,
}: {
  label: string
  value: string
  compact?: boolean
  emphasized?: boolean
}) {
  return (
    <Box sx={{ minWidth: 0 }}>
      <Typography
        component="span"
        variant="caption"
        color="text.secondary"
        sx={{ display: 'block', lineHeight: 1.3 }}
      >
        {label}
      </Typography>
      <Typography
        component="span"
        variant={compact ? 'subtitle2' : 'h6'}
        sx={{
          display: 'block',
          color: emphasized ? 'warning.main' : 'text.primary',
          fontVariantNumeric: 'tabular-nums',
          ...(compact && {
            fontSize: 21,
            fontWeight: 600,
            letterSpacing: '-.55px',
          }),
          lineHeight: 1.35,
          wordBreak: 'break-word',
        }}
      >
        {value}
      </Typography>
    </Box>
  )
}
