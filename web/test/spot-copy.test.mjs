// Spot Auto-Copy (docs/spot-copy.md) against stand-ins for the chain and the quotes: a real wallet
// key signs the EIP-7702 authorization, the Calibur batch and the grant; a real P-256 key plays
// the Secure Enclave; the engine plays leaders' ledgers through a fake executor.
import { test } from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, randomBytes, sign as cryptoSign } from "node:crypto";
import { privateKeyToAccount } from "viem/accounts";
import { keccak256, recoverAddress, toHex } from "viem";
import { secp256k1 } from "@noble/curves/secp256k1";
import { memoryStore } from "../api/_store.mjs";
import { createCopyHandler, deviceCanonical } from "../api/_copy.mjs";
import { spotGrantText } from "../api/_spot.mjs";
import { copyQuoteParams, AUSD as QUOTE_AUSD } from "../api/swap-quote.mjs";
import {
  SPOT, accountFromSigner, batchFor, delegationOf, derToRS, hookAddress, keyHashOf, setupCalls, signDigestWith,
} from "../copyd/spot-chain.mjs";
import { buyDecision, checkedSpotRules, sellDecision, sellsBack, ausdRaw } from "../copyd/spot-rules.mjs";
import { S, createSpotEngine, eventId } from "../copyd/spot-engine.mjs";
import { SpotRefusal, createSpotExecutor, reasonOf } from "../copyd/spot-executor.mjs";

const wallet = privateKeyToAccount("0x7c56100e187f2845a35ce856646662dfc2024be2b4a150b45ad1f62564617128");
const ME = wallet.address;
const DESK = "0x00000000000000000000000000000000000DE5C1";
const HOOK = "0xDe5C0000000000000000000000000000dC0B501e";
const LEADER = "0x52ac212e7187a799a7382c7a768cb35b72a3e20a";
const TOKEN = "0x1111111111111111111111111111111111111111";

// ---------- chain encoding ----------

test("the key hash is Calibur's: keccak(abi.encode(Secp256k1, keccak(abi.encode(address))))", () => {
  // From cast, the same encoding as the Solidity fork tests use.
  assert.equal(keyHashOf(DESK), "0xe67133d0108d00d5caaf272729e4fcb08f3d2f6d41d7743d5f1faf82094f3f2e");
});

test("the hook address must carry Calibur's callback bits", () => {
  assert.equal(hookAddress({ SPOT_HOOK: HOOK }), HOOK);
  assert.equal(hookAddress({ SPOT_HOOK: "0xDe5C0000000000000000000000000000dC0B501f" }), null);
  assert.equal(hookAddress({}), null);
});

test("a wallet's code reads as no delegation, Calibur, or something else", () => {
  assert.equal(delegationOf("0x"), "none");
  assert.equal(delegationOf(`0xef0100${SPOT.calibur.slice(2)}`), "calibur");
  assert.equal(delegationOf("0xef01000000000000000000000000000000000000dead"), "other");
});

test("setup registers the key, fences it with the hook until the expiry, and sets limits", () => {
  const calls = setupCalls({ desk: DESK, hook: HOOK, expiry: 1_800_000_000, perTrade: 25_000_000n, perDay: 100_000_000n });
  assert.equal(calls.length, 3);
  assert.equal(calls[0].to, "0x0000000000000000000000000000000000000000");
  assert.ok(calls[1].data.includes((BigInt(1_800_000_000) << 160n | BigInt(HOOK)).toString(16)));
  assert.equal(calls[2].to, HOOK);
});

test("a KMS-style DER signature becomes a low-s Ethereum signature that recovers to the key", async () => {
  const secret = secp256k1.utils.randomPrivateKey();
  const address = privateKeyToAccount(toHex(secret)).address;
  const hash = keccak256("0x1234");
  // KMS answers DER, and not always low-s: hand it a high-s one.
  const signDer = async (digest) => {
    const sig = secp256k1.sign(digest, secret, { lowS: false });
    const high = sig.s > secp256k1.CURVE.n / 2n ? sig : new secp256k1.Signature(sig.r, secp256k1.CURVE.n - sig.s);
    return Buffer.from(high.toDERRawBytes());
  };
  const signature = await signDigestWith({ signDer, address, hash });
  assert.ok(BigInt(signature.s) <= secp256k1.CURVE.n / 2n);
  assert.equal(await recoverAddress({ hash, signature }), address);
  const { r } = derToRS(await signDer(Buffer.from(hash.slice(2), "hex")));
  assert.equal(toHex(r, { size: 32 }), signature.r);
  const account = accountFromSigner({ address, signDer });
  await assert.rejects(account.signMessage({ message: "hi" }), /transactions only/);
});

