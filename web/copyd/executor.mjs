/// Live copies: the engine decides, this signs and sends (docs/server-copy.md, "Executing").
///
/// Per order: the hard caps from the copier's grant are checked again outside the planner, an
/// intent is written before anything is signed, the lease and the halt are checked again
/// immediately before the signature, the order goes over REST (KMS signs it), and its fate is
/// read off the copier's trading socket by the app's OrderTracker rules. When the socket can't
/// say, the positions endpoint decides; nothing is ever re-sent blind.
import { kmsSigner } from "./kms.mjs";
import {
  NETWORKS, restClient, signinFrame, marketOpen, marketClose, protectiveClose, requestCounter, stopCondition, takeCondition,
} from "./perpl.mjs";
import { priceFrom } from "./engine.mjs";
import { scaled } from "./planner.mjs";
import { unseal } from "../api/_copy.mjs";

const INTENT_TTL_S = 7 * 86_400;
const ACCOUNT_FRESH_MS = 3_000;
const SOCKET_IDLE_MS = 60_000;
const SIGNIN_WAIT_MS = 5_000;
const CLOSE_SLIPPAGE_BPS = 50;

export const intentKey = (copierId, copyId, kind) => `copy:intent:${copierId}:${copyId}:${kind}`;
const ordersKey = (copierId, hour) => `copy:orders:${copierId}:${hour}`;

// ---------- the app's OrderTracker, for one order ----------

/// Perpl's rule: the first non-failure `mt: 24` status (`st` 2–6, 8–10) is definitive and later
/// ones are ignored; a failure (`st: 7`) stands only if nothing better arrives before the
/// deadline. 0 and 1 are progress. No `st` at all means it settled.
export function applyUpdate(entry, item) {
  if (entry.decided) return entry;
  const st = item.st == null ? null : Number(item.st);
  if (st === 0 || st === 1) return entry;
  if (st === 7) return entry.phase === "failed" ? entry : { ...entry, phase: "failed", reason: num(item.sr), failure: num(item.fr) };
  if (st === null) return { ...entry, phase: "settled", decided: true };
  const fill = { status: st, originalRaw: big(item.os), filledRaw: big(item.fs), priceRaw: big(item.fp), feeRaw: big(item.f), orderType: num(item.t) };
  return { ...entry, decided: true, fill, phase: (st === 5 || st === 6) && fill.filledRaw === 0n ? "unfilled" : "settled" };
}

const num = (v) => (v == null ? null : Number(v));
const big = (v) => (v == null ? 0n : BigInt(v));

/// The account to trade with, from a wallet snapshot (`mt: 19` or REST): its id, the last
/// request Perpl forwarded, and what is free (balance less what is locked).
export function accountFrom(snapshot, instanceId) {
  const list = snapshot?.as ?? snapshot?.accounts ?? [];
  const found = list.find((a) => instanceId == null || a.in == null || Number(a.in) === Number(instanceId)) ?? list[0];
  if (!found) return null;
  const balance = big(found.b);
  return {
    id: Number(found.id), lastForwarded: found.lfr == null ? null : BigInt(found.lfr),
    free: balance - big(found.lb), forwarding: found.fw == null ? true : Boolean(found.fw), frozen: Boolean(found.fr),
  };
}

/// Why Perpl didn't fill it, in the app's words where they exist.
export function fateSentence(entry) {
  if (entry.phase === "unfilled") return "Perpl had no liquidity within the slippage allowed, so nothing was filled.";
  if (entry.phase === "failed") {
    if (entry.failure === 1 || entry.failure === 2 || entry.failure === 3) return "Not enough free collateral for this copy and its fee. Nothing was filled.";
    return `Perpl didn't fill it (reason ${entry.reason ?? "?"}${entry.failure != null ? `/${entry.failure}` : ""}).`;
  }
  return "Perpl didn't confirm the order.";
}

// ---------- the trading socket ----------

