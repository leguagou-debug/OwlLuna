/** The hand the splash's checklist is printed in (`Launch/BentoNoteTile.swift`): leaning capitals, each a little off its neighbours' line. */
const capitals: Record<string, [number, string]> = {
  C: [14.8, 'M13.7,4.4 Q8.4,-2.5 3.1,4 Q-2.2,11.1 3.1,17 Q8.3,23 14.1,17'],
  D: [14.8, 'M0.1,20.9 L0,0 M0,0.6 Q15.8,0.6 14.8,11 Q14.3,20.9 0.1,20.9'],
  E: [12.7, 'M12.1,0.2 L0,0.3 L0,20.7 L12.6,20.7 M0,10.2 L9.5,10.1'],
  H: [14.3, 'M-0.2,-0.2 L-0.1,20.6 M14.1,0.3 L14.2,21.1 M-0.2,10.7 L14.1,10.7'],
  I: [4.3, 'M2.2,0 L2.1,21'],
  K: [13.7, 'M0,0 L0,21 M12.6,0.4 L0.5,12.7 M4.7,9.1 L13.7,21.5'],
  R: [14.7, 'M0.1,21 L0,0 M0,0.5 Q13.7,-0.6 13.2,6.2 Q12.6,11.9 0.1,11.6 M5.3,11.7 L13.7,21.4'],
  S: [13.1, 'M11.1,3.2 Q5.1,-2.6 1.1,3.2 Q-2.4,8.9 5.6,10.5 Q14,12.5 11.1,17.8 Q7,23.5 -0.5,17.8'],
  T: [15.8, 'M0,0.5 L15.7,0.5 M7.9,0.8 L7.8,21.2'],
  U: [14.7, 'M0,-0.2 L-0.1,13.4 Q-0.1,21.3 7.3,21.5 Q14.6,21.8 14.6,13.9 L14.6,0.2'],
  W: [20.4, 'M-1.2,0 L4.4,21 L9.2,8.4 L14.9,21 L19,0.1'],
  Y: [15.8, 'M0,-0.3 L7.9,10.9 L15.8,0.3 M7.9,10.9 L7.8,20.9'],
}

const capHeight = 21
const slant = 0.158
const letterGap = 5.7
const unevenness: [number, number][] = [
  [-0.9, -2.7], [-0.7, 0.65], [0, -0.3], [0.2, -1.05], [0.95, -2.2], [-0.85, -2.9],
  [0.4, -0.8], [-0.3, 0.4], [0.7, -1.9], [-0.6, -0.5], [0.1, -2.5], [0.8, 0.2],
]

export type HandLetter = { d: string; transform: string }

/** A word's letters, tops at 0 and feet at 21, with the width the word takes. */
export function printed(word: string): { letters: HandLetter[]; width: number } {
  let x = 0
  const letters = [...word.toUpperCase()].map((letter, index) => {
    const [width, d] = capitals[letter]
    const [drop, turn] = unevenness[index % unevenness.length]
    const lean = (Math.atan(slant) * 180) / Math.PI
    const transform = `translate(${x} ${drop}) rotate(${turn} ${width / 2} ${capHeight / 2}) translate(${slant * (capHeight / 2)} 0) skewX(${-lean})`
    x += width + letterGap
    return { d, transform }
  })
  return { letters, width: x - letterGap }
}
