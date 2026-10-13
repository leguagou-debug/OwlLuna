import type { Metadata } from 'next'
import { Log } from '@/components/prototypes/Log'
import { Tag } from '@/components/prototypes/Print'
import { entries, firstDay, lastDay, sequence } from '@/components/prototypes/shots'
import { Away, Button } from '@/components/ui/Button'
import { SectionHeading } from '@/components/ui/SectionHeading'
import { formatDate, site } from '@/lib/site'
import styles from './prototypes.module.css'

export const metadata: Metadata = {
  title: 'Prototypes',
  description:
    'Screenshots from the making of OwlLuna, in the order they were saved: first tries, options side by side, and the ones that were dropped.',
}

/** A date as its day and the first three letters of its month. */
function short(iso: string): string {
  const [day, month] = formatDate(iso).split(' ')
  return `${day} ${month.slice(0, 3)}`
}

export default function Prototypes() {
  return (
    <>
      <section className="section-tight">
        <div className={`wrap ${styles.intro}`}>
          <div className={styles.lead}>
            <SectionHeading as="h1" eyebrow="Prototypes" title="How it came to look like this">
              <p>
                The {sequence.length} screenshots here were saved between {formatDate(firstDay).split(' ')[0]} and{' '}
                {formatDate(lastDay)}, while the app was being finished: first tries, options side by side, and a few
                dead ends. Select one to see it whole.
              </p>
            </SectionHeading>
            <p className={styles.key}>
              <span className={styles.keyLine} aria-hidden="true">
                <Tag verdict="kept" className={styles.keyTag} />
                went into the app.
              </span>
              <span className={styles.keyLine} aria-hidden="true">
                <Tag verdict="dropped" className={styles.keyTag} />
                did not.
              </span>
              <span className="visually-hidden">A screenshot marked Kept went into the app. One marked Dropped did not.</span>
            </p>
          </div>

          <nav className={styles.contents} aria-label="The days">
            <p className={styles.band}>In order</p>
            <ol>
              {entries.map((entry) => (
                <li key={entry.id}>
                  <a href={`#${entry.id}`} className={styles.row}>
                    <time dateTime={entry.date} className={`tabular ${styles.when}`}>
                      {short(entry.date)}
                    </time>
                    <span className={styles.what}>{entry.title}</span>
                    <span className={`tabular ${styles.count}`}>
                      {entry.shots.length}
                      <span className="visually-hidden"> screenshots</span>
                    </span>
                  </a>
                </li>
              ))}
            </ol>
          </nav>
        </div>
      </section>

      <section className={styles.pages} aria-label="The screenshots">
        <noscript>
          <style>{`[data-study-art]{opacity:1!important;stroke-dasharray:none!important}`}</style>
        </noscript>
        <div className="wrap">
          <Log />
          <div className={styles.closing}>
            <p>That is the pile. What the finished app does is on the first page, and every line of it is on GitHub.</p>
            <div className={styles.actions}>
              <Button href="/#features">What the app does</Button>
              <Button href={site.repo}>
                The repository on GitHub
                <Away />
              </Button>
            </div>
          </div>
        </div>
      </section>
    </>
  )
}
