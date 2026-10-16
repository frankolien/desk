// The live executor against stand-ins for KMS, Perpl's REST and its trading socket: every order
// is capped, written down, signed by the KMS key and decided by the app's OrderTracker rules.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createPrivateKey, createPublicKey, randomBytes, sign as edSign } from "node:crypto";
import { memoryStore } from "../api/_store.mjs";
import { seal } from "../api/_copy.mjs";
import { createExecutor, applyUpdate, accountFrom, intentKey } from "../copyd/executor.mjs";
import { marketFromContext, plan as planCopy, DEFAULT_RULES, DEFAULT_GUARDS } from "../copyd/planner.mjs";
import { priceFrom } from "../copyd/engine.mjs";
import { verifyEd25519, canonical } from "../copyd/perpl.mjs";

const context = JSON.parse(readFileSync(new URL("../../DeskKit/Tests/DeskFlowTests/Context-testnet.json", import.meta.url)));
const btc = marketFromContext(context.markets.find((m) => m.id === 16));
const TOKEN_KEY = randomBytes(32).toString("base64");
const PKCS8 = Buffer.from("302e020100300506032b657004220420", "hex");
const CAPS = { maxMarginPerTrade: 50, maxLeverage: 10, maxOpenCopies: 5, maxOpenNotional: 1000, maxDailyLoss: 100, maxOrdersPerHour: 3 };

function fakeKms() {
  const priv = createPrivateKey({ key: Buffer.concat([PKCS8, randomBytes(32)]), format: "der", type: "pkcs8" });
  const spki = createPublicKey(priv).export({ format: "der", type: "spki" });
  return {
    publicKey: spki.subarray(12),
    async send(command) {
      const input = command.input;
      if (command.constructor.name === "GetPublicKeyCommand") return { KeyId: "key-1", KeySpec: "ECC_NIST_EDWARDS25519", PublicKey: new Uint8Array(spki) };
      if (command.constructor.name === "SignCommand") return { Signature: new Uint8Array(edSign(null, Buffer.from(input.Message), priv)) };
      throw new Error("unexpected");
    },
  };
}

/// Perpl: REST for the wallet, positions and orders; one socket class whose instances answer
/// the sign-in with a wallet snapshot. `onOrders(specs, socket)` scripts what happens next.
function fakePerpl({ kms, onOrders = () => {}, positions = () => [] }) {
  const sockets = [];
  const placed = [];
  let lfr = 100n;
  class FakeSocket {
    constructor(url) { this.url = url; this.listeners = {}; this.sent = []; sockets.push(this); queueMicrotask(() => this.emit("open")); }
    addEventListener(name, fn) { (this.listeners[name] ??= []).push(fn); }
    emit(name, event = {}) { for (const fn of this.listeners[name] ?? []) fn(event); }
    send(text) {
      this.sent.push(JSON.parse(text));
      if (JSON.parse(text).mt === 29) queueMicrotask(() => this.frame({ mt: 19, as: [{ id: 519, in: btc.instanceId, lfr: String(lfr), b: "500000000", lb: "0", fw: true }] }));
    }
    frame(json) { this.emit("message", { data: JSON.stringify(json) }); }
    close() { this.emit("close"); }
  }
  async function fetchImpl(url, { method, headers, body }) {
    const target = url.replace(/^https:\/\/[^/]+\/api/, "");
    const message = canonical(10143, method, target, headers["X-API-Timestamp"], headers["X-API-Nonce"], body ?? "");
    if (!verifyEd25519(kms.publicKey, message, Buffer.from(headers["X-API-Signature"], "base64url"))) return new Response("bad signature", { status: 401 });
    if (target === "/v1/trading/wallet") return Response.json({ mt: 19, as: [{ id: 519, in: btc.instanceId, lfr: String(lfr), b: "500000000", lb: "0", fw: true }] });
    if (target === "/v1/trading/positions") return Response.json({ mt: 26, d: positions() });
    if (target === "/v1/trading/orders" && method === "POST") {
      const specs = JSON.parse(body).d;
      placed.push(specs);
      lfr = BigInt(specs.at(-1).rq);
      const answer = onOrders(specs, sockets.at(-1)) ?? { statuses: specs.map(() => ({ code: 0 })) };
      return Response.json(answer);
    }
    return new Response("no", { status: 404 });
  }
  return { fetchImpl, FakeSocket, sockets, placed };
}

