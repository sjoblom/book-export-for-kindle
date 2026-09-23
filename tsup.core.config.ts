import { defineConfig } from 'tsup'

// `dist-core/kindle-core.js`: the pure logic in src/core as one classic script
// for JavaScriptCore in the native app (macos/PLAN.md). An IIFE rather than a
// module because `JSContext.evaluateScript` runs scripts, not modules; the
// entry assigns `globalThis.KindleCore` itself. Neutral platform so nothing
// Node-specific is resolved or shimmed. ES2022 is what JavaScriptCore on macOS
// 13 runs natively. Left unminified: when a call fails inside the app, the
// JavaScript line in the error should be readable.
export default defineConfig({
  entry: { 'kindle-core': 'src/core/index.ts' },
  outDir: 'dist-core',
  format: ['iife'],
  platform: 'neutral',
  target: 'es2022',
  clean: true,
  sourcemap: false,
  minify: false,
  treeshake: true,
  outExtension: () => ({ js: '.js' })
})
