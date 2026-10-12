import type { MetadataRoute } from 'next'
import { site } from '@/lib/site'

export const dynamic = 'force-static'

export default function sitemap(): MetadataRoute.Sitemap {
  const lastModified = new Date(`${site.policyUpdated}T00:00:00Z`)
  return ['/', '/privacy/', '/support/'].map((path) => ({ url: `${site.url}${path}`, lastModified }))
}
