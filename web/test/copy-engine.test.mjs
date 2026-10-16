// The server's copy engine in shadow mode, against an in-memory store and books the test
// writes: every behaviour docs/server-copy.md promises before a key is involved.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { memoryStore } from "../api/_store.mjs";
import { createEngine, copierId, startOfDay, priceFrom } from "../copyd/engine.mjs";
import { createLease } from "../copyd/lease.mjs";
import { readTrader } from "../copyd/books.mjs";
import { DEFAULT_GUARDS, DEFAULT_RULES } from "../copyd/planner.mjs";

const context = JSON.parse(readFileSync(new URL("../../DeskKit/Tests/DeskFlowTests/Context-testnet.json", import.meta.url)));
const openMarkets = new Map(context.markets.filter((m) => m.config.is_open).map((m) => [m.id, m]));
const TRADER = "0x52ac212e7187a799a7382c7a768cb35b72a3e20a";
const ME = "0x50B240678777451BEfd67B7e8c3b4366482ba8F9";

const btc = (side = "long", { entry = 60_000, mark = 60_000, leverage = 5 } = {}) =>
  ({ symbol: "BTC", side, size: 0.5, entry, mark, collateral: 2_000, leverage, marketId: 16 });

function setup({ rules = {}, guards = {}, timeZone = "UTC", clock = { t: Date.UTC(2026, 9, 15, 12) } } = {}) {
  const store = memoryStore();
  const books = { [TRADER]: { accountId: "9", balance: 10_000, portfolio: 20_000, positions: {} } };
  const notes = [];
  const engine = createEngine({
    store, markets: async () => openMarkets, now: () => clock.t,
    readTrader: async (address) => books[address],
    notify: async (copier, row) => { notes.push(row); },
    logger: { warn() {} },
  });
  const copier = {
    network: "testnet", address: ME, timeZone, guards: { ...DEFAULT_GUARDS, ...guards },
    traders: { [TRADER]: { rules: { ...DEFAULT_RULES, ...rules }, since: clock.t } },
  };
  return { store, books, notes, engine, copier, clock, id: copierId("testnet", ME) };
}

test("What a trader already holds is never copied; what they open next is", async () => {
  const { engine, books, copier, id, notes } = setup();
  await engine.putCopier(copier);
  books[TRADER].positions = { BTC: btc() };
  assert.deepEqual(await engine.processTrader(TRADER), []);
  assert.equal((await engine.openCopies(id)).length, 0);

  books[TRADER].positions = {};
  await engine.processTrader(TRADER); // first empty read: held
  await engine.processTrader(TRADER); // second: a real close of nothing we copied
  books[TRADER].positions = { BTC: btc() };
  const found = await engine.processTrader(TRADER);
  assert.equal(found[0].kind, "opened");
  const open = await engine.openCopies(id);
  assert.equal(open.length, 1);
  assert.equal(open[0].symbol, "BTC");
  assert.equal(open[0].isShadow, true);
  assert.equal(open[0].leverage, 5);
  const [row] = await engine.log(id);
  assert.equal(row.kind, "opened");
  assert.match(row.detail, /^10\.00 AUSD margin · stop −25%$/);
  assert.equal(notes.at(-1).kind, "opened");
});

async function opened(over = {}) {
  const ctx = setup(over);
  await ctx.engine.putCopier(ctx.copier);
  await ctx.engine.processTrader(TRADER); // baseline: empty
  ctx.books[TRADER].positions = { BTC: btc() };
  await ctx.engine.processTrader(TRADER);
  return ctx;
}

test("A close by the trader closes the shadow copy with its result", async () => {
  const { engine, books, id } = await opened();
  books[TRADER].positions = { BTC: btc("long", { mark: 61_000 }) };
  await engine.processTrader(TRADER); // a mark move is not a move
  books[TRADER].positions = {};
  await engine.processTrader(TRADER);
  assert.equal((await engine.openCopies(id)).length, 1, "one empty read is not a close");
  await engine.processTrader(TRADER);
  assert.equal((await engine.openCopies(id)).length, 0);
  const [row] = await engine.log(id);
  assert.equal(row.kind, "closed");
  assert.equal(row.detail, "Closed with the trader.");
  assert.ok(row.pnl > 0, `expected a gain from 60,000 to 61,000, got ${row.pnl}`);
});

