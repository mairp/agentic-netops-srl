// `npm test` / `make test-ui` (T123-T125): compile the TypeScript unit tests with tsc into the
// git-ignored .test-build/ (CI runs Node 20, which cannot strip types), then run the Node built-in
// test runner over the compiled tests and the plain-JS suites in tests/. Explicit file arguments
// work the same on Node 20 and Node 22 (no glob, no directory argument).
import { spawnSync } from 'node:child_process'
import { existsSync, readdirSync, rmSync, statSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const ui = join(dirname(fileURLToPath(import.meta.url)), '..')
const out = join(ui, '.test-build')

rmSync(out, { recursive: true, force: true })
const tsc = spawnSync(process.execPath, [join(ui, 'node_modules/typescript/bin/tsc'), '-p', 'tsconfig.test.json'], {
  cwd: ui,
  stdio: 'inherit',
})
if (tsc.status !== 0) process.exit(tsc.status ?? 1)

const found = []
const walk = (dir) => {
  if (!existsSync(dir)) return
  for (const name of readdirSync(dir).sort()) {
    const path = join(dir, name)
    if (statSync(path).isDirectory()) walk(path)
    else if (/\.test\.(m?js)$/.test(name)) found.push(relative(ui, path))
  }
}
walk(out)
walk(join(ui, 'tests'))

const run = spawnSync(process.execPath, ['--test', ...found], { cwd: ui, stdio: 'inherit' })
process.exit(run.status ?? 1)