function setup({ onOrders, positions, mayAct = () => true, deadlineMs = 60 } = {}) {
  const kms = fakeKms();
  const perpl = fakePerpl({ kms, onOrders, positions });
  const store = memoryStore();
  const settled = [];
  const executor = createExecutor({
    store, kms, tokenKey: TOKEN_KEY, mayAct, fetchImpl: perpl.fetchImpl, WebSocketImpl: perpl.FakeSocket, deadlineMs, logger: { warn() {} },
  });
  executor.attach({ settle: async (id, copyId, result) => { settled.push({ id, copyId, ...result }); } });
  const copier = { id: "testnet:0xme", network: "testnet", address: "0xme", keyId: "key-1", apiKey: seal("tok", TOKEN_KEY), caps: CAPS };
  return { executor, perpl, store, settled, copier, kms };
}

const position = { symbol: "BTC", side: "long", size: 0.5, entry: 60_000, mark: 60_000, collateral: 2_000, leverage: 5, marketId: 16 };
function intentFor(over = {}) {
  const result = planCopy({
    position, rules: { ...DEFAULT_RULES, mode: "live", maxChaseBps: 200 }, guards: DEFAULT_GUARDS, market: btc,
    mark: priceFrom(60_000, btc.config.priceDecimals), free: 500_000_000n, openCopies: [], realisedToday: 0n,
  });
  assert.equal(result.ok, true);
  const copy = { id: "c1", trader: "0xtrader", symbol: "BTC", isLong: true, margin: result.plan.margin, leverage: result.plan.leverage, state: "pending", isShadow: false };
  return { copy, market: btc, plan: result.plan, details: ["10.00 AUSD margin", "stop −25%"], open: [copy], realisedToday: 0, ...over };
}
const fill = (rq, { st = 2, size, price = 600_100, fee = 345_000 } = {}) => ({ mt: 24, d: [{ rq, st, os: size, fs: size, fp: price, f: fee, t: 1 }] });

test("An order fills: capped, written down, signed by KMS, its stop linked to it, decided on the socket", async () => {
  const ctx = setup({ onOrders: (specs, socket) => { queueMicrotask(() => socket.frame(fill(specs[0].rq, { size: specs[0].s }))); } });
  const intent = intentFor();
  await ctx.executor.submit({ copier: ctx.copier, ...intent });
  const [specs] = ctx.perpl.placed;
  assert.equal(specs.length, 2, "the opener and its stop");
  assert.equal(specs[0].t, 1);
  assert.equal(specs[0].fl, 4, "immediate or cancel");
  assert.equal(specs[0].acc, 519);
  assert.ok(BigInt(specs[0].rq) > 100n, "past what Perpl last forwarded");
  assert.equal(specs[1].tr, specs[0].rq, "the stop is linked to the opener");
  assert.equal(specs[1].t, 3, "a close, never an opposing open");
  assert.equal(ctx.perpl.sockets[0].sent[0].mt, 29, "the socket signed in with the KMS key");
  const [done] = ctx.settled;
  assert.equal(done.kind, "filled");
  assert.equal(done.entry, 60_010);
  assert.equal(done.sizeRaw, String(specs[0].s));
  assert.equal(done.row.kind, "opened");
  assert.equal(JSON.parse(await ctx.store.get(intentKey(ctx.copier.id, "c1", "open"))).state, "filled");
  ctx.executor.stop();
});

test("A failure is not the last word: a later fill decides it; a failure alone stands at the deadline", async () => {
  const later = setup({ onOrders: (specs, socket) => {
    queueMicrotask(() => { socket.frame({ mt: 24, d: [{ rq: specs[0].rq, st: 7, sr: 3 }] }); socket.frame(fill(specs[0].rq, { size: specs[0].s })); });
  } });
  await later.executor.submit({ copier: later.copier, ...intentFor() });
  assert.equal(later.settled[0].kind, "filled");

  const alone = setup({ onOrders: (specs, socket) => { queueMicrotask(() => socket.frame({ mt: 24, d: [{ rq: specs[0].rq, st: 7, sr: 9, fr: 1 }] })); } });
  await alone.executor.submit({ copier: alone.copier, ...intentFor() });
  assert.equal(alone.settled[0].kind, "refused");
  assert.match(alone.settled[0].row.detail, /Not enough free collateral/);
  later.executor.stop(); alone.executor.stop();
});

