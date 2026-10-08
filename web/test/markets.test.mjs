import assert from "node:assert/strict";
import { test } from "node:test";

import { createMarkets, describeMarket, describeMarkets } from "../api/_markets.mjs";
import { createHandler } from "../api/v1.mjs";
import { memoryStore } from "../api/_store.mjs";

const BTC = {
  id: 1, name: "BTC", size_units: "BTC", funding_interval_sec: 2580,
  config: { is_open: true, price_decimals: 1, size_decimals: 5, initial_margin: 1500, maintenance_margin: 2500, maker_fee: 90, taker_fee: 690 },
  state: { mrk: 812940, prv: 803609, dva: "40469790813411", oi: 531756, tvl: "163503172071" },
  funding: { rate: 40 },
};
const CLOSED = { ...BTC, id: 2, name: "OLD", config: { ...BTC.config, is_open: false } };

test("a market is read at its own scales", () => {
  const row = describeMarket(BTC);
  assert.equal(row.mark, 81294);
  assert.equal(row.prev, 80360.9);
  assert.ok(Math.abs(row.change - 0.01161) < 0.0001);
  assert.ok(Math.abs(row.volume24h - 40469790.81) < 0.01);
  assert.ok(Math.abs(row.openInterest - 5.31756 * 81294) < 0.01);
  assert.ok(Math.abs(row.tvl - 163503.17) < 0.01);
  assert.equal(row.fundingRate, 0.00004);
  assert.equal(row.maxLeverage, 15);
  assert.equal(row.takerFee, 690);
  assert.equal(row.maintenanceMargin, 2500);
});

test("closed markets are left out and the collateral is named", () => {
  const out = describeMarkets({ markets: [BTC, CLOSED], tokens: [{ symbol: "AUSD" }] });
  assert.deepEqual(out.markets.map((m) => m.name), ["BTC"]);
  assert.equal(out.collateral, "AUSD");
});

test("candles come from Perpl at the market's scales, ascending, cached a minute, and only for listed markets", async () => {
  let candleCalls = 0;
  const fetchImpl = async (url) => {
    if (url.includes("/pub/context")) return { ok: true, json: async () => ({ markets: [BTC], tokens: [{ symbol: "AUSD" }] }) };
    candleCalls += 1;
    assert.match(url, /market-data\/1\/candles\/900\/\d+-\d+$/);
    return { ok: true, json: async () => ({ d: [{ t: 120000, o: 20, h: 30, l: 10, c: 25, v: "9000000", n: 3 }, { t: 60000, o: 10, h: 20, l: 5, c: 20, v: "8000000", n: 2 }] }) };
  };
  let clock = 1_790_000_000_000;
  const source = createMarkets({ fetchImpl, now: () => clock });
  const rows = await source.candles("btc", "15m");
  assert.deepEqual(rows.map((r) => r.time), [60, 120]);
  assert.equal(rows[0].close, 2);
  assert.equal(rows[1].volume, 9);
  await source.candles("BTC", "15m");
  assert.equal(candleCalls, 1);
  clock += 61_000;
  await source.candles("BTC", "15m");
  assert.equal(candleCalls, 2);
  assert.equal(await source.candles("DOGE", "15m"), null);
  assert.equal(await source.candles("BTC", "2m"), null);
  assert.equal(await source.hasInstrument("btc"), true);
  assert.equal(await source.hasInstrument("DOGE"), false);
});

function recorder() {
  const out = { status: 200, body: null, headers: {} };
  const res = {
    status(code) { out.status = code; return this; },
    end(value) { out.body = value == null ? null : JSON.parse(value); return out; },
    json(value) { out.body = value; return out; },
    setHeader(key, value) { out.headers[key] = value; },
  };
  return { out, res };
}

async function call(handler, path, query = {}) {
  const { out, res } = recorder();
  await handler({ method: "GET", url: `/api/v1?path=${path}`, query: { path, ...query }, headers: {} }, res);
  return out;
}

