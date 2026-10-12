'use client'

import { motion } from 'motion/react'
import type { ReactNode } from 'react'
import { landing } from '@/lib/motion'

/** A piece of paper settling into its place as it comes into view. It is turned a little until then, never hidden. */
export function Drop({ children, className, turn = 2.5 }: { children: ReactNode; className?: string; turn?: number }) {
  return (
    <motion.div
      data-study-art
      className={className}
      initial={{ y: 14, rotate: turn }}
      whileInView={{ y: 0, rotate: 0 }}
      viewport={{ once: true, amount: 0.7 }}
      transition={{ ...landing, delay: 0.25 }}
    >
      {children}
    </motion.div>
  )
}
