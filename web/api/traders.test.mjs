// node --test web/api/traders.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import {
  createHandler, describePosition, formatFixed, perpIdsFromBitmap, rankTraders,
} from "./traders.mjs";

const BTC = { id: 1, name: "BTC", config: { is_open: true, price_decimals: 1, size_decimals: 5 } };
const ETH = { id: 20, name: "ETH", config: { is_open: true, price_decimals: 2, size_decimals: 0 } };
const ALICE = "0x95D2602d30DA1179fd13274839e60345857ca648";

const row = (overrides) => ({
  accountId: 3901n, nextNodeId: 0n, positionType: 0, depositCNS: 2_309_980_000n,
  pricePNS: 184_799n, lotLNS: 5n, entryBlock: 90_179_398n, pnlCNS: 3_047_920_000n, ...overrides,
});

function recorder() {
  const out = { status: null, body: null, headers: {} };
  return {
    status(code) { out.status = code; return this; },
    json(value) { out.body = value; return out; },
    setHeader(key, value) { out.headers[key] = value; },
  };
}

const context = async () => ({ ok: true, json: async () => ({ markets: [BTC, ETH, { id: 99, name: "OLD", config: { is_open: false } }] }) });

test("fixed-point values keep their sign and trim zeros", () => {
  assert.equal(formatFixed(765_192n, 1), "76519.2");
  assert.equal(formatFixed(-861_914n, 6, 2), "-0.86");
  assert.equal(formatFixed(1n, 5), "0.00001");
  assert.equal(formatFixed(100_000_000n, 6, 2), "100");
});

test("the position bitmap names every perp across banks", () => {
  assert.deepEqual(perpIdsFromBitmap({ bank1: 2n, bank2: 0n, bank3: 0n, bank4: 0n }), [1]);
  assert.deepEqual(perpIdsFromBitmap({ bank1: (1n << 20n) | (1n << 90n), bank2: 1n }), [20, 90, 256]);
  assert.deepEqual(perpIdsFromBitmap({}), []);
});

test("a position reads as side, leverage, value and PnL at its market's decimals", () => {
  // A live ETH long: 5 ETH from 1,847.99 on 2,309.98 AUSD, marked at 2,447.22.
  const described = describePosition(row(), 244_722n, ETH);
  assert.equal(described.side, "long");
  assert.equal(described.entry, "1847.99");
  assert.equal(described.value, "12236.1");
  assert.equal(described.leverage, 4);
  assert.equal(described.pnlPercent, 131.94);
  assert.equal(describePosition(row({ positionType: 1 }), 244_722n, ETH).side, "short");
  // BTC carries six decimals of price and size combined, matching collateral exactly.
  const btc = describePosition(row({ pricePNS: 697_422n, lotLNS: 179n, depositCNS: 41_612_829n }), 765_337n, BTC);
  assert.equal(btc.size, "0.00179");
  assert.equal(btc.leverage, 3);
});

test("traders rank by total open PnL across their positions", () => {
  const entries = [
    { accountId: 1n, raw: row({ pnlCNS: 100n }), described: { value: "10" } },
    { accountId: 2n, raw: row({ pnlCNS: 500n }), described: { value: "10" } },
    { accountId: 1n, raw: row({ pnlCNS: 450n }), described: { value: "10" } },
    { accountId: 3n, raw: row({ pnlCNS: -5n }), described: { value: "10" } },
  ];
  const ranked = rankTraders(entries, 2);
  assert.deepEqual(ranked.map((entry) => [entry.accountId, entry.pnl]), [[1n, 550n], [2n, 500n]]);
  assert.equal(ranked[0].positions.length, 2);
});

test("top pages through every open market and resolves addresses", async () => {
  const pages = [];
  const chain = {
    async allPositions(market) {
      pages.push(market.name);
      return market.id === 20 ? [{ row: row(), mark: 244_722n }] : [];
    },
    async accountById(id) { return { accountId: id, accountAddr: ALICE }; },
  };
  const result = await createHandler({ chain, fetchImpl: context })({ method: "GET", query: { view: "top" } }, recorder());
  assert.equal(result.status, 200);
  assert.deepEqual(pages.sort(), ["BTC", "ETH"]);
  assert.equal(result.body.traders[0].address, ALICE);
  assert.equal(result.body.traders[0].pnl, "3047.92");
  assert.match(result.headers["Cache-Control"], /s-maxage=60/);
});

test("a followed wallet shows its live positions, and an unknown one shows none", async () => {
  const chain = {
    async accountByAddress(address) {
      return address === ALICE
        ? { accountId: 3901n, accountAddr: ALICE, balanceCNS: 1_284_340_000n, positions: { bank1: 1n << 20n } }
        : null;
    },
    async position(perpId) { return perpId === 20 ? { row: row(), mark: 244_722n } : null; },
  };
  const other = "0x1111111111111111111111111111111111111111";
  const result = await createHandler({ chain, fetchImpl: context })(
    { method: "GET", query: { view: "following", addresses: `${ALICE},${other}` } }, recorder());
  assert.equal(result.status, 200);
  assert.equal(result.body.traders[0].balance, "1284.34");
  assert.equal(result.body.traders[0].positions[0].market, "ETH");
  assert.deepEqual(result.body.traders[1], { address: other, accountId: null, positions: [] });
});

test("bad input and outages are refused plainly", async () => {
  const handler = createHandler({ chain: {}, fetchImpl: context });
  assert.equal((await handler({ method: "GET", query: { view: "following", addresses: "0x12" } }, recorder())).status, 400);
  const many = Array.from({ length: 21 }, () => ALICE).join(",");
  assert.equal((await handler({ method: "GET", query: { view: "following", addresses: many } }, recorder())).status, 400);
  assert.equal((await handler({ method: "POST", query: {} }, recorder())).status, 405);
  const broken = createHandler({ chain: { allPositions: async () => { throw new Error("rpc"); } }, fetchImpl: context });
  const down = await broken({ method: "GET", query: { view: "top" } }, recorder());
  assert.equal(down.status, 502);
  assert.doesNotMatch(JSON.stringify(down.body), /rpc/);
});
