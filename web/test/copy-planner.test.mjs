// CopyTradingTests.swift, case for case, against the same context fixture: the server's planner
// must agree with the app's on every copy, skip and stop.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  plan, moves, chaseBps, clampedInt, conviction, leverage, trigger, scaled, marketFromContext,
  decodeRules, decodeGuards, DEFAULT_RULES, DEFAULT_GUARDS, shadowFill, shadowPnL, shadowTriggered,
  SHADOW_SLIPPAGE_BPS, INT_LIMIT, sentence,
} from "../copyd/planner.mjs";

const context = JSON.parse(readFileSync(new URL("../../DeskKit/Tests/DeskFlowTests/Context-testnet.json", import.meta.url)));
const market = (id) => marketFromContext(context.markets.find((m) => m.id === id));

const btc = (side = "long", { entry = 60_000, leverage: lev = 7.6, collateral = 0 } = {}) =>
  ({ symbol: "BTC", side, size: 0.5, entry, mark: 60_000, collateral, leverage: lev });
const money = (whole) => BigInt(whole) * 1_000_000n;
const rules = (over = {}) => ({ ...DEFAULT_RULES, ...over });
const guards = (over = {}) => ({ ...DEFAULT_GUARDS, ...over });

function run(position, { rules: r = rules({ mode: "live" }), guards: g = guards(), free = money(1_000), open = [], today = 0n, portfolio = null } = {}) {
  return plan({
    position, traderPortfolio: portfolio, rules: r, guards: g, market: market(16),
    mark: scaled(600_000n, 1), free, openCopies: open, realisedToday: today,
  });
}
const skipOf = (result) => (result.ok ? null : result.skip);
const get = (result) => { assert.ok(result.ok, `expected a plan, got ${JSON.stringify(result.skip)}`); return result.plan; };

test("Entries, flips and exits are moves; resizing is not", () => {
  const long = btc();
  assert.deepEqual(moves({}, { BTC: long }), [{ kind: "opened", position: long }]);
  assert.deepEqual(moves({ BTC: long }, {}), [{ kind: "closed", position: long }]);
  const short = btc("short");
  assert.deepEqual(moves({ BTC: long }, { BTC: short }), [{ kind: "flipped", position: short }]);
  const bigger = { symbol: "BTC", side: "long", size: 2, entry: 61_000, mark: 0, collateral: 0, leverage: 3 };
  assert.deepEqual(moves({ BTC: long }, { BTC: bigger }), []);
});

test("A copy is sized from the copier's margin at the capped leverage, with venue-held protection", () => {
  const p = get(run(btc(), { rules: rules({ mode: "live", marginPerTrade: 10, maxLeverage: 5, stopLossPercent: 25, takeProfitPercent: 50 }) }));
  assert.equal(p.side, "long");
  assert.equal(p.draft.leverageHundredths, 500);
  assert.equal(p.draft.size.raw, 83n);
  assert.equal(p.draft.protection.stopLoss.raw, 570_000n);
  assert.equal(p.draft.protection.takeProfit.raw, 660_000n);
});

test("Fading takes the other side, with its stop above the mark", () => {
  const p = get(run(btc("long", { entry: 60_000 }), { rules: rules({ direction: "fade" }) }));
  assert.equal(p.side, "short");
  assert.equal(p.draft.side, "short");
  assert.equal(p.draft.protection.stopLoss.raw, 630_000n);
});

test("Conviction scales margin by the share of their account behind the trade, within half and double", () => {
  assert.equal(conviction(1_000, 10_000), 1);
  assert.equal(conviction(5_000, 10_000), 2);
  assert.equal(conviction(100, 10_000), 0.5);
  assert.equal(conviction(100, null), 1);
  const heavy = get(run(btc("long", { collateral: 3_000 }), { rules: rules({ sizing: "conviction", marginPerTrade: 10 }), portfolio: 10_000 }));
  assert.equal(heavy.margin, 20);
});

