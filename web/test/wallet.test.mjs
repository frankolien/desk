import assert from "node:assert/strict";
import { test } from "node:test";

import { describeWallet } from "../api/_wallet.mjs";

const FROGE = "0xAbCd000000000000000000000000000000000001";

test("a wallet's holdings sort by value, drop risk tokens, and pick out the token in view", () => {
  const rows = [{ tokenAssets: [
    { tokenContractAddress: FROGE, symbol: "FROGE", balance: "71850000", tokenPrice: "0.0013", isRiskToken: false },
    { tokenContractAddress: "0x2", symbol: "USDC", balance: "1200", tokenPrice: "1", isRiskToken: false },
    { tokenContractAddress: "0x3", symbol: "SCAM", balance: "9999999", tokenPrice: "5", isRiskToken: true },
    { tokenContractAddress: "0x4", symbol: "DUST", balance: "0", tokenPrice: "1" },
    { tokenContractAddress: "0x5", symbol: "NOPRICE", balance: "3", tokenPrice: "" },
  ] }];
  const wallet = describeWallet(rows, FROGE.toLowerCase());
  assert.deepEqual(wallet.holdings.map((row) => row.symbol), ["FROGE", "USDC", "NOPRICE"]);
  assert.equal(wallet.held.balance, 71_850_000);
  assert.ok(Math.abs(wallet.held.value - 93_405) < 1e-6);
  assert.ok(Math.abs(wallet.portfolio - 94_605) < 1e-6);
  assert.deepEqual(wallet.chains, [{ chainIndex: "", chain: null, value: 94_605 }]);
});

test("an empty or unpriced wallet has no portfolio figure rather than a zero one", () => {
  assert.deepEqual(describeWallet([], "0x1"), { portfolio: null, chains: [], held: null, holdings: [] });
  const unpriced = describeWallet([{ tokenAssets: [{ tokenContractAddress: "0x1", symbol: "X", balance: "5" }] }], "0x1");
  assert.equal(unpriced.portfolio, null);
  assert.deepEqual(unpriced.held, { balance: 5, value: null });
});
