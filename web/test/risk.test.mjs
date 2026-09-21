import assert from "node:assert/strict";
import { test } from "node:test";

import { assessToken, looksLikePool, okxRiskLevel } from "../api/_risk.mjs";

const NOW = 1_800_000_000_000;
const holder = (address, percent, amount = percent * 1e6) => ({ address, amount, percent });

test("no inputs is unchecked, not low", () => {
  assert.equal(assessToken({ now: NOW }).level, "unchecked");
});

test("a thin pool alone is high risk; light liquidity is caution", () => {
  assert.equal(assessToken({ liquidity: 8_200, now: NOW }).level, "high");
  assert.equal(assessToken({ liquidity: 8_200, now: NOW }).reasons[0].text, "Liquidity is thin: $8.2K in pool");
  assert.equal(assessToken({ liquidity: 25_000, now: NOW }).level, "caution");
  assert.equal(assessToken({ liquidity: 120_000, now: NOW }).level, "low");
});

test("the pool is left out of the concentration count", () => {
  const liquidity = 200_000;
  const price = 0.002;
  const pool = holder("0xpool", 61, (liquidity / 2) / price);
  assert.equal(looksLikePool(pool, { liquidity, price }), true);
  const people = [holder("0xa", 4), holder("0xb", 3), holder("0xc", 2)];
  const withPool = assessToken({ liquidity, price, holders: [pool, ...people], now: NOW });
  assert.equal(withPool.level, "low");
  const noPool = assessToken({ liquidity, price, holders: [holder("0xwhale", 61, 9e6), ...people], now: NOW });
  assert.equal(noPool.level, "high");
  assert.equal(noPool.reasons[0].text, "Top 10 wallets hold 70% of supply");
});

test("age, creator share, sells and flags add up with the number shown", () => {
  const trades = Array.from({ length: 40 }, () => ({ type: "buy" }));
  const risk = assessToken({
    liquidity: 60_000, holders: [holder("0xdev", 18), holder("0xa", 5)], creator: "0xDEV",
    createdAt: NOW / 1000 - 3 * 3600, trades, communityRecognized: false, graduated: false, now: NOW,
  });
  assert.equal(risk.level, "high");
  assert.deepEqual(risk.reasons.map((r) => r.text), [
    "Creator wallet holds 18% of supply",
    "Launched 3 hours ago",
    "No sells seen in the last 40 trades",
    "Not recognized by the community yet",
    "Still on the bonding curve",
  ]);
  assert.equal(assessToken({ riskFlag: "high", now: NOW }).reasons[0].severity, "high");
  assert.equal(assessToken({ riskFlag: "medium", now: NOW }).level, "caution");
  assert.equal(okxRiskLevel("1"), null);
  assert.equal(okxRiskLevel("2"), "medium");
  assert.equal(okxRiskLevel("3"), "high");
  assert.equal(assessToken({ createdAt: NOW / 1000 - 600, now: NOW }).reasons[0].text, "Launched 10 minutes ago");
});

test("positive facts are facts, not safety", () => {
  const risk = assessToken({ liquidity: 300_000, marketCap: 2_400_000, graduated: true, communityRecognized: true, createdAt: NOW / 1000 - 40 * 86_400, trades: [...Array(30)].map((_, i) => ({ type: i % 3 ? "buy" : "sell" })), now: NOW });
  assert.equal(risk.level, "low");
  assert.deepEqual(risk.facts.map((f) => f.text), [
    "Launched 40 days ago", "10 of the last 30 trades were sells", "Recognized by the community", "Graduated to a pool", "Market cap $2.4M",
  ]);
});