test("When the socket says nothing, the account's positions decide, and nothing is sent twice", async () => {
  let held = [];
  const ctx = setup({ positions: () => held });
  held = [{ mkt: 16, sd: 1, s: 8, st: 1 }];
  await ctx.executor.submit({ copier: ctx.copier, ...intentFor() });
  assert.equal(ctx.settled[0].kind, "filled");
  assert.equal(ctx.settled[0].sizeRaw, "8");
  assert.equal(ctx.perpl.placed.length, 1);

  const none = setup({ positions: () => [] });
  await none.executor.submit({ copier: none.copier, ...intentFor() });
  assert.equal(none.settled[0].kind, "refused");
  assert.equal(none.perpl.placed.length, 1);
  ctx.executor.stop(); none.executor.stop();
});

test("A refusal at the gateway, an IOC with no liquidity, and a halt each leave nothing open", async () => {
  const gateway = setup({ onOrders: () => ({ statuses: [{ code: 4, error: "slippage", sr: 2 }] }) });
  await gateway.executor.submit({ copier: gateway.copier, ...intentFor() });
  assert.equal(gateway.settled[0].kind, "refused");
  assert.match(gateway.settled[0].row.detail, /slippage/);

  const empty = setup({ onOrders: (specs, socket) => { queueMicrotask(() => socket.frame({ mt: 24, d: [{ rq: specs[0].rq, st: 5, os: specs[0].s, fs: 0 }] })); } });
  await empty.executor.submit({ copier: empty.copier, ...intentFor() });
  assert.match(empty.settled[0].row.detail, /no liquidity/);

  const halted = setup({ mayAct: () => false });
  await halted.executor.submit({ copier: halted.copier, ...intentFor() });
  assert.equal(halted.perpl.placed.length, 0, "nothing signed once the lease or the halt says stop");
  assert.equal(JSON.parse(await halted.store.get(intentKey(halted.copier.id, "c1", "open"))).state, "withheld");
  for (const c of [gateway, empty, halted]) c.executor.stop();
});

test("The grant's caps are checked again before signing, whatever the planner said", async () => {
  const ctx = setup();
  const intent = intentFor();
  const cases = [
    { plan: { ...intent.plan, margin: 80 } },
    { plan: { ...intent.plan, leverage: 20 } },
    { open: Array.from({ length: 6 }, (_, i) => ({ ...intent.copy, id: `c${i}` })) },
    { open: [{ ...intent.copy, margin: 300, leverage: 5 }] },
    { realisedToday: -100 },
  ];
  for (const over of cases) await ctx.executor.submit({ copier: ctx.copier, ...intent, ...over });
  assert.equal(ctx.perpl.placed.length, 0);
  assert.equal(ctx.settled.length, cases.length);
  assert.ok(ctx.settled.every((s) => s.kind === "refused"));

  const hourly = setup({ onOrders: (specs, socket) => { queueMicrotask(() => socket.frame(fill(specs[0].rq, { size: specs[0].s }))); } });
  for (let i = 0; i < 4; i++) await hourly.executor.submit({ copier: hourly.copier, ...intentFor({ copy: { ...intent.copy, id: `h${i}` } }) });
  assert.equal(hourly.perpl.placed.length, 3, "three orders an hour, as the grant says");
  assert.match(hourly.settled.at(-1).row.detail, /3 orders this hour/);
  ctx.executor.stop(); hourly.executor.stop();
});

test("Closing sends a close for the copy's size and reports what it made; a failed close leaves it open", async () => {
  const ctx = setup({ onOrders: (specs, socket) => { queueMicrotask(() => socket.frame(fill(specs[0].rq, { size: specs[0].s, price: 610_000, fee: 350_000 }))); } });
  const copy = { id: "c1", symbol: "BTC", isLong: true, sizeRaw: "8", entry: 60_000, feeRaw: "345000", state: "closing", isShadow: false };
  await ctx.executor.close({ copier: ctx.copier, copy, market: btc, reason: "Closed with the trader." });
  const [specs] = ctx.perpl.placed;
  assert.equal(specs[0].t, 3);
  assert.equal(specs[0].s, 8);
  const [done] = ctx.settled;
  assert.equal(done.kind, "closed");
  const units = 8 / 10 ** btc.config.sizeDecimals;
  assert.ok(Math.abs(done.row.pnl - ((61_000 - 60_000) * units - 0.695)) < 1e-9);

  const stuck = setup({ onOrders: () => ({ statuses: [{ code: 2, error: "account frozen" }] }) });
  await stuck.executor.close({ copier: stuck.copier, copy, market: btc, reason: "x" });
  assert.equal(stuck.settled[0].kind, "closeFailed");
  assert.match(stuck.settled[0].row.detail, /stays open with its stop/);
  ctx.executor.stop(); stuck.executor.stop();
});