// ---------- rules ----------

const rules = checkedSpotRules({}, { perTradeAusd: 25 });
const buy = (value, extra = {}) => ({ kind: "buy", side: "buy", token: TOKEN, symbol: "PEPE", amount: 1000, value, time: 0, hash: "0xabc", ...extra });

test("a fixed buy spends the set amount; under the minimum and over the bait limit are skipped", () => {
  const base = { rules, holdsCopy: false, remainingTodayRaw: ausdRaw(100), perTradeRaw: ausdRaw(25) };
  assert.deepEqual(buyDecision({ ...base, event: buy(1000) }), { amount: ausdRaw(10) });
  assert.match(buyDecision({ ...base, event: buy(100) }).skip, /under \$250/);
  const bait = checkedSpotRules({ maxLeaderUsd: 50_000 }, { perTradeAusd: 25 });
  assert.match(buyDecision({ ...base, rules: bait, event: buy(60_000) }).skip, /over \$50000/);
});

test("matching the leader is capped by the max per buy and by the chain's per-trade limit", () => {
  const match = checkedSpotRules({ sizing: "match", maxPerBuy: 20 }, { perTradeAusd: 25 });
  const base = { rules: match, holdsCopy: false, remainingTodayRaw: ausdRaw(100) };
  assert.deepEqual(buyDecision({ ...base, perTradeRaw: ausdRaw(25), event: buy(5000) }), { amount: ausdRaw(20) });
  assert.deepEqual(buyDecision({ ...base, perTradeRaw: ausdRaw(15), event: buy(5000) }), { amount: ausdRaw(15) });
});

test("buy-once skips a token already copied; the day's limit skips past it", () => {
  const base = { rules, perTradeRaw: ausdRaw(25), event: buy(1000) };
  assert.match(buyDecision({ ...base, holdsCopy: true, remainingTodayRaw: ausdRaw(100) }).skip, /Already copied/);
  assert.match(buyDecision({ ...base, holdsCopy: false, remainingTodayRaw: ausdRaw(5) }).skip, /limit is used up/);
});

test("rules above what the wallet approved on-chain are refused", () => {
  assert.throws(() => checkedSpotRules({ maxPerBuy: 50 }, { perTradeAusd: 25 }), /approved with Face ID/);
  assert.throws(() => checkedSpotRules({ slippageBps: 5 }, { perTradeAusd: 25 }), /Slippage/);
});

test("a leader's partial sell sells the same share of the copy; a close sells all of it", () => {
  const copiedRaw = 1_000_000n;
  const half = sellDecision({ event: { kind: "sell", amount: 50 }, rules, copiedRaw, leftAfter: 50 });
  assert.deepEqual(half, { amount: 500_000n, all: false });
  assert.deepEqual(sellDecision({ event: { kind: "close", amount: 100 }, rules, copiedRaw, leftAfter: 0 }), { amount: copiedRaw, all: true });
  assert.deepEqual(sellDecision({ event: { kind: "sell", amount: 97 }, rules, copiedRaw, leftAfter: 3 }), { amount: copiedRaw, all: true });
  assert.deepEqual(sellDecision({ event: { kind: "sell", amount: 10 }, rules, copiedRaw: 0n, leftAfter: 0 }), { skip: null });
  const off = checkedSpotRules({ copySells: false }, { perTradeAusd: 25 });
  assert.match(sellDecision({ event: { kind: "sell", amount: 10 }, rules: off, copiedRaw, leftAfter: 0 }).skip, /off/);
});

test("a round trip under 85% is a token that can't be sold back", () => {
  assert.equal(sellsBack({ spentRaw: 10_000_000n, backRaw: 9_000_000n }), true);
  assert.equal(sellsBack({ spentRaw: 10_000_000n, backRaw: 8_000_000n }), false);
});

test("copy quotes carry Desk's fee in AUSD only when it is configured", () => {
  const query = { taker: ME, sellToken: QUOTE_AUSD, buyToken: TOKEN, sellAmount: "5000000", slippageBps: "500" };
  assert.equal(copyQuoteParams(query, {}).params.get("swapFeeBps"), null);
  const fee = copyQuoteParams(query, { COPY_FEE_BPS: "50", SPOT_FEE_RECIPIENT: DESK }).params;
  assert.equal(fee.get("swapFeeBps"), "50");
  assert.equal(fee.get("swapFeeToken"), QUOTE_AUSD);
  assert.equal(copyQuoteParams({ ...query, kind: "price" }, { COPY_FEE_BPS: "50", SPOT_FEE_RECIPIENT: DESK }).params.get("swapFeeBps"), null);
  assert.equal(copyQuoteParams({ ...query, sellToken: TOKEN, buyToken: "0x2222222222222222222222222222222222222222" }, {}), null, "one side is AUSD");
});

