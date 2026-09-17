// node --test web/api/faucet.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import {
  AUSD_MINIMUM, MON_DRIP, MON_RESERVE, MON_THRESHOLD,
  createHandler, plan, revertReason, throttled, validRecipient,
} from "./faucet.mjs";

const WALLET = "0x1111111111111111111111111111111111111111";
const FULL_FAUCET = 10n ** 20n;

function recorder() {
  const out = { status: null, body: null, headers: {} };
  return {
    status(code) { out.status = code; return this; },
    json(value) { out.body = value; return out; },
    setHeader(key, value) { out.headers[key] = value; },
  };
}

function fakeChain(balances, overrides = {}) {
  const calls = [];
  let nonce = 7;
  return {
    calls,
    balances: async () => balances,
    simulateClaim: async () => ({ ok: true, gas: 80_000n }),
    nonce: async () => nonce,
    sendMON: async (to, n) => { calls.push(["mon", to, n]); return "0xmon"; },
    claimAUSD: async (to, gas, n) => { calls.push(["ausd", to, n]); return "0xausd"; },
    confirmed: async () => true,
    ...overrides,
  };
}

const fund = (chain, body = { address: WALLET }) =>
  createHandler(() => chain, new Map())({ method: "POST", body }, recorder());

test("an empty wallet gets MON and AUSD on consecutive nonces", async () => {
  const chain = fakeChain({ recipientMON: 0n, recipientAUSD: 0n, faucetMON: FULL_FAUCET });
  const result = await fund(chain);
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, { mon: { status: "sent", hash: "0xmon" }, ausd: { status: "sent", hash: "0xausd" } });
  assert.deepEqual(chain.calls, [["mon", WALLET, 7], ["ausd", WALLET, 8]]);
});

test("a wallet at the app's gas threshold is not dripped", () => {
  const decision = plan({ recipientMON: MON_THRESHOLD, recipientAUSD: AUSD_MINIMUM, faucetMON: FULL_FAUCET });
  assert.deepEqual(decision, { mon: "enough", ausd: "enough" });
});

test("a faucet short of MON sends only what it can pay gas for", () => {
  const decision = plan({ recipientMON: 0n, recipientAUSD: 0n, faucetMON: MON_DRIP });
  assert.deepEqual(decision, { mon: "faucet-empty", ausd: "faucet-empty" });
  const funded = plan({ recipientMON: MON_THRESHOLD, recipientAUSD: 0n, faucetMON: MON_RESERVE });
  assert.equal(funded.ausd, "claim");
});

test("Agora's cooldown is reported without sending the claim", async () => {
  const chain = fakeChain(
    { recipientMON: MON_THRESHOLD, recipientAUSD: 0n, faucetMON: FULL_FAUCET },
    { simulateClaim: async () => ({ ok: false, reason: "cooldown" }) });
  const result = await fund(chain);
  assert.deepEqual(result.body, { mon: { status: "enough" }, ausd: { status: "unavailable", reason: "cooldown" } });
  assert.deepEqual(chain.calls, []);
});

test("a reverted or unconfirmed transfer is not reported as sent", async () => {
  const chain = fakeChain(
    { recipientMON: 0n, recipientAUSD: 0n, faucetMON: FULL_FAUCET },
    { confirmed: async (hash) => { if (hash === "0xmon") throw new Error("timeout"); return false; } });
  const result = await fund(chain);
  assert.deepEqual(result.body.mon, { status: "pending", hash: "0xmon" });
  assert.deepEqual(result.body.ausd, { status: "unavailable", reason: "reverted" });
});

test("requests are refused before touching the chain", async () => {
  assert.equal((await fund(fakeChain({}), { address: "0x0000000000000000000000000000000000000000" })).status, 400);
  assert.equal((await fund(fakeChain({}), "{not json")).status, 400);
  const unconfigured = await createHandler(() => null, new Map())({ method: "POST", body: { address: WALLET } }, recorder());
  assert.equal(unconfigured.status, 503);
  assert.equal(unconfigured.body.reason, "not-configured");
  const get = await createHandler(() => fakeChain({}), new Map())({ method: "GET" }, recorder());
  assert.equal(get.status, 405);
});

test("a chain failure answers 502 and frees the wallet to retry", async () => {
  const memory = new Map();
  const failing = fakeChain({}, { balances: async () => { throw new Error("rpc down"); } });
  const handler = createHandler(() => failing, memory);
  const result = await handler({ method: "POST", body: { address: WALLET } }, recorder());
  assert.equal(result.status, 502);
  assert.equal(memory.size, 0);
  assert.doesNotMatch(JSON.stringify(result.body), /rpc down/);
});

test("the same wallet is throttled for a minute", () => {
  const memory = new Map();
  assert.equal(throttled("a", 0, memory), false);
  assert.equal(throttled("a", 59_000, memory), true);
  assert.equal(throttled("a", 61_000, memory), false);
});

test("Agora's revert selectors map to reasons", () => {
  assert.equal(revertReason("0x20e5bc67"), "cooldown");
  assert.equal(revertReason("0x0949DAB9"), "already-funded");
  assert.equal(revertReason("0x5274afe7000000000000000000000000a9012a055bd4e0edff8ce09f960291c09d5322dc"), "faucet-empty");
  assert.equal(revertReason("0xdeadbeef"), null);
  assert.equal(validRecipient(WALLET), true);
  assert.equal(validRecipient("0x123"), false);
});
