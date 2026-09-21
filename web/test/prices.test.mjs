// node --test web/test/prices.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import { levelStep, levelText, priceDeliveries, priceEvents, pricePayload } from "../api/_prices.mjs";
import { memoryStore } from "../api/_store.mjs";
import { parseSubscription } from "../api/alerts.mjs";

test("a level is a tenth of the price's magnitude", () => {
  assert.equal(levelStep(81_294), 1000);
  assert.equal(levelStep(2_654), 100);
  assert.equal(levelStep(111.5), 10);
  assert.equal(levelStep(4.96), 0.1);
  assert.ok(Math.abs(levelStep(0.0248) - 0.001) < 1e-12);
  assert.equal(levelStep(0), null);
  assert.equal(levelText(85_000), "$85K");
  assert.equal(levelText(2_700), "$2.7K");
  assert.equal(levelText(115), "$115");
  assert.equal(levelText(0.025), "$0.025");
});

test("crossing a level up or down is an event, and so is a day's move past a threshold", () => {
  assert.deepEqual(priceEvents("BTC", { mark: 84_900 }, { mark: 85_020, prev: 84_000 }), [{ kind: "level", direction: "up", level: 85_000, mark: 85_020 }]);
  assert.deepEqual(priceEvents("BTC", { mark: 85_020 }, { mark: 84_950, prev: 84_000 }), [{ kind: "level", direction: "down", level: 85_000, mark: 84_950 }]);
  assert.deepEqual(priceEvents("BTC", { mark: 84_100 }, { mark: 84_900, prev: 84_000 }), []);
  assert.deepEqual(priceEvents("BTC", null, { mark: 85_020, prev: 84_000 }), []);
  const moved = priceEvents("SOL", { mark: 111 }, { mark: 111.5, prev: 100 });
  assert.equal(moved.length, 1);
  assert.equal(moved[0].kind, "move");
  assert.equal(moved[0].threshold, 0.1);
  assert.equal(moved[0].direction, "up");
});

test("the alert reads like a sentence and carries the market for the app", () => {
  const up = pricePayload("BTC", { kind: "level", direction: "up", level: 85_000, mark: 85_020 });
  assert.equal(up.aps.alert.body, "Bitcoin just broke $85K 🟢");
  assert.equal(up.aps["interruption-level"], "time-sensitive");
  assert.deepEqual(up.desk, { type: "price", market: "BTC", mark: 85_020, kind: "level", direction: "up", level: 85_000 });
  const down = pricePayload("SOL", { kind: "level", direction: "down", level: 110, mark: 109.7 });
  assert.equal(down.aps.alert.body, "Solana just fell through $110 🔴");
  const move = pricePayload("MON", { kind: "move", direction: "down", threshold: 0.05, change: -0.062, mark: 0.0231 });
  assert.equal(move.aps.alert.body, "Monad is down 6% today 🔴 · $0.0231");
});

test("the first reading is the baseline, a level is told once in six hours, and opted-out subscribers are skipped", async () => {
  const store = memoryStore();
  const subscribers = [
    { id: "a", record: { token: "t", prices: true } },
    { id: "b", record: { token: "u", prices: false } },
    { id: "c", record: { token: "v" } },
  ];
  const first = await priceDeliveries({ store, quotes: [{ name: "BTC", mark: 84_900, prev: 70_000 }], subscribers, now: 1 });
  assert.equal(first.deliveries.length, 0);
  const second = await priceDeliveries({ store, quotes: [{ name: "BTC", mark: 85_100, prev: 84_000 }], subscribers, now: 2 });
  assert.equal(second.events, 1);
  assert.deepEqual(second.deliveries.map((d) => d.id), ["a", "c"]);
  assert.equal(second.deliveries[0].collapseId, "px-BTC");
  const wobble = await priceDeliveries({ store, quotes: [{ name: "BTC", mark: 84_950, prev: 84_000 }], subscribers, now: 3 });
  const again = await priceDeliveries({ store, quotes: [{ name: "BTC", mark: 85_050, prev: 84_000 }], subscribers, now: 4 });
  assert.equal(wobble.events, 1);
  assert.equal(again.events, 0);
});

test("a subscription carries whether it wants prices, on unless said otherwise", () => {
  const base = { install: "ab".repeat(32), token: "cd".repeat(32), traders: [] };
  assert.equal(parseSubscription(base).record.prices, true);
  assert.equal(parseSubscription(base).wantsPrices, false);
  assert.equal(parseSubscription({ ...base, prices: true }).wantsPrices, true);
  assert.equal(parseSubscription({ ...base, prices: false }).record.prices, false);
});
