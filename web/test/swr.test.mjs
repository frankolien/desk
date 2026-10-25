import assert from "node:assert/strict";
import test from "node:test";
import { lastGood } from "../api/_swr.mjs";
import { memoryStore } from "../api/_store.mjs";

const clock = (start) => { let t = start; const now = () => t; now.advance = (ms) => { t += ms; }; return now; };

test("nothing held builds and keeps the answer", async () => {
  const store = memoryStore(); const now = clock(1_000);
  let builds = 0;
  const first = await lastGood(store, "k", { freshMs: 30_000, now, background: () => {} }, async () => ++builds);
  assert.deepEqual([first.value, first.stale, builds], [1, false, 1]);
});

test("a fresh answer is served without building", async () => {
  const store = memoryStore(); const now = clock(1_000);
  let builds = 0;
  await lastGood(store, "k", { freshMs: 30_000, now, background: () => {} }, async () => ++builds);
  now.advance(10_000);
  const again = await lastGood(store, "k", { freshMs: 30_000, now, background: () => {} }, async () => ++builds);
  assert.deepEqual([again.value, again.stale, again.ageMs, builds], [1, false, 10_000, 1]);
});

test("a stale answer is served at once and rebuilt once in the background", async () => {
  const store = memoryStore(); const now = clock(1_000);
  let builds = 0; const queued = [];
  await lastGood(store, "k", { freshMs: 30_000, now, background: () => {} }, async () => ++builds);
  now.advance(60_000);
  const opts = { freshMs: 30_000, now, background: (work) => queued.push(work) };
  let open; const gate = new Promise((resolve) => { open = resolve; });
  const slow = async () => { await gate; return ++builds; };
  const a = await lastGood(store, "k", opts, slow);
  const b = await lastGood(store, "k", opts, slow);
  assert.deepEqual([a.value, a.stale, b.value, b.stale], [1, true, 1, true]);
  assert.equal(queued.length, 1, "a second request while rebuilding does not start another");
  open();
  await Promise.all(queued);
  const c = await lastGood(store, "k", opts, async () => ++builds);
  assert.deepEqual([c.value, c.stale, builds], [2, false, 2]);
});

test("a failed rebuild keeps the old answer and frees the key", async () => {
  const store = memoryStore(); const now = clock(1_000);
  await lastGood(store, "k", { freshMs: 30_000, now, background: () => {} }, async () => "old");
  now.advance(60_000);
  const queued = [];
  const opts = { freshMs: 30_000, now, background: (work) => queued.push(work) };
  const a = await lastGood(store, "k", opts, async () => { throw new Error("upstream"); });
  await Promise.all(queued);
  const b = await lastGood(store, "k", opts, async () => "new");
  assert.equal(a.value, "old");
  assert.equal(b.value, "old");
  assert.equal(queued.length, 2, "the rebuild lock was released after the failure");
});

test("without a store it just builds", async () => {
  const out = await lastGood(null, "k", { freshMs: 1 }, async () => 7);
  assert.deepEqual([out.value, out.stale], [7, false]);
});

test("freshness can depend on the held answer", async () => {
  const store = memoryStore(); const now = clock(1_000);
  const freshMs = (held) => (held?.partial ? 5_000 : 30_000);
  await lastGood(store, "k", { freshMs, now, background: () => {} }, async () => ({ partial: true }));
  now.advance(10_000);
  const out = await lastGood(store, "k", { freshMs, now, background: () => {} }, async () => ({ partial: false }));
  assert.equal(out.stale, true);
});