test("Closing with the trader can be turned off", async () => {
  const { engine, books, id } = await opened({ rules: { closeWithTrader: false } });
  books[TRADER].positions = { ETH: { ...btc(), symbol: "ETH", marketId: 32 } };
  await engine.processTrader(TRADER);
  assert.ok((await engine.openCopies(id)).some((c) => c.symbol === "BTC"));
});

test("A flip closes the copy first, then copies the new side", async () => {
  const { engine, books, id } = await opened();
  books[TRADER].positions = { BTC: btc("short") };
  await engine.processTrader(TRADER);
  const rows = await engine.log(id);
  assert.equal(rows[1].kind, "closed");
  assert.equal(rows[1].detail, "They flipped, so the copy was closed first.");
  assert.equal(rows[0].kind, "opened");
  const open = await engine.openCopies(id);
  assert.equal(open.length, 1);
  assert.equal(open[0].isLong, false);
});

test("An unreadable book changes nothing", async () => {
  const { engine, books, id } = await opened();
  books[TRADER] = { unreadable: true };
  await engine.processTrader(TRADER);
  await engine.processTrader(TRADER);
  assert.equal((await engine.openCopies(id)).length, 1);
});

test("Paused, nothing new is copied, and a live copy waits for an executor", async () => {
  const paused = setup();
  await paused.engine.putCopier({ ...paused.copier, paused: true });
  await paused.engine.processTrader(TRADER);
  paused.books[TRADER].positions = { BTC: btc() };
  await paused.engine.processTrader(TRADER);
  assert.equal((await paused.engine.log(paused.id))[0].detail, "Auto-copy was paused.");

  const live = setup({ rules: { mode: "live" } });
  await live.engine.putCopier(live.copier);
  await live.engine.processTrader(TRADER);
  live.books[TRADER].positions = { BTC: btc() };
  await live.engine.processTrader(TRADER);
  assert.equal((await live.engine.log(live.id))[0].detail, "Live copying from the server isn't switched on yet.");
});

test("The planner's skips are recorded in the app's words", async () => {
  const { engine, books, id } = setup();
  await engine.putCopier(setup().copier);
  await engine.processTrader(TRADER);
  books[TRADER].positions = { BTC: btc("long", { entry: 59_000 }) };
  await engine.processTrader(TRADER);
  assert.equal((await engine.log(id))[0].detail, "Price had already moved 1.69% against the copy since their entry.");
});

test("A shadow stop fires at the mark that broke it", async () => {
  const { engine, books, id } = await opened({ rules: { stopLossPercent: 25 } });
  books[TRADER].positions = { BTC: btc("long", { mark: 56_000 }) };
  await engine.sweep();
  const [row] = await engine.log(id);
  assert.equal(row.kind, "protected");
  assert.equal(row.detail, "Stop loss hit.");
  assert.ok(row.pnl < -2 && row.pnl >= -10);
  assert.equal((await engine.openCopies(id)).length, 0);
});

test("The daily loss limit counts from midnight in the copier's own time zone", async () => {
  const clock = { t: Date.UTC(2026, 9, 15, 3) }; // 10:00 in Jakarta, 03:00 UTC
  const ctx = await opened({ timeZone: "Asia/Jakarta", guards: { dailyLossLimit: 5 }, clock, rules: { stopLossPercent: 60 } });
  ctx.books[TRADER].positions = {};
  await ctx.engine.processTrader(TRADER);
  ctx.books[TRADER].positions = { BTC: btc("long", { mark: 50_000 }) };
  await ctx.engine.processTrader(TRADER); // the BTC position is still there, but now at a loss
  ctx.books[TRADER].positions = {};
  await ctx.engine.processTrader(TRADER); await ctx.engine.processTrader(TRADER); // closed at 50,000: a loss past 5
  ctx.books[TRADER].positions = { ETH: { ...btc(), symbol: "ETH", marketId: 32 } };
  await ctx.engine.processTrader(TRADER);
  assert.match((await ctx.engine.log(ctx.id))[0].detail, /shadow losses reached your 5 AUSD limit/);
  assert.equal(startOfDay(clock.t, "Asia/Jakarta"), Date.UTC(2026, 9, 14, 17));
  assert.equal(startOfDay(Date.UTC(2026, 9, 15, 23, 30), "America/New_York"), Date.UTC(2026, 9, 15, 4));
  assert.equal(startOfDay(Date.UTC(2026, 9, 15, 12), "Not/AZone"), Date.UTC(2026, 9, 15));
});

