'use client'

import { useState, type CSSProperties } from 'react'
import { Reveal } from '@/components/ui/Reveal'
import { Print } from './Print'
import { Viewer } from './Viewer'
import { entries, sequence, type Entry } from './shots'
import styles from './Log.module.css'

const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
const placed = new Map(sequence.map((shot) => [shot.name, shot]))

/** The screenshots as a dated log: a note for each sitting, and its prints on the board beside it. */
export function Log() {
  const [open, setOpen] = useState<number | null>(null)

  return (
    <>
      <div className={styles.log}>
        {entries.map((entry) => (
          <section key={entry.id} id={entry.id} className={styles.entry} aria-labelledby={`${entry.id}-title`}>
            <Reveal className={styles.note}>
              <Leaf date={entry.date} />
              <h2 id={`${entry.id}-title`} className={`display ${styles.title}`}>
                {entry.title}
              </h2>
              <p className={styles.words}>{entry.note}</p>
              <p className="meta">{span(entry)}</p>
            </Reveal>

            <div className={styles.board}>
              {entry.bands.map((band, index) => (
                <div key={index} className={styles.band} style={{ '--columns': band.map(([share]) => `${share}fr`).join(' ') } as CSSProperties}>
                  {band.map(([, ...names], column) => (
                    <div key={names[0]} className={styles.column}>
                      {names.map((name, row) => (
                        <Print key={name} shot={placed.get(name)!} onOpen={setOpen} delay={column * 0.07 + row * 0.05} />
                      ))}
                    </div>
                  ))}
                </div>
              ))}
            </div>
          </section>
        ))}
      </div>
      <Viewer open={open} onChange={setOpen} />
    </>
  )
}

/** A leaf off a day-to-a-page calendar. */
function Leaf({ date }: { date: string }) {
  const [, month, day] = date.split('-').map(Number)
  return (
    <time dateTime={date} className={`print ${styles.leaf}`}>
      <span className={`cloth ${styles.month}`}>{months[month - 1]}</span>
      <span className={styles.day}>{String(day).padStart(2, '0')}</span>
    </time>
  )
}

function span(entry: Entry): string {
  const first = placed.get(entry.shots[0].name)!.number
  const last = first + entry.shots.length - 1
  return `${entry.shots.length} screenshots · Nos. ${first} to ${last}`
}