test("the public API serves markets and candles", async () => {
  const markets = {
    context: async () => ({ collateral: "AUSD", markets: [describeMarket(BTC)] }),
    candles: async (name, bar) => [{ time: 60, open: 1, high: 2, low: 0.5, close: 2, volume: 8, bar, name }],
    hasInstrument: (name) => name.toUpperCase() === "BTC",
  };
  const handler = createHandler({ store: memoryStore(), markets, now: () => Date.UTC(2026, 8, 21) });

  const list = await call(handler, "markets");
  assert.equal(list.status, 200);
  assert.equal(list.body.data.markets[0].name, "BTC");
  assert.equal(list.body.data.collateral, "AUSD");
  assert.match(list.headers["Cache-Control"], /s-maxage=10/);

  const candles = await call(handler, "markets/BTC/candles", { bar: "1H" });
  assert.equal(candles.status, 200);
  assert.equal(candles.body.data.market, "BTC");
  assert.equal(candles.body.data.candles[0].bar, "1H");

  const unknown = await call(handler, "markets/DOGE/candles");
  assert.equal(unknown.status, 404);
  const badBar = await call(handler, "markets/BTC/candles", { bar: "2m" });
  assert.equal(badBar.status, 400);
});

test("the head and block time come from the stamps, and marks are read off the contract", async () => {
  const context = {
    chain: { gas: { at: { b: 1000, t: 1_000_300 } } },
    markets: [{ ...BTC, config: { ...BTC.config, at: { b: 0, t: 700_000 } }, state: { ...BTC.state, at: { b: 1000, t: 1_000_000 } } }],
    tokens: [{ symbol: "AUSD" }],
  };
  const out = describeMarkets(context);
  assert.deepEqual(out.head, { block: 1000, time: 1_000_300, blockMs: 300 });

  const fetchImpl = async () => ({ ok: true, json: async () => context });
  const source = createMarkets({ fetchImpl, now: () => 5, readMark: async (id) => (id === 1 ? 812345 : null) });
  const marks = await source.marks();
  assert.deepEqual(marks, { at: 5, marks: { BTC: 81234.5 } });

  const markets = { context: async () => out, marks: () => source.marks(), candles: async () => [], hasInstrument: () => false };
  const handler = createHandler({ store: memoryStore(), markets, now: () => 5 });
  const live = await call(handler, "markets/marks");
  assert.equal(live.status, 200);
  assert.equal(live.body.data.marks.BTC, 81234.5);
  assert.match(live.headers["Cache-Control"], /s-maxage=2/);
});

test("weeks are folded from days, Monday to Monday", async () => {
  const { weekly, weekStart } = await import("../api/_markets.mjs");
  assert.equal(weekStart(345_600), 345_600);
  assert.equal(weekStart(345_600 + 6 * 86_400 + 1), 345_600);
  assert.equal(weekStart(345_600 + 7 * 86_400), 345_600 + 604_800);
  const day = (i, o, h, l, c, v) => ({ time: 345_600 + i * 86_400, open: o, high: h, low: l, close: c, volume: v });
  const weeks = weekly([day(8, 5, 6, 4, 5, 1), day(0, 1, 3, 1, 2, 1), day(1, 2, 9, 0.5, 4, 2), day(7, 4, 5, 3, 5, 1)]);
  assert.deepEqual(weeks, [
    { time: 345_600, open: 1, high: 9, low: 0.5, close: 4, volume: 3 },
    { time: 345_600 + 604_800, open: 4, high: 6, low: 3, close: 5, volume: 2 },
  ]);
  const fetchImpl = async (url) => {
    if (url.includes("/pub/context")) return { ok: true, json: async () => ({ markets: [BTC], tokens: [{ symbol: "AUSD" }] }) };
    assert.match(url, /candles\/86400\//);
    return { ok: true, json: async () => ({ d: Array.from({ length: 21 }, (_, i) => ({ t: (345_600 + i * 86_400) * 1000, o: 10, h: 12, l: 9, c: 11, v: "1000000" })) }) };
  };
  const rows = await createMarkets({ fetchImpl, now: () => 1_790_000_000_000 }).candles("BTC", "1W");
  assert.equal(rows.length, 3);
  // The fixture market prices to one decimal, so the raw tens read as units.
  assert.deepEqual(rows[0], { time: 345_600, open: 1, high: 1.2, low: 0.9, close: 1.1, volume: 7 });
});

test("candles stop at 300, the newest ones, when Perpl answers one more", async () => {
  const fetchImpl = async (url) => {
    if (url.includes("/pub/context")) return { ok: true, json: async () => ({ markets: [BTC], tokens: [{ symbol: "AUSD" }] }) };
    return { ok: true, json: async () => ({ d: Array.from({ length: 301 }, (_, i) => ({ t: (i + 1) * 60_000, o: 10, h: 10, l: 10, c: 10, v: "1" })) }) };
  };
  const rows = await createMarkets({ fetchImpl, now: () => 1_790_000_000_000 }).candles("BTC", "1m");
  assert.equal(rows.length, 300);
  assert.deepEqual([rows[0].time, rows[299].time], [120, 18_060]);
});
