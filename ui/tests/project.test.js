// Chat-surface project sanity (T025, FR-020): the first suite of `make test-ui`
// (`npm test`, the Node built-in test runner — no extra dependency). It asserts
// that the tracked lock file is the resolution of package.json, so `npm ci` in
// CI installs exactly what was declared, and the pins the build relies on.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const read = (f) => JSON.parse(readFileSync(new URL(`../${f}`, import.meta.url), 'utf8'))
const pkg = read('package.json')
const lock = read('package-lock.json')

test('package-lock.json is the resolution of package.json', () => {
  assert.equal(lock.name, pkg.name)
  assert.equal(lock.version, pkg.version)
  assert.ok(lock.lockfileVersion >= 2)
  const root = lock.packages['']
  assert.deepEqual(root.dependencies ?? {}, pkg.dependencies ?? {})
  assert.deepEqual(root.devDependencies ?? {}, pkg.devDependencies ?? {})
})

test('every declared dependency is locked at a concrete version', () => {
  const all = { ...pkg.dependencies, ...pkg.devDependencies }
  for (const name of Object.keys(all)) {
    const entry = lock.packages[`node_modules/${name}`]
    assert.ok(entry, `${name} missing from package-lock.json`)
    assert.match(entry.version, /^\d+\.\d+\.\d+/, `${name} locked without a version`)
    assert.ok(entry.integrity, `${name} locked without an integrity hash`)
  }
})

test('the surface is built for node 20 with Vite and React', () => {
  assert.equal(pkg.engines.node, '^20.19.0')
  assert.equal(pkg.type, 'module')
  assert.match(pkg.scripts.build, /tsc -b && vite build/)
  for (const dep of ['react', 'react-dom']) assert.ok(pkg.dependencies[dep], dep)
  for (const dep of ['vite', '@vitejs/plugin-react', 'typescript']) assert.ok(pkg.devDependencies[dep], dep)
})