// ---------- the API ----------

function device() {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const jwk = publicKey.export({ format: "jwk" });
  const raw = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, "base64url"), Buffer.from(jwk.y, "base64url")]);
  return { key: raw.toString("base64url"), privateKey };
}

function fakeReads(state = {}) {
  const chain = { delegation: "none", transactions: 7, seq: 0n, registered: false, copied: new Map(), remaining: ausdRaw(100), limits: { perTrade: ausdRaw(25), perDay: ausdRaw(100) }, ...state };
  return {
    chain,
    reads: {
      wallet: async () => ({ delegation: chain.delegation, transactions: chain.transactions, seq: chain.seq, registered: chain.registered }),
      copied: async (_wallet, token) => chain.copied.get(token.toLowerCase()) ?? 0n,
      remainingToday: async () => chain.remaining,
      limits: async () => chain.limits,
    },
  };
}

function setup({ clock = { t: Date.UTC(2026, 9, 17, 12) }, state } = {}) {
  const store = memoryStore();
  const { reads, chain } = fakeReads(state);
  store.set(S.desk, JSON.stringify({ address: DESK, hook: HOOK, feeBps: 50 }));
  const handler = createCopyHandler(() => ({ store, kms: null, now: () => clock.t, spotReads: () => reads }));
  const phone = device();
  async function call(action, body, { headers = {} } = {}) {
    const res = { code: 0, body: null, status(c) { this.code = c; return this; }, json(b) { this.body = b; return this; }, setHeader() {} };
    await handler({ method: "POST", query: { action }, headers: { "x-forwarded-for": "1.2.3.4", ...headers }, body: typeof body === "string" ? body : JSON.stringify(body) }, res);
    return res;
  }
  async function signed(action, payload = {}, { key = phone.privateKey, nonce = randomBytes(16).toString("base64url") } = {}) {
    const text = JSON.stringify(payload);
    const message = deviceCanonical({ chainId: 143, method: "POST", target: `/api/copy/${action}`, time: String(clock.t), nonce, body: text });
    const signature = cryptoSign("sha256", Buffer.from(message), { key, dsaEncoding: "der" }).toString("base64url");
    return call(action, text, { headers: { "x-desk-wallet": ME, "x-desk-time": String(clock.t), "x-desk-nonce": nonce, "x-desk-signature": signature } });
  }
  async function enable({ perTrade = 25, perDay = 100, days = 30, tamper = {}, signer = wallet } = {}) {
    const prepared = await call("spot-prepare", { wallet: ME });
    assert.equal(prepared.code, 200, JSON.stringify(prepared.body));
    const p = prepared.body;
    const expiry = Math.floor(clock.t / 1000) + days * 86_400;
    const typed = batchFor({ kind: "enable", wallet: ME, desk: p.desk, hook: p.hook, nonce: p.batchNonce, deadline: p.deadline, perTrade, perDay, expiry });
    const signature = await signer.signTypedData(typed);
    const authorization = p.authorizationNonce == null ? null
      : await signer.signAuthorization({ chainId: 143, contractAddress: SPOT.calibur, nonce: Number(p.authorizationNonce) });
    const grant = { issuedAt: clock.t };
    grant.signature = await signer.signMessage({ message: spotGrantText({ wallet: ME, desk: p.desk, deviceKey: phone.key, perTrade, perDay, expiry, issuedAt: clock.t }) });
    return call("spot-enable", {
      wallet: ME, deviceKey: phone.key, perTrade, perDay, expiry, nonce: p.batchNonce, deadline: p.deadline, signature, grant,
      authorization: authorization && { chainId: 143, address: SPOT.calibur, nonce: authorization.nonce, r: authorization.r, s: authorization.s, yParity: authorization.yParity },
      leaders: { [LEADER]: { rules: {}, name: "Whale" } },
      ...tamper,
    });
  }
  return { store, call, signed, enable, chain, clock, phone };
}

