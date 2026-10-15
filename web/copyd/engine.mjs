/// The server's copy engine: what App/Desk/CopyTrader.swift does on the phone, for every copier
/// who turned server copying on, with the phone off. This file runs shadow copies; live copies
/// go through an executor that signs with the copier's KMS key, and are refused here until one
/// is configured.
///
/// Differences from the app, each deliberate (docs/server-copy.md):
/// - Baselines are persisted, so a restart diffs against what was last seen instead of losing
///   every move made while the engine was down.
/// - "Today" for the daily loss limit is midnight in the copier's own time zone.
/// - Every result is also a notification, since nobody is watching the screen.
///
/// Only the lease holder runs an engine, so its memory is the working copy and Redis is where
/// that copy is kept: everything is read once on load, a decision touches memory only, and what
/// changed goes out in one pipeline afterwards. A decision has no `await` between reading a
/// copier's state and changing it, so two traders read at once can't both take a copier's last
/// slot. Copiers changed elsewhere (the API) are named in `copy:dirty` and reloaded each tick.
/// The engine never writes `copy:copier:*`, which the API owns: a pause it makes for the daily
/// loss limit is `copy:pause:<id>`, and the API deletes that key when the copier resumes.
///
/// Executor contract, for live copies (copyd/executor.mjs): `quote(copier, market, {mark})` →
/// `{mark, free}` is awaited before deciding; `submit(intent)` and `close(intent)` run after and
/// report back through `settle(copierId, copyId, {kind: filled|refused|closed|closeFailed, row})`;
/// `reconcile` settles what a previous engine left pending or closing.
import { randomUUID } from "node:crypto";
import {
  plan, moves as diff, sentence, shadowFill, shadowPnL, shadowTriggered, chaseBps, marketFromContext, scaled,
} from "./planner.mjs";

export const LOG_LIMIT = 400;
const TRIM_EVERY = 50;
const SHADOW_PAPER_BALANCE = 1_000_000_000n; // 1,000 AUSD, as the app
const DEFAULT_TAKER_FEE = 345;

export const K = {
  copier: (id) => `copy:copier:${id}`,
  copiers: "copy:copiers",
  dirty: "copy:dirty",
  followers: (trader) => `copy:followers:${trader}`,
  traders: "copy:traders",
  base: (trader) => `copy:base:${trader}`,
  open: (id) => `copy:open:${id}`,
  log: (id) => `copy:log:${id}`,
  pause: (id) => `copy:pause:${id}`,
  close: (id) => `copy:close:${id}`,
};

export const copierId = (network, address) => `${network}:${address.toLowerCase()}`;

/// Midnight today in `timeZone`, as epoch milliseconds. An unknown zone falls back to UTC.
export function startOfDay(nowMs, timeZone = "UTC") {
  let zone = timeZone;
  try { new Intl.DateTimeFormat("en-US", { timeZone: zone }); } catch { zone = "UTC"; }
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-US", {
    timeZone: zone, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit",
  }).formatToParts(new Date(nowMs)).map((p) => [p.type, p.value]));
  const wallAsUTC = Date.UTC(+parts.year, +parts.month - 1, +parts.day, +parts.hour, +parts.minute, +parts.second);
  const offset = wallAsUTC - Math.floor(nowMs / 1000) * 1000;
  return Date.UTC(+parts.year, +parts.month - 1, +parts.day) - offset;
}

/// The app formats the observed mark to eight places and parses it at the market's decimals,
/// rounding toward zero.
export function priceFrom(mark, decimals) {
  if (!(mark > 0) || !Number.isFinite(mark)) return null;
  const [whole, fraction = ""] = mark.toFixed(8).split(".");
  return scaled(BigInt(whole + (fraction + "0".repeat(decimals)).slice(0, decimals)), decimals);
}

const micros = (value) => {
  if (!Number.isFinite(value)) return 0n;
  const limit = 4_611_686_018_427_387_903; // Int64.max / 2, the app's microsClamping
  const scaledValue = Math.max(-limit, Math.min(limit, Math.round(value * 1_000_000)));
  return BigInt(scaledValue);
};

/// Runs `work` over `items`, at most `limit` at a time.
export async function inPool(items, limit, work) {
  const out = new Array(items.length);
  let next = 0;
  const lane = async () => { while (next < items.length) { const i = next++; out[i] = await work(items[i], i); } };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, lane));
  return out;
}