test("The exposure guard trims a copy to the market's room and refuses one that would offset another", () => {
  const open = [{ symbol: "BTC", side: "long", notional: 50 }];
  const trimmed = get(run(btc(), { rules: rules({ marginPerTrade: 10, maxLeverage: 5 }), guards: guards({ maxMarketExposure: 80 }), open }));
  assert.equal(trimmed.margin, 6);
  assert.deepEqual(skipOf(run(btc(), { guards: guards({ maxMarketExposure: 52 }), open })), { kind: "exposureLimit", limit: 52 });
  assert.deepEqual(skipOf(run(btc("short"), { open })), { kind: "offsetsOpenCopy" });
});

test("What is left of the chase allowance bounds the order's slippage", () => {
  const r = rules({ maxChaseBps: 100 });
  assert.equal(get(run(btc("long", { entry: 59_700 }), { rules: r })).draft.slippageBps, 50);
  assert.equal(get(run(btc("long", { entry: 59_600 }), { rules: r })).draft.slippageBps, 33);
  assert.deepEqual(skipOf(run(btc("long", { entry: 59_000 }), { rules: r })), { kind: "chased", bps: 169 });
  assert.equal(chaseBps(59_000, 60_000, "short"), -169);
});

test("A figure the server should never send is clamped, not trapped", () => {
  assert.equal(chaseBps(1e-300, 60_000, "long"), INT_LIMIT);
  assert.equal(chaseBps(1e-300, 60_000, "short"), -INT_LIMIT);
  assert.equal(chaseBps(NaN, 60_000, "long"), 0);
  assert.equal(chaseBps(60_000, Infinity, "long"), 0);
  assert.equal(chaseBps(Infinity, 60_000, "long"), 0);
  assert.equal(clampedInt(NaN), 0);
  assert.equal(clampedInt(-Infinity), -INT_LIMIT);
  assert.equal(clampedInt(12.4), 12);
});

test("A short's stop sits above the mark and every trigger rounds away from firing early", () => {
  const mark = scaled(600_001n, 1);
  assert.equal(trigger(mark, "long", -25, 5).raw, 570_000n);
  assert.equal(trigger(mark, "short", -25, 5).raw, 630_002n);
  assert.equal(trigger(mark, "long", -600, 5), null);
});

test("Guards turn a copy into a stated skip", () => {
  const g = guards({ maxOpenCopies: 3, dailyLossLimit: 50 });
  const three = Array.from({ length: 3 }, () => ({ symbol: "ETH", side: "long", notional: 1 }));
  assert.deepEqual(skipOf(run(btc(), { guards: g, open: three })), { kind: "openCopiesLimit", limit: 3 });
  assert.deepEqual(skipOf(run(btc(), { guards: g, today: -50_000_000n })), { kind: "dailyLossLimit", limit: 50 });
  assert.deepEqual(skipOf(run(btc(), { free: money(5) })), { kind: "insufficientBalance" });
  assert.equal(skipOf(run(btc(), { guards: g, today: -49_000_000n })), null);
});

test("Leverage follows the trader within both the copier's and the market's cap", () => {
  const m = market(16);
  assert.equal(leverage(btc("long", { leverage: 2.4 }), rules({ maxLeverage: 5 }), m), 2);
  assert.equal(leverage(btc("long", { leverage: 40 }), rules({ maxLeverage: 50 }), m), 15);
  assert.equal(leverage(btc("long", { leverage: null }), rules(), m), 1);
});

test("A copy has to afford its fee, not only its margin", () => {
  const r = rules({ mode: "live", marginPerTrade: 10, maxLeverage: 5 });
  assert.deepEqual(skipOf(run(btc(), { rules: r, free: money(10) })), { kind: "insufficientBalance" });
  assert.equal(get(run(btc(), { rules: r, free: 10_017_250n })).margin, 10);
});