test("spot-prepare hands the phone Desk's key, the hook and the wallet's nonces", async () => {
  const { call } = setup();
  const prepared = await call("spot-prepare", { wallet: ME });
  assert.equal(prepared.code, 200);
  assert.equal(prepared.body.desk, DESK);
  assert.equal(prepared.body.hook, HOOK);
  assert.equal(prepared.body.authorizationNonce, "7");
  assert.equal(prepared.body.keyHash, keyHashOf(DESK));
});

test("a wallet running other smart-account code is refused", async () => {
  const { call } = setup({ state: { delegation: "other" } });
  assert.equal((await call("spot-prepare", { wallet: ME })).code, 409);
});

test("spot-enable checks every signature, then queues the batch for copyd and follows the leader", async () => {
  const { enable, store } = setup();
  const enabled = await enable();
  assert.equal(enabled.code, 200, JSON.stringify(enabled.body));
  assert.equal(enabled.body.copier.stage, "enabling");
  const job = JSON.parse(store.lists.get(S.jobs)[0]);
  assert.equal(job.kind, "enable");
  assert.equal(job.authorization.address, SPOT.calibur);
  assert.deepEqual(await store.smembers(S.followers(LEADER)), [ME.toLowerCase()]);
  assert.deepEqual(await store.smembers(S.leaders), [LEADER]);
  assert.equal((await enable()).code, 409, "not twice");
});

test("spot-enable refuses a batch signed for other limits, a stranger's signatures and a stale nonce", async () => {
  const stranger = privateKeyToAccount("0x" + "11".repeat(32));
  assert.equal((await setup().enable({ tamper: { perTrade: 26 } })).code, 401, "grant and batch name 25");
  assert.equal((await setup().enable({ signer: stranger })).code, 401);
  const moved = setup();
  moved.chain.transactions = 8;
  assert.equal((await moved.enable()).code, 200, "prepare again picks up the new nonce");
  const wallet7702 = setup({ state: { delegation: "calibur", seq: 3n } });
  const ok = await wallet7702.enable();
  assert.equal(ok.code, 200, JSON.stringify(ok.body));
  assert.equal(JSON.parse(wallet7702.store.lists.get(S.jobs)[0]).authorization, null, "already runs Calibur");
});

test("limits are whole AUSD, per buy no more than per day, and end within 90 days", async () => {
  assert.equal((await setup().enable({ perTrade: 200, perDay: 100 })).code, 400);
  assert.equal((await setup().enable({ days: 120 })).code, 400);
  assert.equal((await setup().enable({ perTrade: 2.5 })).code, 400);
});

test("after enabling, only the phone's device key steers it", async () => {
  const { enable, signed } = setup();
  await enable();
  const state = await signed("spot-state");
  assert.equal(state.code, 200, JSON.stringify(state.body));
  assert.equal(state.body.copier.leaders[LEADER].name, "Whale");
  const other = device();
  assert.equal((await signed("spot-pause", {}, { key: other.privateKey })).code, 401);
  assert.equal((await signed("spot-pause")).body.copier.paused, true);
  const rules = await signed("spot-rules", { leaders: { [LEADER]: { rules: { amount: 100, maxPerBuy: 100 } } } });
  assert.equal(rules.code, 400, "more than the 25 AUSD approved on-chain");
});

test("spot-disable stops copying at once and queues the wallet's signed revoke", async () => {
  const { enable, signed, store, call } = setup({ state: { delegation: "calibur", seq: 0n } });
  await enable();
  const prepared = (await call("spot-prepare", { wallet: ME })).body;
  const typed = batchFor({ kind: "disable", wallet: ME, desk: DESK, hook: HOOK, nonce: prepared.batchNonce, deadline: prepared.deadline });
  const off = await signed("spot-disable", { nonce: prepared.batchNonce, deadline: prepared.deadline, signature: await wallet.signTypedData(typed) });
  assert.equal(off.code, 200, JSON.stringify(off.body));
  assert.equal(off.body.copier.stage, "stopping");
  assert.deepEqual(await store.smembers(S.followers(LEADER)), []);
  assert.equal(JSON.parse(store.lists.get(S.jobs).at(-1)).kind, "disable");
});

// ---------- the engine ----------

function ledgerWith(trades, positions = {}) {
  return { trades, positions, indexedAt: Date.now() };
}