/// One signed-in connection for a copier, kept while orders are in flight and closed after a
/// quiet minute. Frames go to `onFrame`; `ready` resolves at the first wallet snapshot.
export function tradingConnection({ url, signin, onFrame, WebSocketImpl = globalThis.WebSocket, logger = console }) {
  let socket;
  let resolveReady;
  let rejectReady;
  const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });
  ready.catch(() => {});
  let open = false;
  const timer = setTimeout(() => rejectReady(new Error("trading socket sign-in timed out")), SIGNIN_WAIT_MS);
  try { socket = new WebSocketImpl(url); } catch (error) { clearTimeout(timer); rejectReady(error); return { ready, close() {}, isOpen: () => false }; }
  socket.addEventListener("open", async () => {
    open = true;
    try { socket.send(await signin()); } catch (error) { rejectReady(error); }
  });
  socket.addEventListener("message", (event) => {
    let frame;
    try { frame = JSON.parse(typeof event.data === "string" ? event.data : String(event.data)); } catch { return; }
    if (frame?.mt === 19) { clearTimeout(timer); resolveReady(frame); }
    try { onFrame(frame); } catch (error) { logger.warn?.(`copyd: trading frame: ${error.message}`); }
  });
  socket.addEventListener("close", () => { open = false; clearTimeout(timer); rejectReady(new Error("trading socket closed")); });
  socket.addEventListener("error", () => { try { socket.close(); } catch {} });
  return { ready, close() { clearTimeout(timer); try { socket.close(); } catch {} }, isOpen: () => open };
}

// ---------- the executor ----------

