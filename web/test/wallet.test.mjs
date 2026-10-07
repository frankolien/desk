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

test("what the desk holds joins the holdings as its own AUSD row, and the chain settles the wallet's AUSD", async () => {
  const { describeDesk, withDesk, MONAD_AUSD } = await import("../api/_wallet.mjs");
  const rows = [{ tokenAssets: [
    { chainIndex: "143", tokenContractAddress: "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", symbol: "MON", balance: "2140", tokenPrice: "0.0271" },
    { chainIndex: "143", tokenContractAddress: MONAD_AUSD, symbol: "AUSD", balance: "0.007268", tokenPrice: "0.9995" },
    { chainIndex: "1", tokenContractAddress: "0x9", symbol: "WETH", balance: "1", tokenPrice: "2600" },
  ] }];
  // The desk read as the exchange contract returns it: six-decimal collateral, and the wallet's
  // own balance has moved on since the index last looked.
  const desk = describeDesk({ accountId: 1922n, balanceCNS: 8_839_140_196n, lockedBalanceCNS: 250_000_000n }, 12_000_000n);
  assert.deepEqual(desk, { account: "1922", collateral: 8839.140196, locked: 250, walletAusd: 12 });

  const wallet = withDesk(describeWallet(rows, ""), desk);
  assert.deepEqual(wallet.holdings.map((row) => [row.symbol, row.balance, Boolean(row.desk)]),
    [["AUSD", 8839.140196, true], ["WETH", 1, false], ["MON", 2140, false], ["AUSD", 12, false]]);
  const expected = 2600 + 2140 * 0.0271 + (8839.140196 + 12) * 0.9995;
  assert.ok(Math.abs(wallet.portfolio - expected) < 1e-6, `${wallet.portfolio} vs ${expected}`);
  assert.deepEqual(wallet.chains.map((chain) => chain.chainIndex), ["143", "1"]);
  assert.ok(Math.abs(wallet.chains[0].value - (expected - 2600)) < 1e-6);
  assert.equal(wallet.desk, desk);
});

test("a wallet with no desk is left as the index described it, and a zero chain balance drops a stale AUSD row", async () => {
  const { describeDesk, withDesk, MONAD_AUSD } = await import("../api/_wallet.mjs");
  const rows = [{ tokenAssets: [
    { chainIndex: "143", tokenContractAddress: "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", symbol: "MON", balance: "10", tokenPrice: "0.03" },
    { chainIndex: "143", tokenContractAddress: MONAD_AUSD, symbol: "AUSD", balance: "5", tokenPrice: "1" },
  ] }];
  const unknown = withDesk(describeWallet(rows, ""), null);
  assert.deepEqual(unknown.holdings.map((row) => row.symbol), ["AUSD", "MON"]);
  assert.equal(unknown.desk, null);

  const none = describeDesk(null, 0n);
  assert.deepEqual(none, { account: null, collateral: null, locked: null, walletAusd: 0 });
  const settled = withDesk(describeWallet(rows, ""), none);
  assert.deepEqual(settled.holdings.map((row) => row.symbol), ["MON"]);
  assert.ok(Math.abs(settled.portfolio - 0.3) < 1e-9);
  assert.deepEqual(settled.chains.map((chain) => [chain.chainIndex, chain.chain]), [["143", "Monad"]]);
  assert.ok(Math.abs(settled.chains[0].value - 0.3) < 1e-9);

  // An empty index answer still shows the desk, priced at par.
  const bare = withDesk({ portfolio: null, chains: [], held: null, holdings: [] }, describeDesk({ accountId: 7n, balanceCNS: 1_500_000n, lockedBalanceCNS: 0n }, 0n));
  assert.deepEqual(bare.holdings.map((row) => [row.symbol, row.value, row.desk]), [["AUSD", 1.5, true]]);
  assert.equal(bare.portfolio, 1.5);
  assert.deepEqual(bare.chains, [{ chainIndex: "143", chain: "Monad", value: 1.5 }]);
});
