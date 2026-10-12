'use client'

import { motion, useInView } from 'motion/react'
import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react'
import { settle } from '@/lib/motion'

const useIsomorphicLayoutEffect = typeof window === 'undefined' ? useEffect : useLayoutEffect

type Props = {
  children: ReactNode
  /** Seconds after it comes into view. */
  delay?: number
  /** How far below its place it starts, in pixels. */
  rise?: number
  /** Degrees it starts turned by, like a tile of the splash. */
  tilt?: number
  className?: string
}

/** Brings content up as it scrolls into view. It is only ever hidden below the window, so the page reads whole without scripts. */
export function Reveal({ children, delay = 0, rise = 28, tilt = 0, className }: Props) {
  const ref = useRef<HTMLDivElement>(null)
  const [waiting, setWaiting] = useState(false)
  const inView = useInView(ref, { once: true, margin: '0px 0px -10% 0px' })

  useIsomorphicLayoutEffect(() => {
    const element = ref.current
    if (element && element.getBoundingClientRect().top > window.innerHeight * 0.92) setWaiting(true)
  }, [])

  const hidden = waiting && !inView
  return (
    <motion.div
      ref={ref}
      className={className}
      initial={false}
      animate={hidden ? { opacity: 0, y: rise, rotate: tilt } : { opacity: 1, y: 0, rotate: 0 }}
      transition={hidden ? { duration: 0 } : { ...settle, delay }}
    >
      {children}
    </motion.div>
  )
}