/// deps: store, kms (KMSClient), tokenKey, mayAct() (lease held and not halted, checked right
/// before every signature; may be async), fetchImpl, WebSocketImpl, now, logger, deadlineMs (how long an
/// order's fate is awaited on the socket before the positions decide), commands (tests).
export function createExecutor({
  store, kms, tokenKey, mayAct = () => true, fetchImpl = fetch, WebSocketImpl = globalThis.WebSocket,
  now = Date.now, logger = console, deadlineMs = 20_000, commands, venueMark = null,
}) {
  let settle = async () => {};
  const sessions = new Map(); // copier id -> session

  function sessionFor(copier) {
    let s = sessions.get(copier.id);
    if (s && s.keyId === copier.keyId) return s;
    s?.connection?.close();
    const network = NETWORKS[copier.network];
    s = {
      keyId: copier.keyId, network, waiters: new Map(), connection: null, idleTimer: null,
      account: null, accountAt: 0, nextRq: requestCounter(() => BigInt(now())),
      signer: kmsSigner({ client: kms, keyId: copier.keyId, commands }),
    };
    s.apiKey = unseal(copier.apiKey, tokenKey);
    s.rest = s.signer.then((signer) => restClient({ network: copier.network, signer, apiKey: s.apiKey, fetchImpl }));
    sessions.set(copier.id, s);
    return s;
  }

  async function account(copier, market, { fresh = false } = {}) {
    const s = sessionFor(copier);
    if (!fresh && s.account && now() - s.accountAt < ACCOUNT_FRESH_MS) return s.account;
    const answer = await (await s.rest).wallet();
    s.account = accountFrom(answer.json, market?.instanceId);
    s.accountAt = now();
    return s.account;
  }

  /// Opens the copier's socket if it isn't, and keeps it while anything waits on it.
  function connect(copier) {
    const s = sessionFor(copier);
    clearTimeout(s.idleTimer);
    if (s.connection?.isOpen()) return s.connection;
    s.connection = tradingConnection({
      url: s.network.socket, WebSocketImpl, logger,
      signin: async () => signinFrame({ signer: await s.signer, apiKey: s.apiKey, chainId: s.network.chainId }),
      onFrame: (frame) => onFrame(s, frame),
    });
    return s.connection;
  }

  function idleLater(copier) {
    const s = sessions.get(copier.id);
    if (!s) return;
    clearTimeout(s.idleTimer);
    s.idleTimer = setTimeout(() => { if (!s.waiters.size) { s.connection?.close(); s.connection = null; } }, SOCKET_IDLE_MS);
    s.idleTimer.unref?.();
  }

  function onFrame(s, frame) {
    if (frame.mt === 19) {
      const fresh = accountFrom(frame);
      if (fresh) { s.account = fresh; s.accountAt = now(); }
      return;
    }
    if (frame.mt !== 24) return;
    for (const item of frame.d ?? [frame]) {
      const waiter = item?.rq != null ? s.waiters.get(String(item.rq)) : null;
      if (!waiter) continue;
      waiter.entry = applyUpdate(waiter.entry, item);
      if (waiter.entry.decided) waiter.done(waiter.entry);
    }
  }

  /// The order's fate: decided on the socket, or at the deadline whatever it last said
  /// (a failure stands; silence is "unknown").
  function awaitFate(s, rq) {
    const key = String(rq);
    let waiter;
    const promise = new Promise((resolve) => {
      waiter = { entry: { phase: "sent", decided: false }, done: resolve };
      s.waiters.set(key, waiter);
    });
    const timer = setTimeout(() => waiter.done(waiter.entry.phase === "failed" ? waiter.entry : { ...waiter.entry, phase: "unknown" }), deadlineMs);
    return promise.finally(() => { clearTimeout(timer); s.waiters.delete(key); });
  }

  /// The grant's hard caps, again, outside the planner: a planner bug can't exceed them.
  async function capsRefuse({ copier, plan, open, realisedToday }) {
    const caps = copier.caps ?? {};
    const live = (open ?? []).filter((c) => !c.isShadow);
    if (!(plan.margin <= caps.maxMarginPerTrade)) return `${plan.margin} AUSD is past the ${caps.maxMarginPerTrade} AUSD a copy you approved.`;
    if (!(plan.leverage <= caps.maxLeverage)) return `${plan.leverage}x is past the ${caps.maxLeverage}x you approved.`;
    if (live.length > caps.maxOpenCopies) return `${caps.maxOpenCopies} copies are already open, the most you approved.`;
    const notional = live.reduce((sum, c) => sum + c.margin * c.leverage, 0);
    if (!(notional <= caps.maxOpenNotional)) return `${notional} AUSD open would pass the ${caps.maxOpenNotional} AUSD you approved.`;
    if (Number.isFinite(realisedToday) && realisedToday <= -caps.maxDailyLoss) return `Today's losses reached the ${caps.maxDailyLoss} AUSD you approved.`;
    return null;
  }

  /// Counted before the signature, so a burst can't outrun the cap.
  async function takeOrderSlot(copier) {
    const hour = Math.floor(now() / 3_600_000);
    const used = await store.incr(ordersKey(copier.id, hour));
    if (used === 1) await store.expire(ordersKey(copier.id, hour), 3_700);
    return used <= (copier.caps?.maxOrdersPerHour ?? 0);
  }

  const writeIntent = (copier, copy, intent) =>
    store.set(intentKey(copier.id, copy.id, intent.kind), JSON.stringify({ ...intent, at: now() }), { ex: INTENT_TTL_S });

  /// The positions endpoint's word on a market and side: the size held, or 0.
  async function heldSize(copier, market, side) {
    const answer = await (await sessionFor(copier).rest).positions();
    const rows = answer.json?.d ?? answer.json?.positions ?? [];
    const sd = side === "long" ? 1 : 2;
    return rows.filter((p) => Number(p.mkt) === Number(market.id) && Number(p.sd) === sd && Number(p.st ?? 1) === 1)
      .reduce((sum, p) => sum + big(p.s), 0n);
  }

  const refuse = (copier, copy, detail) => settle(copier.id, copy.id, { kind: "refused", row: { kind: "failed", detail } });

  // ---------- what the engine calls ----------

  /// Sized at the venue the copy fills on (`venueMark`); the trader's own mark when that venue's
  /// can't be read.
  async function quote(copier, market, { mark } = {}) {
    const [held, venue] = await Promise.all([
      account(copier, market),
      venueMark ? venueMark(copier, market).catch(() => null) : null,
    ]);
    if (!held) throw new Error("no Perpl account");
    return { mark: priceFrom(venue ?? mark, market.config.priceDecimals), free: held.free };
  }

  async function submit({ copier, copy, market, plan, details, open, realisedToday }) {
    const s = sessionFor(copier);
    const fail = async (detail, state = "refused") => {
      await writeIntent(copier, copy, { kind: "open", state, detail });
      return refuse(copier, copy, detail);
    };
    const capped = await capsRefuse({ copier, plan, open, realisedToday });
    if (capped) return fail(capped);
    if (!(await takeOrderSlot(copier))) return fail(`${copier.caps.maxOrdersPerHour} orders this hour is the most you approved.`);

    const connection = connect(copier);
    const held = await account(copier, market, { fresh: true });
    if (!held) return fail("This wallet has no Perpl account.");
    if (held.frozen || !held.forwarding) return fail("Perpl isn't taking orders for this account right now.");

    const { draft } = plan;
    const rq = s.nextRq(held.lastForwarded);
    const specs = [marketOpen({ market, account: held.id, side: draft.side, size: draft.size, leverageHundredths: draft.leverageHundredths, slippageBps: draft.slippageBps, rq })];
    const protection = draft.protection ?? {};
    for (const [trigger, condition] of [[protection.stopLoss, stopCondition(draft.side)], [protection.takeProfit, takeCondition(draft.side)]]) {
      if (!trigger) continue;
      specs.push(protectiveClose({ market, account: held.id, side: draft.side, size: draft.size, trigger, condition, linkedRequest: rq, slippageBps: draft.slippageBps, rq: s.nextRq(held.lastForwarded) }));
    }
    await writeIntent(copier, copy, { kind: "open", state: "planned", rq: String(rq), marketId: market.id, side: draft.side, sizeRaw: draft.size.raw.toString() });
    await connection.ready.catch(() => {}); // the socket is for confirmation; REST works without it

    if (!(await mayAct())) return fail("Copying paused on the server before the order was signed.", "withheld");
    const fate = awaitFate(s, rq);
    let answer;
    try {
      answer = await (await s.rest).place(specs);
    } catch (error) {
      s.waiters.get(String(rq))?.done({ phase: "rejected" });
      await fate;
      return fail(`Perpl refused the order: ${String(error.body ?? error.message).slice(0, 160)}`);
    }
    const statuses = answer.json?.statuses ?? answer.json?.d ?? [];
    const first = statuses[0];
    if (first && Number(first.code ?? 0) !== 0) {
      s.waiters.get(String(rq))?.done({ phase: "rejected" });
      await fate;
      return fail(`Perpl refused the order: ${first.error ?? `code ${first.code}`}${first.sr != null ? ` (${first.sr})` : ""}.`);
    }
    await writeIntent(copier, copy, { kind: "open", state: "sent", rq: String(rq), marketId: market.id, side: draft.side, sizeRaw: draft.size.raw.toString() });

    const outcome = await fate;
    idleLater(copier);
    let filledRaw = outcome.fill?.filledRaw ?? 0n;
    let entry = outcome.fill && outcome.fill.priceRaw > 0n ? Number(outcome.fill.priceRaw) / 10 ** market.config.priceDecimals : null;
    if (outcome.phase === "unknown") {
      // The socket said nothing in time: what the account now holds on this market decides.
      const size = await heldSize(copier, market, draft.side).catch(() => null);
      if (size == null) return writeIntent(copier, copy, { kind: "open", state: "unresolved", rq: String(rq), marketId: market.id, side: draft.side, sizeRaw: draft.size.raw.toString() });
      filledRaw = size;
    }
    if (outcome.phase === "settled" || filledRaw > 0n) {
      const sizeRaw = (filledRaw > 0n ? filledRaw : draft.size.raw).toString();
      await writeIntent(copier, copy, { kind: "open", state: "filled", rq: String(rq), sizeRaw, entry });
      const shortfall = filledRaw > 0n && filledRaw < draft.size.raw ? ` · ${Number(filledRaw * 10000n / draft.size.raw) / 100}% filled` : "";
      return settle(copier.id, copy.id, {
        kind: "filled", entry, sizeRaw, rq: String(rq), feeRaw: (outcome.fill?.feeRaw ?? 0n).toString(),
        row: { kind: "opened", detail: details.join(" · ") + shortfall },
      });
    }
    return fail(fateSentence(outcome), "unfilled");
  }

  async function close({ copier, copy, market, reason }) {
    const s = sessionFor(copier);
    const back = (detail) => settle(copier.id, copy.id, { kind: "closeFailed", row: { kind: "failed", detail } });
    if (!market) return back(`${copy.symbol} isn't listed any more, so the copy stays open with its stop.`);
    if (!(await takeOrderSlot(copier))) return back("The hour's order limit is used up; the copy stays open with its stop.");
    const connection = connect(copier);
    const held = await account(copier, market, { fresh: true });
    if (!held || held.frozen) return back("Perpl isn't taking orders for this account right now; the copy stays open with its stop.");
    const side = copy.isLong ? "long" : "short";
    const size = scaled(BigInt(copy.sizeRaw), market.config.sizeDecimals);
    const rq = s.nextRq(held.lastForwarded);
    const spec = marketClose({ market, account: held.id, side, size, slippageBps: Math.min(CLOSE_SLIPPAGE_BPS, market.maxMarketSlippageBps), rq });
    await writeIntent(copier, copy, { kind: "close", state: "planned", rq: String(rq) });
    await connection.ready.catch(() => {});
    if (!(await mayAct())) return back("Copying paused on the server before the close was signed; the copy stays open with its stop.");
    const fate = awaitFate(s, rq);
    let answer;
    try { answer = await (await s.rest).place([spec]); } catch (error) {
      s.waiters.get(String(rq))?.done({ phase: "rejected" });
      await fate;
      return back(`Perpl refused the close: ${String(error.body ?? error.message).slice(0, 160)}. The copy stays open with its stop.`);
    }
    const first = (answer.json?.statuses ?? [])[0];
    if (first && Number(first.code ?? 0) !== 0) {
      s.waiters.get(String(rq))?.done({ phase: "rejected" });
      await fate;
      return back(`Perpl refused the close: ${first.error ?? `code ${first.code}`}. The copy stays open with its stop.`);
    }
    await writeIntent(copier, copy, { kind: "close", state: "sent", rq: String(rq) });
    const outcome = await fate;
    idleLater(copier);
    let closedAll = outcome.phase === "settled" && (outcome.fill == null || outcome.fill.filledRaw >= BigInt(copy.sizeRaw));
    if (outcome.phase === "unknown" || (outcome.phase === "settled" && !closedAll)) {
      const left = await heldSize(copier, market, side).catch(() => null);
      closedAll = left === 0n;
    }
    if (!closedAll) return back(`${fateSentence(outcome)} The copy stays open with its stop.`);
    const exit = outcome.fill && outcome.fill.priceRaw > 0n ? Number(outcome.fill.priceRaw) / 10 ** market.config.priceDecimals : null;
    const sizeUnits = Number(copy.sizeRaw) / 10 ** market.config.sizeDecimals;
    const fees = (Number(copy.feeRaw ?? 0) + Number(outcome.fill?.feeRaw ?? 0n)) / 1_000_000;
    const pnl = exit != null && copy.entry != null ? (exit - copy.entry) * sizeUnits * (copy.isLong ? 1 : -1) - fees : undefined;
    await writeIntent(copier, copy, { kind: "close", state: "filled", rq: String(rq), exit });
    return settle(copier.id, copy.id, { kind: "closed", row: { kind: "closed", detail: reason, ...(pnl != null ? { pnl } : {}) } });
  }

  /// After a restart: a copy left pending or closing is settled from what the account holds,
  /// never by sending again.
  async function reconcile({ copier, copy, market }) {
    if (!market) return;
    const side = copy.isLong ? "long" : "short";
    const size = await heldSize(copier, market, side);
    if (copy.state === "pending") {
      if (size > 0n) return settle(copier.id, copy.id, { kind: "filled", entry: copy.entry ?? null, sizeRaw: size.toString(), row: { kind: "opened", detail: "Confirmed after a restart." } });
      return settle(copier.id, copy.id, { kind: "refused", row: { kind: "failed", detail: "The order wasn't filled before a restart; nothing was opened." } });
    }
    if (copy.state === "closing") {
      if (size === 0n) return settle(copier.id, copy.id, { kind: "closed", row: { kind: "closed", detail: "Closed; confirmed after a restart." } });
      return settle(copier.id, copy.id, { kind: "closeFailed" });
    }
  }

  return {
    quote, submit, close, reconcile,
    attach(engine) { settle = engine.settle; },
    stop() { for (const s of sessions.values()) { clearTimeout(s.idleTimer); s.connection?.close(); } sessions.clear(); },
  };
}
