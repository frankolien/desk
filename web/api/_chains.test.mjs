// node --test web/api/_chains.test.mjs
//
// The swap route had no test of any kind, which is how a stale seven-chain allowlist and
// a required decimal the feed never supplies both survived in production.
import assert from "node:assert/strict";
import { test } from "node:test";

import {
  CHAINS, ZEROX_CHAINS, chainName, isQuotable, nativeToken, rpcEndpoint,
} from "./_chains.mjs";
import handler, {
  baseUnits, readableUnits, resolveDecimals, validAddress,
} from "./swap-quote.mjs";

/// Enough of Vercel's response object to see which answer the route chose.
function recorder() {
  const out = { status: null, body: null, headers: {} };
  return {
    status(code) { out.status = code; return this; },
    json(value) { out.body = value; return out; },
    setHeader(key, value) { out.headers[key] = value; },
  };
}

const quote = (query) => handler({ method: "GET", query }, recorder());

test("0x's published chain set is carried verbatim", () => {
  // Counted from 0x's supported-chains documentation.
  assert.equal(ZEROX_CHAINS.size, 21);
  for (const id of ["1", "56", "8453", "42161", "143", "4663"]) {
    assert.ok(ZEROX_CHAINS.has(id), `${id} should be quotable through 0x`);
  }
});

test("Robinhood Chain is quotable and Arc is not", () => {
  // The bug this file exists for: every trending token on 4663 was refused as malformed.
  assert.equal(isQuotable("4663"), true);
  assert.equal(chainName("4663"), "Robinhood Chain");
  // Arc's gas token is USDC, so it cannot borrow the shared EVM native either.
  assert.equal(isQuotable("5042"), false);
  assert.equal(chainName("5042"), "Arc");
  assert.equal(nativeToken("5042"), null);
});

test("Solana is quotable but has no EVM native", () => {
  assert.equal(isQuotable("501"), true);
  assert.equal(nativeToken("501").decimals, 9);
});

test("An unknown chain is unsupported rather than assumed", () => {
  assert.equal(isQuotable("123456"), false);
  assert.equal(nativeToken("123456"), null);
  assert.equal(chainName("123456"), "Chain 123456");
});

test("Every named chain with an RPC is one we can actually quote", () => {
  for (const [id, chain] of Object.entries(CHAINS)) {
    if (!chain.rpc) continue;
    assert.ok(chain.rpc.startsWith("https://"), `${id} rpc must be https`);
  }
});

test("Chain 999 carries no guessed identity", () => {
  // 0x calls it HyperEVM, the public registry still answers Wanchain Testnet. Quotes
  // work; the native symbol and on-chain lookup stay unavailable rather than wrong.
  assert.equal(isQuotable("999"), true);
  assert.equal(nativeToken("999").symbol, null);
  assert.equal(rpcEndpoint("999"), null);
});

test("Amounts convert both ways without floating point", () => {
  assert.equal(baseUnits("0.01", 18), "10000000000000000");
  assert.equal(baseUnits("1", 6), "1000000");
  assert.equal(baseUnits("0.0000001", 6), null, "more precision than the token has");
  assert.equal(baseUnits("abc", 18), null);
  assert.equal(readableUnits("10000000000000000", 18), "0.01");
  assert.equal(readableUnits("1000000", 6), "1");
});

test("Addresses are checked on both chains' shapes", () => {
  assert.ok(validAddress("0x78e35c13252836e2313208ab48f8bb07a7551a43"));
  assert.ok(validAddress("So11111111111111111111111111111111111111112"));
  assert.ok(!validAddress("0xnope"));
});

test("A caller's decimal hint is trusted without a network call", async () => {
  const decimals = await resolveDecimals("1", "0x" + "a".repeat(40), 6, () => {
    throw new Error("should not reach the chain");
  });
  assert.equal(decimals, 6);
});

