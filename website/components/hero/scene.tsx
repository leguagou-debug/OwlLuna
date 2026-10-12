'use client'

import type { TargetAndTransition, Transition } from 'motion/react'
import { createContext, useContext } from 'react'

type Scene = {
  /** The tile is on screen, so its scene may run. */
  play: boolean
  /** Milliseconds taken off every beat, for a tile that came into view after the others had played. */
  shift: number
}

const SceneContext = createContext<Scene>({ play: true, shift: 0 })

export const SceneProvider = SceneContext.Provider

/** The clock of the app's launch splash: beats are given in its milliseconds and come back as seconds to wait. */
export function useScene() {
  const scene = useContext(SceneContext)
  const at = (ms: number) => Math.max(0, ms - scene.shift) / 1000
  const beat = (from: TargetAndTransition, to: TargetAndTransition, ms: number, transition: Transition = {}) => ({
    initial: from,
    animate: scene.play ? to : from,
    transition: { ...transition, delay: at(ms) },
  })
  /** A pen stroke drawn from its start; it has no ink at all until its beat. */
  const draw = (ms: number, transition: Transition = {}) => ({
    initial: { pathLength: 0, opacity: 0 },
    animate: scene.play ? { pathLength: 1, opacity: 1 } : { pathLength: 0, opacity: 0 },
    transition: { ...transition, delay: at(ms), opacity: { duration: 0.01, delay: at(ms) } },
  })
  return { play: scene.play, at, beat, draw }
}

/** The fixed inks of the splash's tiles, which do not change at night. */
export const inks = {
  ink: '#1B2230',
  paper: '#F1EDE4',
  board: '#FAF7F0',
  white: '#FFFDF6',
  rule: '#D6CFBE',
  moon: '#F4DE3C',
  moonLight: '#FBF07A',
  tomato: '#C9452F',
} as const

/** A fixed point in an SVG drawing's own coordinates for a group to turn or grow about. */
export const about = (x: number, y: number) => ({ transformBox: 'view-box', transformOrigin: `${x}px ${y}px` }) as const
