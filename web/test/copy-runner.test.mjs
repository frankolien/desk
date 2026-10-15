// copyd's loop, its chain-event parsing and its notifications.
import { test } from "node:test";
import assert from "node:assert/strict";
import { memoryStore } from "../api/_store.mjs";
import { createRunner } from "../copyd/runner.mjs";
import { createLease } from "../copyd/lease.mjs";
import { accountInFrame, subscription, TOPICS, EXCHANGE } from "../copyd/watcher.mjs";
import { copyPayload, createNotifier } from "../copyd/notify.mjs";

const quiet = { warn() {} };

function fakeEngine() {
  const calls = [];
  return {
    calls,
    async refresh() { calls.push("refresh"); return 0; },
    async sweep() { calls.push("sweep"); return {}; },
    traderForAccount(id) { return id === "9" ? "0xtrader" : null; },
    async processTrader(trader) { calls.push(`read ${trader}`); await new Promise((r) => setTimeout(r, 5)); return []; },
  };
}

test("Only the lease holder sweeps, and each sweep leaves a heartbeat", async () => {
  const store = memoryStore();
  const clock = { t: 1_000 };
  const holder = createLease({ store, now: () => clock.t, id: "other" });
  await holder.acquire();
  const engine = fakeEngine();
  const runner = createRunner({ engine, lease: createLease({ store, now: () => clock.t, id: "me" }), store, now: () => clock.t, logger: quiet });
  assert.deepEqual(await runner.tick(), { swept: false, reason: "no lease" });
  assert.deepEqual(engine.calls, []);
  clock.t += 20_000; // the other holder stopped renewing
  const result = await runner.tick();
  assert.equal(result.swept, true);
  assert.deepEqual(engine.calls, ["refresh", "sweep"]);
  assert.equal(await store.get("copy:heartbeat"), String(clock.t));
});

test("copy:halt stops everything until it is cleared", async () => {
  const store = memoryStore();
  const engine = fakeEngine();
  const runner = createRunner({ engine, lease: createLease({ store, id: "me" }), store, logger: quiet });
  await store.set("copy:halt", "incident 1");
  assert.deepEqual(await runner.tick(), { swept: false, reason: "halted" });
  await store.del("copy:halt");
  assert.equal((await runner.tick()).swept, true);
});

test("An event reads its trader without waiting for a sweep; unknown accounts and a halt stop it", async () => {
  const store = memoryStore();
  const engine = fakeEngine();
  let release;
  engine.sweep = async () => { engine.calls.push("sweep"); await new Promise((r) => { release = r; }); return {}; };
  const runner = createRunner({ engine, lease: createLease({ store, id: "me" }), store, logger: quiet });
  const tick = runner.tick();
  await new Promise((r) => setTimeout(r, 5));
  await Promise.all([runner.onAccount("9"), runner.onAccount("123")]);
  assert.deepEqual(engine.calls, ["refresh", "sweep", "read 0xtrader"], "the read did not wait for the sweep");
  release(); await tick;
  await store.set("copy:halt", "incident");
  await runner.tick();
  await runner.onAccount("9");
  await runner.idle();
  assert.equal(engine.calls.filter((c) => c.startsWith("read")).length, 1);
});

test("A log frame yields its account id; anything else yields nothing", () => {
  const data = `0x${"0".repeat(63)}1${"0".repeat(48)}${(12345).toString(16).padStart(16, "0")}${"0".repeat(64)}`;
  const frame = (topic, body = data) => JSON.stringify({ jsonrpc: "2.0", method: "eth_subscription", params: { result: { topics: [topic], data: body } } });
  assert.equal(accountInFrame(frame(TOPICS[0])), "12345");
  assert.equal(accountInFrame(frame(TOPICS[4].toUpperCase().replace("0X", "0x"))), "12345");
  assert.equal(accountInFrame(frame("0xdeadbeef")), null);
  assert.equal(accountInFrame(frame(TOPICS[1], `0x${"0".repeat(64)}${"1".repeat(64)}`)), null, "a word wider than an account id is not one");
  assert.equal(accountInFrame("not json"), null);
  const sub = JSON.parse(subscription());
  assert.equal(sub.method, "eth_subscribe");
  assert.equal(sub.params[1].address, EXCHANGE);
  assert.deepEqual(sub.params[1].topics, [TOPICS]);
});