test("Following and unfollowing keeps the trader index in step", async () => {
  const { engine, copier, store, id } = setup();
  await engine.putCopier(copier);
  assert.deepEqual(await store.smembers(`copy:followers:${TRADER}`), [id]);
  await engine.putCopier({ ...copier, traders: {} });
  assert.deepEqual(await store.smembers(`copy:followers:${TRADER}`), []);
  await engine.sweep();
  assert.deepEqual(await engine.traders(), []);
});

test("A mark becomes a price the way the app parses it: eight places, toward zero", () => {
  assert.equal(priceFrom(60_000.129999, 1).raw, 600_001n);
  assert.equal(priceFrom(0.0247371, 6).raw, 24_737n);
  assert.equal(priceFrom(0, 1), null);
});

test("One engine at a time: the lease is taken once, lost on the clock, and never extended by a lapsed holder", async () => {
  const store = memoryStore();
  const clock = { t: 1_000_000 };
  const a = createLease({ store, now: () => clock.t, id: "a" });
  const b = createLease({ store, now: () => clock.t, id: "b" });
  assert.equal(await a.acquire(), true);
  assert.equal(await b.acquire(), false);
  assert.ok(a.holds());
  clock.t += 14_000;
  assert.equal(a.holds(), false, "within two seconds of lapsing, stop signing");
  assert.equal(await a.renew(), true);
  clock.t += 16_000;
  assert.equal(await b.acquire(), true, "a lapsed lease can be taken");
  assert.equal(await a.renew(), false, "the old holder cannot extend it");
  assert.equal(a.holds(), false);
  assert.equal(await a.release(), false, "nor release it");
  assert.ok(b.holds());
  assert.equal(await b.release(), true);
  assert.equal(await a.acquire(), true);
});

test("A book read off the contract: no account, unreadable, and positions as the app parses them", async () => {
  const markets = new Map([[16, openMarkets.get(16)]]);
  const reverted = Object.assign(new Error("execution reverted"), { code: 3 });
  assert.deepEqual((await readTrader({ accountByAddress: async () => { throw reverted; } }, markets, TRADER)).positions, {});
  assert.deepEqual(await readTrader({ accountByAddress: async () => { throw new Error("timeout"); } }, markets, TRADER), { unreadable: true });
  const chain = {
    accountByAddress: async () => ({ accountId: 9n, balanceCNS: 1_000_000_000n, positions: { bank1: 1n << 16n, bank2: 0n, bank3: 0n, bank4: 0n } }),
    openPosition: async () => ({ row: { lotLNS: 50_000n, pricePNS: 600_000n, depositCNS: 600_000_000n, pnlCNS: 5_000_000n, positionType: 0, entryBlock: 1n }, mark: 601_000n }),
  };
  const book = await readTrader(chain, markets, TRADER);
  assert.equal(book.accountId, "9");
  const p = book.positions.BTC;
  assert.deepEqual([p.side, p.size, p.entry, p.mark, p.collateral, p.leverage], ["long", 0.5, 60_000, 60_100, 600, 50]);
  assert.equal(book.portfolio, 1_000 + 600 + 5);
  const failing = { ...chain, openPosition: async () => { throw new Error("rpc"); } };
  assert.deepEqual(await readTrader(failing, markets, TRADER), { unreadable: true });
});

test("Reads of one trader never overlap, and an event mid-read gets a read of its own", async () => {
  const { engine, books, copier } = setup();
  await engine.putCopier(copier);
  let reads = 0, inside = 0, most = 0;
  const slow = createEngine({
    store: memoryStore(), markets: async () => openMarkets, logger: { warn() {} },
    readTrader: async (a) => { reads++; inside++; most = Math.max(most, inside); await new Promise((r) => setTimeout(r, 10)); inside--; return books[a]; },
  });
  await slow.putCopier(copier);
  await Promise.all([slow.processTrader(TRADER), slow.processTrader(TRADER), slow.processTrader(TRADER)]);
  assert.equal(most, 1);
  assert.equal(reads, 2, "the first read, then one more for the calls that landed during it");
});

