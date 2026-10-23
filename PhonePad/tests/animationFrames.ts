import type { TestContext } from 'node:test';

export function animationFrames(t: TestContext) {
  const previousRequest = globalThis.requestAnimationFrame;
  const previousCancel = globalThis.cancelAnimationFrame;
  let next = 0;
  let time = 0;
  t.mock.method(performance, 'now', () => time);
  const pending = new Map<number, (time: number) => void>();
  globalThis.requestAnimationFrame = callback => { pending.set(++next, callback); return next; };
  globalThis.cancelAnimationFrame = id => { if (id != null) pending.delete(id); };
  t.after(() => {
    globalThis.requestAnimationFrame = previousRequest;
    globalThis.cancelAnimationFrame = previousCancel;
  });
  return {
    get pending() { return pending.size; },
    advance(milliseconds: number) { time += milliseconds; },
    tick(milliseconds = 1000 / 60) {
      time += milliseconds;
      const callbacks = Array.from(pending.values());
      pending.clear();
      for (const callback of callbacks) callback(time);
    },
  };
}