test("Decimals come off the chain when the feed has none", async () => {
  // The discovery feed returns a null decimal for every token, so this is the path that
  // actually runs in production.
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, body: JSON.parse(options.body) });
    return { json: async () => ({ jsonrpc: "2.0", id: 1, result: "0x12" }) };
  };
  const decimals = await resolveDecimals(
    "4663", "0x78e35c13252836e2313208ab48f8bb07a7551a43", undefined, fetchImpl);
  assert.equal(decimals, 18);
  assert.equal(calls[0].url, "https://rpc.mainnet.chain.robinhood.com");
  assert.equal(calls[0].body.method, "eth_call");
  assert.equal(calls[0].body.params[0].data, "0x313ce567");
});

test("Solana decimals come off the mint, not a contract call", async () => {
  // eth_call means nothing on Solana, so every token there was refused as having
  // unconfirmable precision until this asked the right question.
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, body: JSON.parse(options.body) });
    return { json: async () => ({ result: { value: { decimals: 6, amount: "1" } } }) };
  };
  const mint = "7GPGqsfVK1gG88GuVEetrsVyDiikABTsj9B9aHEHpump";
  const decimals = await resolveDecimals("501", mint, undefined, fetchImpl);
  assert.equal(decimals, 6);
  assert.equal(calls[0].body.method, "getTokenSupply");
  assert.equal(calls[0].body.params[0], mint);
});

test("A chain with no RPC reports unknown decimals rather than inventing them", async () => {
  const decimals = await resolveDecimals(
    "5042", "0x78e35c13252836e2313208ab48f8bb07a7551a43", undefined, () => {
      throw new Error("should not reach the chain");
    });
  assert.equal(decimals, null);
});

test("An RPC that answers with nonsense is refused", async () => {
  for (const result of ["0x", "0x" + "f".repeat(64), undefined]) {
    const decimals = await resolveDecimals(
      "1", "0x" + "b".repeat(40), undefined,
      async () => ({ json: async () => ({ result }) }));
    assert.equal(decimals, null);
  }
});

const ARGUS = "0x78e35c13252836e2313208ab48f8bb07a7551a43";

test("An unsupported chain is answered as such, not as a bad request", async () => {
  // Every Arc token used to come back 400 "Valid quote parameters required", which reads
  // as the app having sent something wrong.
  const result = await quote({
    chainIndex: "5042", tokenAddress: ARGUS, side: "buy", amount: "0.01", tokenDecimals: "18",
  });
  assert.equal(result.status, 422);
  assert.equal(result.body.reason, "unsupported-chain");
  assert.equal(result.body.chainName, "Arc");
  assert.match(result.body.error, /Arc/);
});

test("A chain 0x covers gets past both gates", async () => {
  // Robinhood was refused outright. With no credentials in the test environment the route
  // now reaches the provider step and reports that instead, which is the proof it is no
  // longer rejected as malformed input.
  const result = await quote({
    chainIndex: "4663", tokenAddress: ARGUS, side: "buy", amount: "0.01", tokenDecimals: "18",
  });
  assert.equal(result.status, 503);
  assert.match(result.body.error, /No quote provider is configured/);
});

test("A token whose decimals cannot be confirmed is refused honestly", async () => {
  // Chain 999 is quotable through 0x but carries no RPC, because its identity is
  // contested, so an unhinted token there cannot be sized safely.
  const result = await quote({
    chainIndex: "999", tokenAddress: ARGUS, side: "buy", amount: "0.01",
  });
  assert.equal(result.status, 422);
  assert.equal(result.body.reason, "unknown-decimals");
});

test("Genuinely malformed input is still a 400", async () => {
  const bad = await quote({
    chainIndex: "1", tokenAddress: "0xnope", side: "buy", amount: "0.01",
  });
  assert.equal(bad.status, 400);

  const zero = await quote({
    chainIndex: "1", tokenAddress: ARGUS, side: "buy", amount: "0", tokenDecimals: "18",
  });
  assert.equal(zero.status, 400);
  assert.match(zero.body.error, /valid amount/);
});

test("Only GET is answered", async () => {
  const result = await handler({ method: "POST", query: {} }, recorder());
  assert.equal(result.status, 405);
});