test("A restart picks up where the last engine stopped: copies, baselines, today's losses and its pauses", async () => {
  const ctx = await opened({ rules: { stopLossPercent: 60 }, guards: { dailyLossLimit: 5 } });
  ctx.books[TRADER].positions = {};
  await ctx.engine.processTrader(TRADER); await ctx.engine.processTrader(TRADER); // closed at the entry: a small loss
  ctx.books[TRADER].positions = { BTC: btc() };
  await ctx.engine.processTrader(TRADER);
  const again = createEngine({
    store: ctx.store, markets: async () => openMarkets, now: () => ctx.clock.t, logger: { warn() {} },
    readTrader: async (address) => ctx.books[address],
  });
  assert.equal((await again.openCopies(ctx.id)).length, 1);
  ctx.books[TRADER].positions = { BTC: btc(), ETH: { ...btc(), symbol: "ETH", marketId: 32 } };
  const found = await again.processTrader(TRADER);
  assert.deepEqual(found.map((m) => m.kind), ["opened"], "BTC was already in the stored baseline");
  await ctx.store.set(`copy:pause:${ctx.id}`, "Today's copy losses reached your limit.");
  const third = createEngine({ store: ctx.store, markets: async () => openMarkets, readTrader: async (a) => ctx.books[a], logger: { warn() {} } });
  assert.equal(await third.paused(ctx.id), true);
});

test("Changes the API makes are read on the next refresh, and the engine never writes the copier", async () => {
  const { engine, store, copier, id, books } = setup();
  await engine.putCopier(copier);
  await engine.processTrader(TRADER);
  const stored = JSON.parse(await store.get(`copy:copier:${id}`));
  stored.traders[TRADER].rules.closeWithTrader = false;
  await store.set(`copy:copier:${id}`, JSON.stringify(stored));
  await store.sadd("copy:dirty", id);
  assert.equal(await engine.refresh(), 1);
  assert.deepEqual(await store.smembers("copy:dirty"), []);
  assert.equal((await engine.copier(id)).traders[TRADER].rules.closeWithTrader, false);
  books[TRADER].positions = { BTC: btc() };
  await engine.processTrader(TRADER);
  const before = await store.get(`copy:copier:${id}`);
  await engine.sweep();
  assert.equal(await store.get(`copy:copier:${id}`), before);

  await store.del(`copy:copier:${id}`);
  await store.sadd("copy:dirty", id);
  await engine.refresh();
  assert.equal(await engine.copier(id), null);
  assert.deepEqual(await engine.traders(), []);
});

test("Two traders opening at the same moment can't both take a copier's last slot", async () => {
  const OTHER = "0x1111111111111111111111111111111111111111";
  const store = memoryStore();
  const books = {
    [TRADER]: { accountId: "9", portfolio: 20_000, positions: {} },
    [OTHER]: { accountId: "10", portfolio: 20_000, positions: {} },
  };
  const engine = createEngine({
    store, markets: async () => openMarkets, logger: { warn() {} },
    readTrader: async (a) => { await new Promise((r) => setTimeout(r, Math.random() * 5)); return books[a]; },
  });
  const rules = { ...DEFAULT_RULES, maxChaseBps: 200 };
  await engine.putCopier({
    network: "testnet", address: ME, guards: { ...DEFAULT_GUARDS, maxOpenCopies: 1 },
    traders: { [TRADER]: { rules, since: 0 }, [OTHER]: { rules, since: 0 } },
  });
  await engine.sweep();
  books[TRADER].positions = { BTC: btc() };
  books[OTHER].positions = { ETH: { ...btc(), symbol: "ETH", marketId: 32 } };
  await Promise.all([engine.processTrader(TRADER), engine.processTrader(OTHER)]);
  const id = copierId("testnet", ME);
  assert.equal((await engine.openCopies(id)).length, 1);
  assert.equal((await engine.log(id)).filter((r) => r.kind === "skipped").length, 1);
});

test("A live copy is held as pending before it is signed, and the executor settles it", async () => {
  const intents = [];
  const executor = {
    quote: async (copier, market) => ({ mark: priceFrom(60_000, market.config.priceDecimals), free: 5_000_000_000n }),
    submit: async (intent) => { intents.push(intent); },
    close: async (intent) => { intents.push(intent); },
  };
  const store = memoryStore();
  const books = { [TRADER]: { accountId: "9", portfolio: 20_000, positions: {} } };
  const notes = [];
  const engine = createEngine({ store, markets: async () => openMarkets, executor, readTrader: async (a) => books[a], notify: async (c, r) => notes.push(r), logger: { warn() {} } });
  await engine.putCopier({ network: "testnet", address: ME, guards: DEFAULT_GUARDS, traders: { [TRADER]: { rules: { ...DEFAULT_RULES, mode: "live" }, since: 0 } } });
  await engine.processTrader(TRADER);
  books[TRADER].positions = { BTC: btc() };
  await engine.processTrader(TRADER);
  const id = copierId("testnet", ME);
  const [pending] = await engine.openCopies(id);
  assert.equal(pending.state, "pending");
  assert.equal(JSON.parse(await store.get(`copy:open:${id}`))[0].state, "pending", "written before the executor runs");
  await new Promise((r) => setImmediate(r));
  assert.equal(intents[0].action, "submit");
  await engine.settle(id, pending.id, { kind: "filled", entry: 60_010, row: { kind: "opened", detail: "Filled." } });
  assert.equal((await engine.openCopies(id))[0].state, "open");
  assert.equal(notes.at(-1).kind, "opened");
  books[TRADER].positions = {};
  await engine.processTrader(TRADER); await engine.processTrader(TRADER);
  assert.equal((await engine.openCopies(id))[0].state, "closing");
  await new Promise((r) => setImmediate(r));
  assert.equal(intents.at(-1).action, "close");
});

