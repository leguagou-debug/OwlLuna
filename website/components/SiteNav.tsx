'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useEffect, useRef, useState } from 'react'
import { asset, iconSet, site } from '@/lib/site'
import { Away, Button } from './ui/Button'
import styles from './SiteNav.module.css'

const links = [
  { href: '/#features', label: 'Features' },
  { href: '/#story', label: 'Story' },
  { href: '/prototypes/', label: 'Prototypes' },
  { href: '/privacy/', label: 'Privacy' },
  { href: '/support/', label: 'Support' },
]

export function SiteNav() {
  const pathname = usePathname()
  const [open, setOpen] = useState(false)
  const menu = useRef<HTMLDivElement>(null)
  const button = useRef<HTMLButtonElement>(null)

  useEffect(() => setOpen(false), [pathname])

  useEffect(() => {
    if (!open) return
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return
      setOpen(false)
      button.current?.focus()
    }
    const onPointer = (event: PointerEvent) => {
      if (menu.current && !menu.current.contains(event.target as Node)) setOpen(false)
    }
    window.addEventListener('keydown', onKey)
    window.addEventListener('pointerdown', onPointer)
    return () => {
      window.removeEventListener('keydown', onKey)
      window.removeEventListener('pointerdown', onPointer)
    }
  }, [open])

  const current = (href: string) => !href.includes('#') && pathname.replace(/\/$/, '') === href.replace(/\/$/, '')

  return (
    <header className={styles.bar}>
      <div className={`wrap ${styles.inner}`}>
        <Link href="/" className={styles.brand} aria-label="OwlLuna, home">
          <img src={asset('/owlluna-icon-32.webp')} srcSet={iconSet} sizes="32px" alt="" width={32} height={32} className={styles.icon} />
          <span className={styles.name}>OwlLuna</span>
        </Link>

        <nav className={styles.links} aria-label="Site">
          <ul className={styles.group}>
            {links.map((link) => (
              <li key={link.href}>
                <Link href={link.href} className={styles.link} aria-current={current(link.href) ? 'page' : undefined}>
                  {link.label}
                </Link>
              </li>
            ))}
          </ul>
        </nav>

        <div className={styles.actions}>
          <Button href={site.appStoreUrl || site.repo} variant="cloth" size="compact">
            {site.appStoreUrl ? 'Get the app' : 'GitHub'}
            <Away />
          </Button>
          <noscript>
            <style>{`.${styles.menu}{display:none!important}`}</style>
          </noscript>
          <div
            className={styles.menu}
            ref={menu}
            onBlur={(event) => {
              if (!event.currentTarget.contains(event.relatedTarget)) setOpen(false)
            }}
          >
            <button
              ref={button}
              type="button"
              className={styles.menuButton}
              aria-expanded={open}
              aria-controls="site-menu"
              onClick={() => setOpen((value) => !value)}
            >
              Menu
            </button>
            <div id="site-menu" className={styles.card} hidden={!open}>
              <div className={`cloth ${styles.cardBand}`}>Menu</div>
              <nav aria-label="Site">
                <ul>
                  {links.map((link) => (
                    <li key={link.href}>
                      <Link
                        href={link.href}
                        className={styles.cardRow}
                        aria-current={current(link.href) ? 'page' : undefined}
                        onClick={() => setOpen(false)}
                      >
                        {link.label}
                      </Link>
                    </li>
                  ))}
                </ul>
              </nav>
            </div>
          </div>
        </div>
      </div>
    </header>
  )
}