test("After a restart, what the account holds settles a pending or closing copy", async () => {
  let held = [{ mkt: 16, sd: 1, s: 8, st: 1 }];
  const ctx = setup({ positions: () => held });
  await ctx.executor.reconcile({ copier: ctx.copier, copy: { id: "p", symbol: "BTC", isLong: true, state: "pending" }, market: btc });
  assert.equal(ctx.settled[0].kind, "filled");
  held = [];
  await ctx.executor.reconcile({ copier: ctx.copier, copy: { id: "q", symbol: "BTC", isLong: true, state: "closing" }, market: btc });
  assert.equal(ctx.settled[1].kind, "closed");
  await ctx.executor.reconcile({ copier: ctx.copier, copy: { id: "r", symbol: "BTC", isLong: true, state: "pending" }, market: btc });
  assert.equal(ctx.settled[2].kind, "refused");
  assert.equal(ctx.perpl.placed.length, 0, "nothing re-sent");
});

test("The tracker's rules and the account snapshot, alone", () => {
  let e = { phase: "sent", decided: false };
  e = applyUpdate(e, { st: 1 });
  assert.equal(e.phase, "sent");
  e = applyUpdate(e, { st: 7, sr: 4 });
  assert.equal(e.phase, "failed");
  e = applyUpdate(e, { st: 7, sr: 9 });
  assert.equal(e.reason, 4, "the first failure stands");
  e = applyUpdate(e, { st: 3, os: "10", fs: "10", fp: "5", f: "1" });
  assert.equal(e.phase, "settled");
  assert.equal(applyUpdate(e, { st: 7 }), e, "decided is final");
  assert.equal(applyUpdate({ phase: "sent" }, { st: 6, os: 10, fs: 0 }).phase, "unfilled");
  assert.deepEqual(accountFrom({ as: [{ id: 5, in: 1, lfr: "9", b: "100", lb: "40", fw: true }] }, 1), { id: 5, lastForwarded: 9n, free: 60n, forwarding: true, frozen: false });
});

test("Perpl's context per network: markets cached, marks fresh, and a copy sized at its venue", async () => {
  const { createMarketBook } = await import("../copyd/markets.mjs");
  const clock = { t: 0 };
  const calls = [];
  const raw = context.markets.find((m) => m.id === 16);
  const book = createMarketBook({ now: () => clock.t, fetchImpl: async (url) => {
    calls.push(url);
    return Response.json({ markets: [{ ...raw, state: { mrk: 821_000 + calls.length } }] });
  } });
  assert.equal((await book.markets("testnet")).get(16).id, 16);
  assert.match(calls[0], /^https:\/\/testnet\.perpl\.xyz\/api\/v1\/pub\/context$/);
  assert.equal(await book.mark("testnet", 16), 82_100.1);
  clock.t += 6_000;
  assert.equal(await book.mark("testnet", 16), 82_100.2, "a mark older than five seconds is read again");
  assert.equal((await book.markets("testnet")).size, 1);
  assert.equal(calls.length, 2, "markets came from the same read");

  const ctx = setup();
  const venue = createExecutor({ store: ctx.store, kms: ctx.kms, tokenKey: TOKEN_KEY, fetchImpl: ctx.perpl.fetchImpl, WebSocketImpl: ctx.perpl.FakeSocket,
    venueMark: async () => 82_100, logger: { warn() {} } });
  const quote = await venue.quote(ctx.copier, btc, { mark: 60_000 });
  assert.equal(quote.mark.raw, 821_000n, "the venue's price, not the trader's");
  venue.stop(); ctx.executor.stop();
});