test("A copier trades on its own network's market, wherever its trader is read", async () => {
  const mainnetBtc = { ...openMarkets.get(16), id: 1 };
  const markets = async (network) => (network === "mainnet" ? new Map([[1, mainnetBtc]]) : openMarkets);
  const intents = [];
  const executor = {
    quote: async (copier, market) => ({ mark: priceFrom(60_000, market.config.priceDecimals), free: 5_000_000_000n }),
    submit: async (intent) => intents.push(intent), close: async () => {},
  };
  const store = memoryStore();
  const books = { [TRADER]: { accountId: "9", portfolio: 20_000, positions: {} } };
  const engine = createEngine({ store, markets, executor, readTrader: async (a) => books[a], logger: { warn() {} } });
  const live = { ...DEFAULT_RULES, mode: "live" };
  await engine.putCopier({ network: "testnet", address: ME, guards: DEFAULT_GUARDS, traders: { [TRADER]: { rules: live, since: 0 } } });
  await engine.putCopier({ network: "mainnet", address: ME, guards: DEFAULT_GUARDS, traders: { [TRADER]: { rules: { ...DEFAULT_RULES }, since: 0 } } });
  await engine.processTrader(TRADER);
  books[TRADER].positions = { BTC: { ...btc(), marketId: 1 } };
  await engine.processTrader(TRADER);
  await new Promise((r) => setImmediate(r));
  assert.equal(intents[0].market.id, 16, "the testnet copier's order goes to testnet's BTC");
  assert.equal((await engine.openCopies(copierId("testnet", ME)))[0].marketId, 16);
  assert.equal((await engine.openCopies(copierId("mainnet", ME)))[0].marketId, 1, "the mainnet copier's shadow uses mainnet's");
});

test("A close that lands while the copy's order is in flight waits for the fill, then closes it", async () => {
  const calls = [];
  let fill;
  const executor = {
    quote: async (copier, market) => ({ mark: priceFrom(60_000, market.config.priceDecimals), free: 5_000_000_000n }),
    submit: (intent) => { calls.push(["submit", intent.copy.id]); return new Promise((resolve) => { fill = resolve; }); },
    close: async (intent) => { calls.push(["close", intent.copy.id, intent.copy.sizeRaw, intent.reason]); },
  };
  const store = memoryStore();
  const books = { [TRADER]: { accountId: "9", portfolio: 20_000, positions: {} } };
  const engine = createEngine({ store, markets: async () => openMarkets, executor, readTrader: async (a) => books[a], logger: { warn() {} } });
  await engine.putCopier({ network: "testnet", address: ME, guards: DEFAULT_GUARDS, traders: { [TRADER]: { rules: { ...DEFAULT_RULES, mode: "live" }, since: 0 } } });
  const id = copierId("testnet", ME);
  await engine.processTrader(TRADER);
  books[TRADER].positions = { BTC: btc() };
  await engine.processTrader(TRADER);
  books[TRADER].positions = {};
  await engine.processTrader(TRADER); await engine.processTrader(TRADER); // the trader closed before the copy filled
  assert.deepEqual(calls.map((c) => c[0]), ["submit"], "no close is sent for an order still in flight");
  const [pending] = await engine.openCopies(id);
  assert.ok(pending.closeWhenFilled);
  await engine.settle(id, pending.id, { kind: "filled", entry: 60_010, sizeRaw: "7", row: { kind: "opened", detail: "Filled." } });
  await new Promise((r) => setImmediate(r));
  assert.deepEqual(calls.at(-1), ["close", pending.id, "7", "Closed with the trader."], "closed at once, for the size that filled");
  assert.equal((await engine.openCopies(id))[0].state, "closing");
  fill?.();
});