const row = (over) => ({ id: "r1", trader: "0x52ac212e7187a799a7382c7a768cb35b72a3e20a", symbol: "BTC", isLong: true, leverage: 5, detail: "10.00 AUSD margin · stop −25%", ...over });

test("Each result reads plainly, and a paper copy says so", () => {
  assert.equal(copyPayload(row({ kind: "opened" })).aps.alert.title, "Copied 0x52ac…e20a: Long BTC 5×");
  assert.equal(copyPayload(row({ kind: "opened", isShadow: true })).aps.alert.title, "Shadow · Copied 0x52ac…e20a: Long BTC 5×");
  const closed = copyPayload(row({ kind: "closed", pnl: -6.25, detail: "Closed with the trader." }), { name: "akintomiwa" });
  assert.equal(closed.aps.alert.title, "Closed with akintomiwa: Long BTC 5×");
  assert.equal(closed.aps.alert.body, "−6.25 AUSD. Closed with the trader.");
  assert.equal(copyPayload(row({ kind: "protected", pnl: 3.1, detail: "Take profit hit." })).aps.alert.body, "Take profit hit. +3.10 AUSD.");
  assert.equal(copyPayload(row({ kind: "paused", trader: "", detail: "Today's copy losses reached your 50 AUSD limit, so auto-copy paused." })).aps.alert.title, "Auto-Copy paused");
  assert.equal(copyPayload(row({ kind: "basket" })), null);
});

test("Skips are held to one per trader per hour; devices without a token get nothing", async () => {
  const sent = [];
  const notify = createNotifier({ send: async (push, payload) => { sent.push(payload); return { status: 200 }; }, now: () => 7_200_000 });
  const copier = { id: "mainnet:0xme", push: { token: "ab".repeat(32), environment: "production" } };
  await notify(copier, row({ kind: "skipped", detail: "x" }));
  assert.deepEqual(await notify(copier, row({ kind: "skipped", detail: "y" })), { skipped: "throttled" });
  await notify(copier, row({ kind: "opened" }));
  assert.equal(sent.length, 2);
  assert.deepEqual(await notify({ id: "x" }, row({ kind: "opened" })), { skipped: "no device" });
  assert.deepEqual(await notify({ ...copier, notifyShadow: false }, row({ kind: "opened", isShadow: true })), { skipped: "shadow muted" });
});

test("The lease is kept between sweeps, so events are never dropped in a sweep's last seconds", async () => {
  const store = memoryStore();
  const clock = { t: 1_000 };
  const engine = fakeEngine();
  const runner = createRunner({ engine, lease: createLease({ store, now: () => clock.t, id: "me" }), store, now: () => clock.t, logger: quiet });
  await runner.tick();
  for (let i = 0; i < 6; i++) { clock.t += 5_000; await runner.keepLease(); }
  await runner.onAccount("9");
  await runner.idle();
  assert.ok(engine.calls.includes("read 0xtrader"), "30 s after the last sweep, still held");
});

test("Taking the lease back after losing it reloads the engine before it acts", async () => {
  const store = memoryStore();
  const clock = { t: 1_000 };
  const engine = fakeEngine();
  engine.reset = () => engine.calls.push("reset");
  const runner = createRunner({ engine, lease: createLease({ store, now: () => clock.t, id: "me" }), store, now: () => clock.t, logger: quiet });
  await runner.tick();
  const other = createLease({ store, now: () => clock.t, id: "other" });
  clock.t += 20_000;
  await other.acquire();
  assert.equal((await runner.tick()).reason, "no lease");
  clock.t += 20_000;
  await runner.tick();
  assert.deepEqual(engine.calls, ["refresh", "sweep", "reset", "refresh", "sweep"]);
});
