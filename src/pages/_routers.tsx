import { createBrowserRouter, RouteObject } from 'react-router'

import Layout from './_layout'
import { navItems } from './_navigation'
import UsageTrayPage from './usage-tray'

export const router = createBrowserRouter([
  { path: '/usage-tray', Component: UsageTrayPage },
  {
    path: '/',
    Component: Layout,
    children: navItems.map(
      (item) =>
        ({
          path: item.path,
          Component: item.Component,
        }) as RouteObject,
    ),
  },
])
