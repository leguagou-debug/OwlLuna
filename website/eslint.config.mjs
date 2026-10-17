import { registerHooks } from 'node:module'

// typescript-eslint does not run on TypeScript 7 yet, so lint parses with the TypeScript 6 API.
registerHooks({
  resolve: (specifier, context, nextResolve) =>
    nextResolve(specifier === 'typescript' ? 'typescript6' : specifier, context),
})

const { default: next } = await import('eslint-config-next')
const jsxA11y = next.find((block) => block.plugins?.['jsx-a11y']).plugins['jsx-a11y']

const config = [
  ...next,
  {
    files: ['**/*.{jsx,tsx}'],
    rules: {
      ...jsxA11y.flatConfigs.recommended.rules,
      // Safari drops list semantics from lists styled with list-style: none, so those keep role="list".
      'jsx-a11y/no-redundant-roles': ['error', { ul: ['list'], ol: ['list'] }],
    },
  },
  {
    rules: {
      // The static export has no image optimizer; pictures ship as WebP already sized for each place.
      '@next/next/no-img-element': 'off',
      // A React Compiler rule, and the site does not use the compiler; its demos set state on purpose when they mount or come into view.
      'react-hooks/set-state-in-effect': 'off',
      // A React Compiler rule; refs read in render pick the viewer's slide direction and keep live regions quiet until a first touch.
      'react-hooks/refs': 'off',
    },
  },
]

export default config