test("Price protection measures the trader's own venue, not the one the copy fills on", () => {
  const theirs = { symbol: "BTC", side: "long", size: 0.5, entry: 95_000, mark: 95_300, collateral: 0, leverage: 5 };
  assert.deepEqual(skipOf(run(theirs, { rules: rules({ mode: "live", maxChaseBps: 25 }) })), { kind: "chased", bps: 32 });
  assert.ok(run(theirs, { rules: rules({ mode: "live", maxChaseBps: 50 }) }).ok);
});

const fillFor = (r) => shadowFill({ mark: 60_000, plan: get(run(btc(), { rules: r })), takerFeeMicros: 345, maintenanceMarginFraction: 2_500, rules: r });

test("A shadow fill pays slippage and its fee, and fires the stop a live copy would", () => {
  const fill = fillFor(rules({ marginPerTrade: 10, maxLeverage: 5, stopLossPercent: 25, takeProfitPercent: 50 }));
  assert.ok(Math.abs(fill.entry - 60_018) < 0.001);
  assert.ok(Math.abs(fill.fees - 0.01725) < 0.00001);
  assert.ok(shadowPnL(fill, 60_000, 345) < 0);
  const exit = 60_000 * (1 - SHADOW_SLIPPAGE_BPS / 10_000);
  const expected = (exit - fill.entry) * fill.units - fill.fees - exit * fill.units * 345 / 1_000_000;
  assert.ok(Math.abs(shadowPnL(fill, 60_000, 345) - expected) < 1e-9);
  assert.ok(shadowPnL(fill, 60_000, 345) < shadowPnL(fill, 60_000, 0));
  assert.equal(shadowTriggered(fill, 57_000).exit, "stop");
  assert.equal(shadowTriggered(fill, 66_100).exit, "take");
  assert.equal(shadowTriggered(fill, 60_500), null);
  assert.equal(shadowPnL(fill, 1, 345), -10);
});

test("A shadow copy is liquidated where the venue would liquidate it, and cannot recover", () => {
  const fill = fillFor(rules({ marginPerTrade: 10, maxLeverage: 5, stopLossPercent: null, takeProfitPercent: null }));
  assert.ok(Math.abs(fill.liquidation - fill.entry * 0.84) < 1);
  assert.equal(shadowTriggered(fill, fill.liquidation - 1).exit, "liquidation");
  assert.equal(shadowTriggered(fill, fill.liquidation + 1), null);
  assert.equal(shadowPnL(fill, fill.liquidation, 345), -10);
  assert.equal(shadowPnL(fill, fill.liquidation - 5_000, 345), -10);
  assert.ok(shadowPnL(fill, fill.entry, 345) < 0);
});

test("A gap through a stop costs the gap, and an overshot take profit does not pay for it", () => {
  const fill = fillFor(rules({ marginPerTrade: 10, maxLeverage: 5, stopLossPercent: 25, takeProfitPercent: 50 }));
  const gapped = shadowTriggered(fill, fill.stop - 50);
  assert.equal(gapped.exit, "stop");
  assert.equal(gapped.price, fill.stop - 50);
  assert.equal(shadowTriggered(fill, fill.take + 5_000).price, fill.take);
});

test("Rules saved before modes existed stay live, followed and fixed", () => {
  const r = decodeRules({ marginPerTrade: 10, maxLeverage: 5, stopLossPercent: 25, closeWithTrader: true, maxChaseBps: 100 });
  assert.ok(r.mode === "live" && r.direction === "follow" && r.sizing === "fixed");
  assert.equal(decodeGuards({ maxOpenCopies: 3, dailyLossLimit: 50 }).maxMarketExposure, 250);
});

test("A skip reads the way the app writes it", () => {
  const r = rules({ mode: "live" });
  assert.equal(sentence(run(btc("long", { entry: 59_000 }), { rules: r }), r), "Price had already moved 1.69% against the copy since their entry.");
  assert.equal(sentence({ ok: false, skip: { kind: "dailyLossLimit", limit: 50 } }, r), "Today's copy losses reached your 50 AUSD limit, so auto-copy paused.");
});
