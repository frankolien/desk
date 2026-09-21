// node --test web/test/markets.test.mjs
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

test("candles come back ascending, cached a minute, and only for known assets", async () => {
  let calls = 0;
  const fetchImpl = async (url) => {
    calls += 1;
    assert.match(url, /instId=BTC-USDT&bar=15m/);
    return { ok: true, json: async () => ({ code: "0", data: [["120000", "2", "3", "1", "2.5", "9"], ["60000", "1", "2", "0.5", "2", "8"]] }) };
  };
  let clock = 1_000_000;
  const source = createMarkets({ fetchImpl, now: () => clock });
  const rows = await source.candles("btc", "15m");
  assert.deepEqual(rows.map((r) => r.time), [60, 120]);
  assert.equal(rows[0].close, 2);
  await source.candles("BTC", "15m");
  assert.equal(calls, 1);
  clock += 61_000;
  await source.candles("BTC", "15m");
  assert.equal(calls, 2);
  assert.equal(await source.candles("DOGE", "15m"), null);
  assert.equal(await source.candles("BTC", "2m"), null);
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