function engineSetup({ chain: state } = {}) {
  const store = memoryStore();
  const { reads, chain } = fakeReads({ delegation: "calibur", ...state });
  const calls = [];
  const sent = [];
  const executor = {
    async buy(args) { calls.push(["buy", args]); if (executor.failBuy) throw new SpotRefusal("failed", "Not enough AUSD in the wallet"); return { hash: "0xb", received: 5_000n * 10n ** 18n, fee: 0n }; },
    async sell(args) { calls.push(["sell", args]); return { hash: "0xs", ausd: 9_000_000n, fee: 0n }; },
    async relay(args) { calls.push(["relay", args]); return { hash: "0xr" }; },
  };
  const engine = createSpotEngine({ store, reads, executor, desk: { address: DESK, hook: HOOK }, send: async (push, payload) => { sent.push(payload); }, sleep: async () => {} });
  const copier = {
    wallet: ME.toLowerCase(), stage: "live", deviceKey: "x", push: { token: "ab".repeat(32), environment: "production" },
    limits: { perTrade: 25, perDay: 100 }, expiry: Math.floor(Date.now() / 1000) + 86_400,
    leaders: { [LEADER]: { rules: checkedSpotRules({}, { perTradeAusd: 25 }), since: 0 } }, paused: false, failures: 0,
  };
  async function follow() {
    await store.set(S.copier(ME), JSON.stringify(copier));
    await store.sadd(S.followers(LEADER), ME.toLowerCase());
    await store.sadd(S.leaders, LEADER);
  }
  return { store, engine, calls, sent, chain, executor, follow, copier };
}

const T0 = Date.UTC(2026, 9, 17, 12);
const trade = (side, extra = {}) => ({ time: T0, hash: "0x" + "a".repeat(64), token: TOKEN, symbol: "PEPE", side, amount: 1000, price: 1, value: 1000, gain: null, ...extra });

test("the engine marks history on first sight and copies only what comes after", async () => {
  const { store, engine, calls, sent, follow } = engineSetup();
  await follow();
  await store.set(`wl:${LEADER}`, JSON.stringify(ledgerWith([trade("buy", { token: "0x" + "9".repeat(40) })])));
  await engine.tick();
  assert.equal(calls.length, 0, "the leader's past isn't copied");

  await store.set(`wl:${LEADER}`, JSON.stringify(ledgerWith([trade("buy", { token: "0x" + "9".repeat(40) }), trade("buy", { time: T0 + 60_000, hash: "0x" + "b".repeat(64) })], { [TOKEN]: { holding: 1000, decimals: 18 } })));
  await engine.tick();
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], "buy");
  assert.equal(calls[0][1].amount, ausdRaw(10));
  assert.equal(calls[0][1].token, TOKEN);
  assert.match(sent[0].aps.alert.title, /Copied 0x52ac…e20a's buy/);
  assert.match(sent[0].aps.alert.body, /10\.00 AUSD → 5\.0K PEPE/);

  await engine.tick();
  assert.equal(calls.length, 1, "the same trade isn't played twice");
});

test("the engine sells the leader's share of the copy, read from the hook", async () => {
  const { store, engine, calls, chain, follow } = engineSetup();
  await follow();
  await store.set(`wl:${LEADER}`, JSON.stringify(ledgerWith([trade("buy")], { [TOKEN]: { holding: 1000, decimals: 18 } })));
  await engine.tick();
  chain.copied.set(TOKEN, 8_000n);
  await store.set(`wl:${LEADER}`, JSON.stringify(ledgerWith([trade("buy"), trade("sell", { time: T0 + 60_000, hash: "0x" + "c".repeat(64), amount: 250, value: 250 })], { [TOKEN]: { holding: 750, decimals: 18 } })));
  await engine.tick();
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], "sell");
  assert.equal(calls[0][1].amount, 2_000n, "a quarter of the copy, as the leader sold a quarter");
});

test("three failed copies in a row pause the copier and say so", async () => {
  const { store, engine, executor, follow, sent } = engineSetup();
  executor.failBuy = true;
  await follow();
  const tokens = ["0x" + "3".repeat(40), "0x" + "4".repeat(40), "0x" + "5".repeat(40)];
  await store.set(`wl:${LEADER}`, JSON.stringify(ledgerWith([])));
  await engine.tick();
  const trades = [];
  for (const [i, token] of tokens.entries()) {
    trades.push(trade("buy", { token, time: T0 + i * 600_000, hash: "0x" + String(i + 1).repeat(64) }));
    await store.set(`wl:${LEADER}`, JSON.stringify(ledgerWith([...trades])));
    await engine.tick();
  }
  const copier = JSON.parse(await store.get(S.copier(ME)));
  assert.equal(copier.paused, true);
  assert.equal(copier.pausedBy, "failures");
  assert.ok(sent.some((p) => p.aps.alert.title === "Spot Auto-Copy paused"));
});

