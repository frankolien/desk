// node --test web/test/solana.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import { parseSubscription } from "../api/alerts.mjs";
import { indexSolanaWallet, isSolanaAddress, solanaMetaReader, solanaMovement } from "../api/_solana.mjs";
import { memoryStore } from "../api/_store.mjs";
import { walletPayload } from "../api/_watch.mjs";

const WALLET = "Fwin1gWxbFAyb1MNPqwETyb4g8oaA2Hdg1ypyxSUsyjE";
const BONK = "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263";
const USDC = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
const OTHER = "9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin";

/// A transaction the way the RPC returns it with jsonParsed: the wallet's own token
/// accounts before and after, lamports before and after, and the fee it paid.
function transaction({ slot = 383_000_000, blockTime = 1_789_990_473, fee = 5005, lamports = [1_000_000_000n, 1_000_000_000n - 5005n], pre = [], post = [], signer = true, err = null } = {}) {
  const balance = (mint, amount, decimals, owner = WALLET) => ({ mint, owner, uiTokenAmount: { amount: String(amount), decimals } });
  return {
    slot, blockTime,
    transaction: { message: { accountKeys: [{ pubkey: WALLET, signer, writable: true }, { pubkey: OTHER, signer: false, writable: true }] } },
    meta: {
      err, fee, preBalances: lamports.map(String).map(Number).slice(0, 1).concat([1]), postBalances: [Number(lamports[1]), 1],
      preTokenBalances: pre.map((row) => balance(...row)), postTokenBalances: post.map((row) => balance(...row)),
    },
  };
}

test("a base58 address of the right length is Solana's, an EVM one is not", () => {
  assert.equal(isSolanaAddress(WALLET), true);
  assert.equal(isSolanaAddress("0x52ac212e7187a799a7382c7a768cb35b72a3e20a"), false);
  assert.equal(isSolanaAddress("0OIl" + WALLET.slice(4)), false);
});

test("a token out for USDC in is a sell, and stablecoin legs are not positions", () => {
  const tx = transaction({ pre: [[USDC, 181_946, 6], [BONK, 190_444_222_564, 5]], post: [[USDC, 183_614, 6], [BONK, 190_394_222_564, 5]] });
  const movement = solanaMovement(WALLET, "sig1", tx);
  assert.equal(movement.kind, "sell");
  assert.deepEqual(movement.in, []);
  assert.deepEqual(movement.out, [{ token: BONK, raw: 50_000_000n, after: 190_394_222_564n, decimals: 5 }]);
  assert.equal(movement.time, 1_789_990_473_000);
});

test("SOL paid beyond fees and rent makes a buy; a bare transfer in is only received", () => {
  const bought = solanaMovement(WALLET, "sig2", transaction({
    lamports: [2_000_000_000n, 1_500_000_000n], pre: [], post: [[BONK, 1_000_000_00n, 5]],
  }));
  assert.equal(bought.kind, "buy");
  assert.equal(bought.paidNative, 500_000_000n - 5005n);
  const airdrop = solanaMovement(WALLET, "sig3", transaction({
    signer: false, lamports: [2_000_000_000n, 2_000_000_000n], pre: [], post: [[BONK, 1_000_000_00n, 5]],
  }));
  assert.equal(airdrop.kind, "received");
  assert.equal(solanaMovement(WALLET, "sig4", transaction({ err: { InstructionError: [0, "Custom"] } })), null);
  assert.equal(solanaMovement(WALLET, "sig5", transaction({ pre: [[BONK, 5, 5, OTHER]], post: [[BONK, 6, 5, OTHER]] })), null);
});

test("the indexer takes the newest page first, then only what is new, and prices the asset leg", async () => {
  const store = memoryStore();
  const sell = transaction({ pre: [[USDC, 181_946, 6], [BONK, 190_444_222_564, 5]], post: [[USDC, 183_614, 6], [BONK, 190_394_222_564, 5]] });
  const buy = transaction({ blockTime: 1_789_990_600, lamports: [2_000_000_000n, 1_500_000_000n], pre: [[BONK, 190_394_222_564, 5]], post: [[BONK, 190_494_222_564, 5]] });
  let chain = [{ signature: "old", err: null }];
  const txs = { old: sell, fresh: buy };
  const calls = [];
  const rpc = async (method, params) => {
    calls.push([method, params]);
    if (method === "getSignaturesForAddress") {
      const { until } = params[1];
      const index = until ? chain.findIndex((entry) => entry.signature === until) : chain.length;
      return chain.slice(0, index === -1 ? chain.length : index);
    }
    return txs[params[0]] ?? null;
  };
  const price = async (token) => (token === "So11111111111111111111111111111111111111112" ? 200 : 0.0000032);
  const meta = solanaMetaReader({ store, fetchImpl: async () => ({ ok: true, json: async () => ({ tokens: [{ chainIndex: "501", contract: BONK, symbol: "Bonk" }] }) }), api: "" });

  const first = await indexSolanaWallet(WALLET, { store, rpc, price, meta, now: () => 10 });
  assert.equal(first.complete, true);
  assert.equal(first.ledger.cursor, "old");
  assert.equal(first.ledger.address, WALLET);
  assert.equal(first.ledger.trades.length, 1, "a sell of tokens bought before we looked is still a sale");
  assert.equal(first.ledger.trades[0].gain, null);
  assert.equal(first.ledger.positions[BONK].symbol, "Bonk");
  assert.ok(Math.abs(first.ledger.positions[BONK].unpriced - 1_903_942.22564) < 1e-6, "what the chain says is held, without a basis");

  chain = [{ signature: "fresh", err: null }, { signature: "old", err: null }];
  const second = await indexSolanaWallet(WALLET, { store, rpc, price, meta, now: () => 20 });
  assert.equal(second.ledger.cursor, "fresh");
  assert.equal(second.ledger.trades.length, 2);
  const trade = second.ledger.trades[1];
  assert.equal(trade.side, "buy");
  assert.equal(trade.symbol, "Bonk");
  assert.equal(trade.amount, 1000);
  assert.ok(Math.abs(trade.value - 0.0032) < 1e-12);
  assert.equal(JSON.parse(await store.get(`wl:${WALLET.toLowerCase()}`)).cursor, "fresh");
  assert.ok(calls.every(([method, params]) => method !== "getSignaturesForAddress" || params[0] === WALLET));
});

test("a Solana wallet can be tracked, keeps its case, and its push names its chain", () => {
  const base = { install: "ab".repeat(32), token: "cd".repeat(32), traders: [] };
  const parsed = parseSubscription({ ...base, wallets: [{ address: WALLET, name: "sol whale" }, { address: "0x52AC212e7187a799a7382C7A768cb35B72A3E20A" }] });
  assert.equal(parsed.record.wallets[0].address, WALLET);
  assert.equal(parsed.record.wallets[1].address, "0x52ac212e7187a799a7382c7a768cb35b72a3e20a");
  assert.equal(parseSubscription({ ...base, wallets: [{ address: "not-an-address" }] }).error != null, true);
  const payload = walletPayload(parsed.record, parsed.record.wallets[0], { kind: "first", token: BONK, symbol: "Bonk", amount: 1_000_000, value: 3.2, count: 1 });
  assert.equal(payload.desk.chainIndex, "501");
  assert.equal(payload.aps.alert.title, "sol whale");
});
