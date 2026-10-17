'use client'

import archivo from '@fontsource-variable/archivo/files/archivo-latin-wdth-normal.woff2' with { turbopackModuleType: 'asset' }
import fraunces from '@fontsource-variable/fraunces/files/fraunces-latin-full-normal.woff2' with { turbopackModuleType: 'asset' }

const files = { fraunces, archivo }

/** Fetches a file of `app/fonts.css` with the page. A client component, so prefetching a page does not fetch its fonts. */
export function FontPreload({ font }: { font: keyof typeof files }) {
  return <link rel="preload" href={files[font]} as="font" type="font/woff2" crossOrigin="anonymous" />
}
