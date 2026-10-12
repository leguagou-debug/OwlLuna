import type { ReactNode } from 'react'
import styles from './Panel.module.css'

type Props = {
  /** Printed on the cloth band that names the card. */
  title: string
  children: ReactNode
  /** Small caps at the band's trailing end. */
  note?: string
  tone?: 'cobalt' | 'tomato'
  className?: string
}

/** The app's Card: a flat, ink-outlined panel under a cloth band that names it. */
export function Panel({ title, note, tone = 'cobalt', children, className }: Props) {
  return (
    <div className={[styles.panel, className].filter(Boolean).join(' ')}>
      <div className={[styles.band, 'cloth', tone === 'tomato' ? styles.tomato : ''].filter(Boolean).join(' ')}>
        <span className={styles.title}>{title}</span>
        {note ? <span className={styles.note}>{note}</span> : null}
      </div>
      <div className={styles.body}>{children}</div>
    </div>
  )
}

/** A row of a Card, ruled like an index card. */
export function PanelRow({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={[styles.row, className].filter(Boolean).join(' ')}>{children}</div>
}
