'use client'

import { useRef, type CSSProperties } from 'react'
import { Drawn } from '@/components/sections/study/Ink'
import { write } from '@/components/ui/hand'
import { Reveal } from '@/components/ui/Reveal'
import { Tape } from '@/components/ui/Tape'
import { useArrival } from '@/components/ui/useArrival'
import { source, sourceSet, type Placed, type Verdict } from './shots'
import styles from './Print.module.css'

const turns = [-1.1, 0.7, -0.5, 1.2, 0.4, -0.9, 1, -0.3]
const tapes = ['mustard', 'sage', 'rose', 'sky'] as const
const words = { kept: write('Kept'), dropped: write('Dropped', 3) }
const said = { kept: 'Kept', dropped: 'Dropped' }

type Props = {
  shot: Placed
  /** Its column's part of the board's width, from 720 px. */
  share: number
  onOpen: (number: number) => void
  /** Seconds after it comes into view. */
  delay?: number
}

/** A screenshot as a print taped to the board, with its number and caption under it. */
export function Print({ shot, share, onOpen, delay = 0 }: Props) {
  const shape = shot.width / shot.height
  const wide = shape >= 1.25
  const style = { '--turn': `${turns[shot.number % turns.length]}deg`, '--order': shot.number } as CSSProperties
  return (
    <figure className={[styles.print, wide ? styles.wide : ''].join(' ')} style={style}>
      <Reveal delay={delay} tilt={shot.number % 2 ? 2 : -2}>
        <button type="button" className={`print ${styles.frame}`} onClick={() => onOpen(shot.number)}>
          {shape < 3.5 ? <Tape color={tapes[shot.number % tapes.length]} className={styles.tape} /> : null}
          <img
            className={styles.image}
            src={source(shot, 'medium')}
            srcSet={sourceSet(shot)}
            sizes={sizes(share, wide)}
            width={shot.width}
            height={shot.height}
            alt={shot.alt}
            loading="lazy"
            decoding="async"
          />
          {shot.verdict ? <Tag verdict={shot.verdict} /> : null}
          <span className="visually-hidden">
            {shot.verdict ? ` ${said[shot.verdict]}.` : ''} Open it larger.
          </span>
        </button>
        <figcaption className={styles.caption}>
          <span className={`meta ${styles.number}`}>No. {String(shot.number).padStart(2, '0')}</span>
          {shot.caption}
        </figcaption>
      </Reveal>
    </figure>
  )
}

/** How wide the picture shows: two abreast on a phone, its column's share from 720 px, beside the note from 1000 px. */
function sizes(share: number, wide: boolean): string {
  const across = (board: string) => `calc(${board} * ${share.toFixed(4)} - 14px)`
  return [
    `(min-width: 1260px) ${across('(1180px - 17rem - 50px)')}`,
    `(min-width: 1000px) ${across('(100vw - 80px - 17rem - 50px)')}`,
    `(min-width: 720px) ${across('92vw')}`,
    wide ? 'calc(100vw - 46px)' : 'calc(50vw - 40px)',
  ].join(', ')
}

/** A paper label on a print's corner saying whether the idea stayed, written on as it comes into view. */
export function Tag({ verdict, className }: { verdict: Verdict; className?: string }) {
  const ref = useRef<HTMLSpanElement>(null)
  const { arrived } = useArrival(ref, { amount: 1 })
  return (
    <span ref={ref} className={[styles.tag, styles[verdict], className].filter(Boolean).join(' ')} aria-hidden="true">
      <Drawn line={words[verdict]} play={arrived} delay={0.25} />
    </span>
  )
}
