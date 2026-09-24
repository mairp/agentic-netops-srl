// A minimal local shim of the node:test and node:assert/strict surface the unit tests use, so the
// test build (tsconfig.test.json) needs no @types/node dependency. Runtime is Node's own.

declare module 'node:test' {
  type TestFn = (t: unknown) => void | Promise<void>
  export function test(name: string, fn: TestFn): Promise<void>
  export function describe(name: string, fn: () => void | Promise<void>): Promise<void>
  export function it(name: string, fn: TestFn): Promise<void>
  export function before(fn: () => void | Promise<void>): void
  export function after(fn: () => void | Promise<void>): void
  export function beforeEach(fn: () => void | Promise<void>): void
  export function afterEach(fn: () => void | Promise<void>): void
  export default test
}

declare module 'node:assert/strict' {
  interface Assert {
    (value: unknown, message?: string): asserts value
    ok(value: unknown, message?: string): asserts value
    equal<T>(actual: unknown, expected: T, message?: string): asserts actual is T
    notEqual(actual: unknown, expected: unknown, message?: string): void
    deepEqual<T>(actual: unknown, expected: T, message?: string): asserts actual is T
    notDeepEqual(actual: unknown, expected: unknown, message?: string): void
    match(value: string, pattern: RegExp, message?: string): void
    doesNotMatch(value: string, pattern: RegExp, message?: string): void
    throws(fn: () => unknown, expected?: unknown, message?: string): void
    rejects(promise: Promise<unknown> | (() => Promise<unknown>), expected?: unknown, message?: string): Promise<void>
    fail(message?: string): never
  }
  const assert: Assert
  export default assert
}