test("a paused, expired or halted copier copies nothing", async () => {
  for (const change of [{ paused: true }, { expiry: 1 }, { halt: true }]) {
    const { store, engine, calls, follow, copier } = engineSetup();
    Object.assign(copier, change.halt ? {} : change);
    await follow();
    if (change.halt) await store.set(S.halt, "1");
    await store.set(`wl:${LEADER}`, JSON.stringify(ledgerWith([])));
    await engine.tick();
    await store.set(`wl:${LEADER}`, JSON.stringify(ledgerWith([trade("buy")])));
    await engine.tick();
    assert.equal(calls.length, 0, JSON.stringify(change));
  }
});

test("enable jobs are relayed and turn the copier live; disable takes it off", async () => {
  const { store, engine, calls, copier, sent } = engineSetup();
  await store.set(S.copier(ME), JSON.stringify({ ...copier, stage: "enabling" }));
  const expiry = Math.floor(T0 / 1000) + 30 * 86_400;
  await store.rpush(S.jobs, JSON.stringify({ kind: "enable", wallet: ME.toLowerCase(), batch: { nonce: "0", deadline: 2_000_000_000, perTrade: 25, perDay: 100, expiry, signature: "0x" + "1".repeat(130) }, authorization: null }));
  await engine.tick();
  assert.equal(calls[0][0], "relay");
  assert.equal(calls[0][1].typed.message.batchedCall.calls.length, 3);
  assert.equal(JSON.parse(await store.get(S.copier(ME))).stage, "live");
  assert.equal(sent[0].aps.alert.title, "Spot Auto-Copy is on");

  await store.rpush(S.jobs, JSON.stringify({ kind: "disable", wallet: ME.toLowerCase(), batch: { nonce: "1", deadline: 2_000_000_000, signature: "0x" + "1".repeat(130) } }));
  await engine.tick();
  assert.equal(JSON.parse(await store.get(S.copier(ME))).stage, "off");
});

// ---------- the executor ----------

test("the executor refuses a token that can't be sold back, and never sends one copy twice", async () => {
  const store = memoryStore();
  const sent = [];
  const chain = {
    simulate: async () => {}, send: async (tx) => { sent.push(tx); return "0xhash"; },
    wait: async () => ({ status: "success", logs: [] }),
  };
  let back = 9_500_000n;
  const quote = async ({ kind }) => (kind === "price" ? { buyAmount: String(back) } : { to: SPOT.holder, data: "0x2213bc0b", buyAmount: "1000", fee: "0" });
  const executor = createSpotExecutor({ store, chain, quote, hook: HOOK, desk: DESK });
  const done = await executor.buy({ wallet: ME, token: TOKEN, amount: 10_000_000n, slippageBps: 500, id: "e1" });
  assert.equal(done.hash, "0xhash");
  assert.equal(sent.length, 1);
  await assert.rejects(executor.buy({ wallet: ME, token: TOKEN, amount: 10_000_000n, slippageBps: 500, id: "e1" }), /Already sent/);
  back = 1_000_000n;
  await assert.rejects(executor.buy({ wallet: ME, token: TOKEN, amount: 10_000_000n, slippageBps: 500, id: "e2" }), (error) => error.kind === "skipped" && /sell it back/.test(error.message));
  assert.equal(sent.length, 1);
});

test("a simulated revert is reported in words and frees the intent", async () => {
  const store = memoryStore();
  const chain = { simulate: async () => { throw new Error("execution reverted: OverDayLimit(13000000, 12000000)"); }, send: async () => "0x", wait: async () => ({ status: "success", logs: [] }) };
  const quote = async ({ kind }) => (kind === "price" ? { buyAmount: "9900000" } : { to: SPOT.holder, data: "0x2213bc0b", buyAmount: "1000" });
  const executor = createSpotExecutor({ store, chain, quote, hook: HOOK, desk: DESK });
  await assert.rejects(executor.buy({ wallet: ME, token: TOKEN, amount: 10_000_000n, slippageBps: 500, id: "e3" }), /Today's limit is used up/);
  assert.equal(await store.get(`copy:spot:intent:${ME.toLowerCase()}:e3`), null);
  assert.equal(reasonOf(new Error("TRANSFER_FROM_FAILED")), "Not enough AUSD in the wallet");
  assert.equal(eventId({ hash: "0x" + "ab".repeat(32), token: TOKEN, side: "buy" }).split(":").length, 3);
});
