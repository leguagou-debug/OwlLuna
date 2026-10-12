'use client'

import { useInView } from 'motion/react'
import { useEffect, useLayoutEffect, useRef, useState } from 'react'

const useIsomorphicLayoutEffect = typeof window === 'undefined' ? useEffect : useLayoutEffect

/** Whether an element has scrolled into view. What is on screen at load has arrived already, so nothing is hidden without scripts. */
export function useArrival<T extends Element>(amount = 0.6) {
  const ref = useRef<T>(null)
  const [waited, setWaited] = useState(false)
  const inView = useInView(ref, { once: true, amount })

  useIsomorphicLayoutEffect(() => {
    const element = ref.current
    if (element && element.getBoundingClientRect().top > window.innerHeight * 0.92) setWaited(true)
  }, [])

  return { ref, arrived: !waited || inView, waited }
}
