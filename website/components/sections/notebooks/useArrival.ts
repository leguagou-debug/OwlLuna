'use client'

import { useInView } from 'motion/react'
import { useEffect, useLayoutEffect, useState, type RefObject } from 'react'

const useIsomorphicLayoutEffect = typeof window === 'undefined' ? useEffect : useLayoutEffect

/** Whether a drawing may play: true before scripts run and once it is in view, false only while it waits below the window. */
export function useArrival(ref: RefObject<Element | null>, amount = 0.3) {
  const [waiting, setWaiting] = useState(false)
  const inView = useInView(ref, { once: true, amount })

  useIsomorphicLayoutEffect(() => {
    const element = ref.current
    if (element && element.getBoundingClientRect().top > window.innerHeight * 0.92) setWaiting(true)
  }, [ref])

  return !waiting || inView
}