const parse = (text) => (text ? JSON.parse(text) : null);

export function createEngine({
  store, readTrader, markets, now = Date.now, notify = async () => {}, executor = null, logger = console,
  readConcurrency = 16, notifyConcurrency = 32,
}) {
  const copiers = new Map(); // id -> copier
  const followers = new Map(); // trader -> Set of copier ids
  const openBy = new Map(); // copier id -> open copies
  const bases = new Map(); // trader -> last book's shape
  const today = new Map(); // copier id -> { since, shadow, live } realised since local midnight
  const pauses = new Map(); // copier id -> why the engine paused them
  const marks = new Map(); // symbol -> latest mark seen on any trader read
  const accounts = new Map(); // exchange account id -> trader
  const inflight = new Map(); // trader -> { promise, again }
  let loading = null;

  // Changes waiting for the next flush.
  const dirtyKeys = new Set();
  const pendingRows = new Map(); // copier id -> rows, oldest first
  const untrimmed = new Map(); // copier id -> rows pushed since the log was last trimmed
  let flushing = Promise.resolve();

  // ---------- loading ----------

  function index(copier) {
    for (const trader of Object.keys(copier.traders ?? {})) {
      const t = trader.toLowerCase();
      if (!followers.has(t)) followers.set(t, new Set());
      followers.get(t).add(copier.id);
    }
  }

  function unindex(id) {
    for (const [trader, set] of followers) {
      set.delete(id);
      if (!set.size) followers.delete(trader);
    }
  }

  async function tallyFromLog(id, copier) {
    const since = startOfDay(now(), copier.timeZone);
    const rows = (await store.lrange(K.log(id), 0, LOG_LIMIT - 1)).map(parse);
    const tally = { since, shadow: 0, live: 0 };
    for (const row of rows) {
      if (row.date >= since && Number.isFinite(row.pnl)) tally[row.isShadow ? "shadow" : "live"] += row.pnl;
    }
    today.set(id, tally);
  }

  async function adopt(ids) {
    if (!ids.length) return;
    const [stored, opens, paused] = await Promise.all([
      store.mget(ids.map(K.copier)), store.mget(ids.map(K.open)), store.mget(ids.map(K.pause)),
    ]);
    const fresh = [];
    ids.forEach((id, i) => {
      unindex(id);
      const copier = parse(stored[i]);
      if (!copier || copier.disabled) { copiers.delete(id); openBy.delete(id); today.delete(id); pauses.delete(id); return; }
      copiers.set(id, copier);
      if (paused[i]) pauses.set(id, paused[i]); else pauses.delete(id);
      if (!openBy.has(id)) openBy.set(id, parse(opens[i]) ?? []);
      index(copier);
      fresh.push([id, copier]);
    });
    await inPool(fresh, readConcurrency, ([id, copier]) => tallyFromLog(id, copier));
    const traders = [...followers.keys()].filter((t) => !bases.has(t));
    if (traders.length) {
      const stored_ = await store.mget(traders.map(K.base));
      traders.forEach((t, i) => { const base = parse(stored_[i]); if (base) bases.set(t, base); });
    }
  }

  /// Everything, once: the lease holder's starting point.
  function ready() {
    loading ??= (async () => {
      await adopt(await store.smembers(K.copiers));
      reconcileLive().catch((error) => logger.warn?.(`copyd: reconcile: ${error.message}`));
    })().catch((error) => { loading = null; throw error; });
    return loading;
  }

  /// Live copies a previous engine left pending or closing: the executor asks the account what
  /// it holds and settles them. Nothing is sent again.
  async function reconcileLive() {
    if (!executor?.reconcile) return;
    const unsure = [];
    for (const [id, open] of openBy) for (const copy of open) if (!copy.isShadow && (copy.state === "pending" || copy.state === "closing")) unsure.push([id, copy]);
    if (!unsure.length) return;
    const bySymbol = await marketsBySymbol();
    await inPool(unsure, 4, async ([id, copy]) => {
      const copier = copiers.get(id);
      if (copier) await executor.reconcile({ copier, copy, market: bySymbol.get(copy.symbol) }).catch((error) => logger.warn?.(`copyd: reconcile ${id}: ${error.message}`));
    });
  }

  /// Copiers the API changed since the last tick. Removing the names before reading them means a
  /// change made in between is either read now or named again for the next tick.
  async function refresh() {
    await ready();
    const ids = await store.smembers(K.dirty);
    if (!ids.length) return 0;
    await store.srem(K.dirty, ...ids);
    await adopt(ids);
    await closeRequested(ids);
    return ids.length;
  }

  /// Copies the app asked to close now (`copy:close:<id>`, set by the API): a shadow at the
  /// latest mark, a live one through the executor.
  async function closeRequested(ids) {
    const asked = await Promise.all(ids.map((id) => store.smembers(K.close(id))));
    if (!asked.some((list) => list.length)) return;
    const bySymbol = await marketsBySymbol();
    const out = [];
    const intents = [];
    const commands = [];
    ids.forEach((id, i) => {
      if (!asked[i].length) return;
      commands.push(["SREM", K.close(id), ...asked[i]]);
      const copier = copiers.get(id);
      if (!copier) return;
      const open = openBy.get(id) ?? [];
      const keep = [];
      for (const copy of open) {
        if (!asked[i].includes(copy.id)) { keep.push(copy); continue; }
        if (copy.isShadow) {
          const fee = bySymbol.get(copy.symbol)?.config.takerFeeMicros ?? DEFAULT_TAKER_FEE;
          const price = marks.get(copy.symbol) ?? copy.lastMark ?? copy.shadow.entry;
          record(copier, {
            trader: copy.trader, symbol: copy.symbol, isLong: copy.isLong, kind: "closed", detail: "Closed from the app.",
            isShadow: true, leverage: copy.leverage, margin: copy.margin, pnl: shadowPnL(copy.shadow, price, fee),
          }, out);
        } else {
          keep.push(copy);
          if (executor && copy.state !== "closing") {
            copy.state = "closing";
            intents.push({ action: "close", copier, copy, market: bySymbol.get(copy.symbol), verb: "manual", reason: "Closed from the app." });
          }
        }
      }
      openBy.set(id, keep);
      touch(K.open(id));
    });
    await store.pipeline(commands);
    await settleEffects(out);
    for (const intent of intents) executor[intent.action](intent).catch((error) => logger.warn?.(`copyd: close ${intent.copier.id}: ${error.message}`));
  }

  // ---------- writing ----------

  function touch(key) { dirtyKeys.add(key); }

  function record(copier, entry, out) {
    const row = { id: randomUUID(), date: now(), ...entry };
    const rows = pendingRows.get(copier.id) ?? [];
    rows.push(row);
    pendingRows.set(copier.id, rows);
    if (Number.isFinite(row.pnl)) {
      const tally = tallyOf(copier);
      if (row.date >= tally.since) tally[row.isShadow ? "shadow" : "live"] += row.pnl;
    }
    out.push([copier, row]);
    return row;
  }

  function valueOf(key) {
    const [, kind, ...rest] = key.split(":");
    const name = rest.join(":");
    if (kind === "open") return openBy.get(name);
    if (kind === "base") return bases.get(name);
    if (kind === "pause") return pauses.get(name);
    return undefined;
  }

  /// One pipeline for whatever changed. Flushes run one after another, so a later state never
  /// lands before an earlier one.
  function flush() {
    flushing = flushing.then(async () => {
      const commands = [];
      for (const key of dirtyKeys) {
        const value = valueOf(key);
        commands.push(value === undefined ? ["DEL", key] : ["SET", key, typeof value === "string" ? value : JSON.stringify(value)]);
      }
      dirtyKeys.clear();
      // Trimmed every fifty rows, not every push: reads take the first LOG_LIMIT either way.
      for (const [id, rows] of pendingRows) {
        commands.push(["LPUSH", K.log(id), ...rows.map((row) => JSON.stringify(row))]);
        const pushed = (untrimmed.get(id) ?? TRIM_EVERY) + rows.length;
        if (pushed >= TRIM_EVERY) { commands.push(["LTRIM", K.log(id), 0, LOG_LIMIT - 1]); untrimmed.set(id, 0); }
        else untrimmed.set(id, pushed);
      }
      pendingRows.clear();
      for (let i = 0; i < commands.length; i += 500) await store.pipeline(commands.slice(i, i + 500));
    }).catch((error) => logger.warn?.(`copyd: flush: ${error.message}`));
    return flushing;
  }

  async function deliver(rows) {
    await inPool(rows, notifyConcurrency, async ([copier, row]) => {
      try { await notify(copier, row); } catch (error) { logger.warn?.(`copyd: notify ${copier.id}: ${error.message}`); }
    });
  }

  async function settleEffects(out) {
    await flush();
    await deliver(out);
  }

  // ---------- copiers ----------

  async function putCopier(copier) {
    await ready();
    const id = copierId(copier.network, copier.address);
    const before = copiers.get(id);
    const next = { paused: false, timeZone: "UTC", traders: {}, ...copier, id };
    copiers.set(id, next);
    if (!openBy.has(id)) openBy.set(id, []);
    if (before?.timeZone !== next.timeZone) today.delete(id);
    unindex(id);
    index(next);
    const was = new Set(Object.keys(before?.traders ?? {}).map((t) => t.toLowerCase()));
    const is = new Set(Object.keys(next.traders).map((t) => t.toLowerCase()));
    const commands = [["SET", K.copier(id), JSON.stringify(next)], ["SADD", K.copiers, id]];
    for (const trader of is) commands.push(["SADD", K.followers(trader), id], ["SADD", K.traders, trader]);
    for (const trader of was) {
      if (is.has(trader)) continue;
      commands.push(["SREM", K.followers(trader), id]);
      if (!followers.has(trader)) commands.push(["SREM", K.traders, trader]);
    }
    await store.pipeline(commands);
    return next;
  }

  async function removeCopier(id) {
    await ready();
    const copier = copiers.get(id);
    if (!copier) return;
    unindex(id);
    copiers.delete(id);
    today.delete(id);
    const commands = [["SREM", K.copiers, id], ["DEL", K.copier(id)]];
    for (const trader of Object.keys(copier.traders)) {
      const t = trader.toLowerCase();
      commands.push(["SREM", K.followers(t), id]);
      if (!followers.has(t)) commands.push(["SREM", K.traders, t]);
    }
    await store.pipeline(commands);
  }

  function tallyOf(copier) {
    const since = startOfDay(now(), copier.timeZone);
    let tally = today.get(copier.id);
    if (!tally || tally.since !== since) { tally = { since, shadow: 0, live: 0 }; today.set(copier.id, tally); }
    return tally;
  }

  const isPaused = (copier) => Boolean(copier.paused) || pauses.has(copier.id);

  const rulesFor = (copier, trader) => copier.traders[trader]?.rules
    ?? copier.traders[Object.keys(copier.traders).find((t) => t.toLowerCase() === trader)]?.rules;

  function setPaused(copier, paused, detail, out) {
    if (paused) pauses.set(copier.id, detail); else pauses.delete(copier.id);
    touch(K.pause(copier.id));
    return record(copier, { trader: "", symbol: "", isLong: false, kind: paused ? "paused" : "resumed", detail }, out);
  }

  // ---------- reading traders ----------

  async function marketsBySymbol() {
    const bySymbol = new Map();
    for (const raw of (await markets()).values()) {
      const market = marketFromContext(raw);
      bySymbol.set(market.symbol, market);
    }
    return bySymbol;
  }

  /// One read of a trader and what follows from it. Reads of the same trader never overlap: a
  /// call made while one is running asks for another read after it, which this call then
  /// shares, so an event that lands mid-read is never answered by the read that missed it.
  function processTrader(address) {
    const trader = address.toLowerCase();
    const running = inflight.get(trader);
    if (running) { running.again = true; return running.promise; }
    const entry = { again: false };
    entry.promise = (async () => {
      const found = [];
      try {
        do { entry.again = false; found.push(...(await readOnce(trader))); } while (entry.again);
      } finally { inflight.delete(trader); }
      return found;
    })();
    inflight.set(trader, entry);
    return entry.promise;
  }

  async function readOnce(trader) {
    await ready();
    if (!followers.get(trader)?.size) return [];
    const book = await readTrader(trader);
    if (!book || book.unreadable) return [];
    if (book.accountId) accounts.set(String(book.accountId), trader);
    const bySymbol = await marketsBySymbol();
    for (const position of Object.values(book.positions)) if (position.mark > 0) marks.set(position.symbol, position.mark);

    const base = bases.get(trader);
    if (!base) {
      // First sight of this trader: what they already hold is never copied.
      bases.set(trader, { at: now(), positions: book.positions, emptyOnce: false });
      touch(K.base(trader));
      await flush();
      return [];
    }
    // A whole book reading empty when it was not needs a second empty read before it acts.
    if (!Object.keys(book.positions).length && Object.keys(base.positions).length && !base.emptyOnce) {
      bases.set(trader, { ...base, emptyOnce: true });
      touch(K.base(trader));
      return [];
    }
    const found = diff(base.positions, book.positions);
    // Only a change of shape is written: marks move every read, and the diff only needs which
    // symbols are held on which side.
    if (found.length || base.emptyOnce) {
      bases.set(trader, { at: now(), positions: book.positions, emptyOnce: false });
      touch(K.base(trader));
    }
    if (!found.length) { await flush(); return []; }

    // Everything else that needs the network happens before deciding.
    const quotes = await liveQuotes(trader, found, bySymbol);

    const out = [];
    const intents = [];
    for (const id of followers.get(trader) ?? []) {
      const copier = copiers.get(id);
      if (!copier) continue;
      const rules = rulesFor(copier, trader);
      if (!rules) continue;
      const context = { copier, trader, rules, portfolio: book.portfolio, bySymbol, quotes, out, intents };
      for (const move of found) {
        if (move.kind === "opened") openCopy(context, move.position);
        else if (move.kind === "flipped") {
          closeCopy(context, move.position.symbol, "flipped", move.position.mark);
          openCopy(context, move.position);
        } else if (rules.closeWithTrader) {
          closeCopy(context, move.position.symbol, "closed", marks.get(move.position.symbol) ?? move.position.mark);
        }
      }
    }
    await settleEffects(out);
    for (const intent of intents) executor[intent.action](intent).catch((error) => logger.warn?.(`copyd: ${intent.action} ${intent.copier.id}: ${error.message}`));
    return found;
  }

  /// Live copiers' marks and free margin for the symbols this read opened, fetched together.
  async function liveQuotes(trader, found, bySymbol) {
    const quotes = new Map();
    if (!executor) return quotes;
    const opened = found.filter((m) => m.kind !== "closed");
    const markOf = new Map(opened.map((m) => [m.position.symbol, m.position.mark]));
    const symbols = opened.map((m) => m.position.symbol);
    const wanted = [];
    for (const id of followers.get(trader) ?? []) {
      const copier = copiers.get(id);
      const rules = copier && rulesFor(copier, trader);
      if (!rules || isPaused(copier) || rules.mode === "shadow") continue;
      for (const symbol of symbols) if (bySymbol.has(symbol)) wanted.push([copier, symbol]);
    }
    await inPool(wanted, readConcurrency, async ([copier, symbol]) => {
      try { quotes.set(`${copier.id}|${symbol}`, await executor.quote(copier, bySymbol.get(symbol), { mark: markOf.get(symbol) })); }
      catch (error) { logger.warn?.(`copyd: quote ${copier.id} ${symbol}: ${error.message}`); }
    });
    return quotes;
  }

  // ---------- opening ----------

  function openCopy({ copier, trader, rules, portfolio, bySymbol, quotes, out, intents }, position) {
    const shadow = rules.mode === "shadow";
    const symbol = position.symbol;
    const base = { trader, symbol, isLong: position.side === "long", isShadow: shadow };
    const skipped = (detail) => record(copier, { ...base, kind: "skipped", detail }, out);

    if (isPaused(copier)) return skipped("Auto-copy was paused.");
    if (!shadow && !executor) return skipped("Live copying from the server isn't switched on yet.");
    const market = bySymbol.get(symbol);
    if (!market) return skipped(`${symbol} isn't listed on Perpl ${copier.network}.`);
    const open = openBy.get(copier.id) ?? [];
    if (open.some((c) => c.trader === trader && c.symbol === symbol && Boolean(c.isShadow) === shadow)) {
      return skipped(`A copy of this trader's ${symbol} trade is already open.`);
    }
    const quote = shadow ? null : quotes.get(`${copier.id}|${symbol}`);
    if (!shadow && !quote) return skipped(`Couldn't read your ${symbol} price or balance in time.`);
    const mark = shadow ? priceFrom(position.mark, market.config.priceDecimals) : quote.mark;
    if (!mark || mark.raw <= 0n) return skipped(`No live ${symbol} price to size from.`);

    const sameMode = open.filter((c) => Boolean(c.isShadow) === shadow);
    const result = plan({
      position, traderPortfolio: portfolio, rules, guards: copier.guards, market, mark,
      free: shadow ? SHADOW_PAPER_BALANCE : quote.free,
      openCopies: sameMode.map((c) => ({ symbol: c.symbol, side: c.isLong ? "long" : "short", notional: c.margin * c.leverage })),
      realisedToday: micros(tallyOf(copier)[shadow ? "shadow" : "live"]),
    });
    if (!result.ok) {
      const detail = sentence(result, rules, copier.network);
      if (result.skip.kind === "dailyLossLimit" && !shadow) return setPaused(copier, true, detail, out);
      return skipped(detail);
    }

    const copyPlan = result.plan;
    const chase = chaseBps(position.entry, position.mark, copyPlan.side);
    const details = [`${copyPlan.margin.toFixed(2)} AUSD margin`];
    if (rules.direction === "fade") details.push("fading them");
    if (copyPlan.margin !== rules.marginPerTrade && rules.sizing === "conviction") details.push(`${(copyPlan.margin / rules.marginPerTrade).toFixed(1)}× conviction`);
    if (rules.stopLossPercent != null) details.push(`stop −${rules.stopLossPercent}%`);
    if (rules.takeProfitPercent != null) details.push(`take +${rules.takeProfitPercent}%`);
    const copy = {
      id: randomUUID(), trader, marketId: market.id, symbol, isLong: copyPlan.side === "long",
      sizeRaw: copyPlan.draft.size.raw.toString(), leverage: copyPlan.leverage, margin: copyPlan.margin,
      openedAt: now(), isShadow: shadow, lastMark: position.mark, theirEntry: position.entry,
    };
    if (shadow) {
      copy.shadow = shadowFill({
        mark: position.mark, plan: copyPlan, takerFeeMicros: market.config.takerFeeMicros ?? DEFAULT_TAKER_FEE,
        maintenanceMarginFraction: market.config.maintenanceMarginFraction, rules,
      });
    } else {
      // Held as pending before anything is signed, so the slot and the margin are taken now.
      copy.state = "pending";
      intents.push({
        action: "submit", copier, copy, market, plan: copyPlan, position, details,
        open: [...open, copy], realisedToday: tallyOf(copier).live,
      });
    }
    openBy.set(copier.id, [...open, copy]);
    touch(K.open(copier.id));
    if (!shadow) return null;
    return record(copier, {
      ...base, isLong: copy.isLong, kind: "opened", detail: details.join(" · "),
      leverage: copy.leverage, margin: copy.margin, slippageBps: chaseBps(position.mark, copy.shadow.entry, copyPlan.side),
      chaseBps: chase,
    }, out);
  }

  // ---------- closing ----------

  function closeCopy({ copier, trader, bySymbol, out, intents }, symbol, verb, mark) {
    const reason = verb === "flipped" ? "They flipped, so the copy was closed first." : "Closed with the trader.";
    const open = openBy.get(copier.id) ?? [];
    const shadows = open.filter((c) => c.isShadow && c.trader === trader && c.symbol === symbol);
    const fee = bySymbol.get(symbol)?.config.takerFeeMicros ?? DEFAULT_TAKER_FEE;
    for (const copy of shadows) {
      const price = mark > 0 ? mark : (copy.lastMark ?? copy.shadow.entry);
      record(copier, {
        trader, symbol, isLong: copy.isLong, kind: "closed", detail: reason, isShadow: true,
        leverage: copy.leverage, margin: copy.margin, pnl: shadowPnL(copy.shadow, price, fee),
      }, out);
    }
    if (shadows.length) { openBy.set(copier.id, open.filter((c) => !shadows.includes(c))); touch(K.open(copier.id)); }
    const live = open.find((c) => !c.isShadow && c.trader === trader && c.symbol === symbol && c.state !== "closing");
    if (live && executor) {
      live.state = "closing";
      touch(K.open(copier.id));
      intents.push({ action: "close", copier, copy: live, market: bySymbol.get(symbol), verb, reason });
    }
  }

  /// What the executor learned about a live copy: filled, refused or closed.
  async function settle(id, copyId, result) {
    const copier = copiers.get(id);
    if (!copier) return;
    const out = [];
    const open = openBy.get(id) ?? [];
    const copy = open.find((c) => c.id === copyId);
    if (!copy) return;
    // filled: the copy is open on the venue; closeFailed: still open, as before the close;
    // refused and closed: gone.
    if (result.kind === "filled") {
      Object.assign(copy, { state: "open", entry: result.entry ?? copy.entry ?? null, sizeRaw: result.sizeRaw ?? copy.sizeRaw });
      if (result.rq) copy.rq = result.rq;
      if (result.feeRaw) copy.feeRaw = result.feeRaw;
    } else if (result.kind === "closeFailed") copy.state = "open";
    else openBy.set(id, open.filter((c) => c !== copy));
    touch(K.open(id));
    if (result.row) record(copier, { trader: copy.trader, symbol: copy.symbol, isLong: copy.isLong, leverage: copy.leverage, margin: copy.margin, ...result.row }, out);
    await settleEffects(out);
  }

  // ---------- shadow triggers ----------

  /// Every open shadow copy priced at the latest mark: liquidation first, then the stop at the
  /// mark that broke it, then the take at its own price. `lastMark` is kept in memory only.
  function priceShadows(copier, bySymbol, out) {
    const open = openBy.get(copier.id) ?? [];
    if (!open.some((c) => c.isShadow)) return;
    const keep = [];
    let closed = false;
    for (const copy of open) {
      const mark = copy.isShadow ? marks.get(copy.symbol) : null;
      if (!copy.isShadow || !(mark > 0)) { keep.push(copy); continue; }
      const hit = shadowTriggered(copy.shadow, mark);
      if (!hit) { copy.lastMark = mark; keep.push(copy); continue; }
      closed = true;
      const fee = bySymbol.get(copy.symbol)?.config.takerFeeMicros ?? DEFAULT_TAKER_FEE;
      const pnl = hit.exit === "liquidation" ? -copy.margin : shadowPnL(copy.shadow, hit.price, fee);
      record(copier, {
        trader: copy.trader, symbol: copy.symbol, isLong: copy.isLong, isShadow: true,
        kind: hit.exit === "liquidation" ? "closed" : "protected",
        detail: hit.exit === "liquidation" ? "Liquidated: the margin was gone." : hit.exit === "stop" ? "Stop loss hit." : "Take profit hit.",
        leverage: copy.leverage, margin: copy.margin, pnl,
      }, out);
    }
    if (closed) { openBy.set(copier.id, keep); touch(K.open(copier.id)); }
  }

  /// One pass over every followed trader, a few at a time, then every open shadow at the marks
  /// just read.
  async function sweep() {
    await ready();
    const traders = [...followers.keys()];
    const found = {};
    await inPool(traders, readConcurrency, async (trader) => {
      try { found[trader] = await processTrader(trader); }
      catch (error) { logger.warn?.(`copyd: ${trader}: ${error.message}`); }
    });
    const bySymbol = await marketsBySymbol();
    const out = [];
    for (const [id, open] of openBy) {
      const copier = copiers.get(id);
      if (copier && open.length) priceShadows(copier, bySymbol, out);
    }
    await settleEffects(out);
    return found;
  }

  /// Forgets everything held in memory; the next call loads it again. For a process that lost
  /// the lease and took it back: another engine may have acted in between.
  function reset() {
    for (const map of [copiers, followers, openBy, bases, today, pauses, untrimmed]) map.clear();
    loading = null;
  }

  return {
    ready, refresh, reset, putCopier, removeCopier, processTrader, sweep, settle,
    /// The engine's own pause (the daily loss limit), not the copier's.
    async setPaused(copier, paused, detail) {
      await ready();
      const out = [];
      setPaused(copiers.get(copier.id) ?? copier, paused, detail, out);
      await settleEffects(out);
    },
    paused: async (id) => { await ready(); const c = copiers.get(id); return c ? isPaused(c) : false; },
    copier: async (id) => { await ready(); return copiers.get(id) ?? null; },
    openCopies: async (id) => { await ready(); return openBy.get(id) ?? []; },
    log: async (id) => { await flushing; return (await store.lrange(K.log(id), 0, LOG_LIMIT - 1)).map(parse); },
    traders: async () => { await ready(); return [...followers.keys()]; },
    /// The followed trader behind an exchange account id, once a read has seen them.
    traderForAccount: (id) => accounts.get(String(id)) ?? null,
    marks,
    size: () => ({ copiers: copiers.size, traders: followers.size }),
  };
}
