/// The server's copy engine: what App/Desk/CopyTrader.swift does on the phone, for every copier
/// who turned server copying on, with the phone off. This file runs shadow copies; live copies
/// go through an executor (`executor.open/close`) that signs with the copier's KMS key, and are
/// refused here until one is configured.
///
/// Differences from the app, each deliberate (docs/server-copy.md):
/// - Baselines are persisted, so a restart diffs against what was last seen instead of losing
///   every move made while the engine was down.
/// - "Today" for the daily loss limit is midnight in the copier's own time zone.
/// - Every result is also a notification, since nobody is watching the screen.
import { randomUUID } from "node:crypto";
import {
  plan, moves as diff, sentence, shadowFill, shadowPnL, shadowTriggered, chaseBps, marketFromContext, scaled,
} from "./planner.mjs";

export const LOG_LIMIT = 400;
const SHADOW_PAPER_BALANCE = 1_000_000_000n; // 1,000 AUSD, as the app
const DEFAULT_TAKER_FEE = 345;

const K = {
  copier: (id) => `copy:copier:${id}`,
  copiers: "copy:copiers",
  followers: (trader) => `copy:followers:${trader}`,
  traders: "copy:traders",
  base: (trader) => `copy:base:${trader}`,
  open: (id) => `copy:open:${id}`,
  log: (id) => `copy:log:${id}`,
  account: (id) => `copy:account:${id}`,
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

export function createEngine({ store, readTrader, markets, now = Date.now, notify = async () => {}, executor = null, logger = console }) {
  const json = async (key, fallback) => { const text = await store.get(key); return text ? JSON.parse(text) : fallback; };
  const save = (key, value) => store.set(key, JSON.stringify(value));
  const marks = new Map(); // symbol -> latest mark seen on any trader read
  const accounts = new Map(); // exchange account id -> trader, written to Redis once

  async function marketsBySymbol() {
    const bySymbol = new Map();
    for (const raw of (await markets()).values()) {
      const market = marketFromContext(raw);
      bySymbol.set(market.symbol, market);
    }
    return bySymbol;
  }

  async function record(copier, entry) {
    const row = { id: randomUUID(), date: now(), ...entry };
    await store.lpush(K.log(copier.id), JSON.stringify(row));
    await store.ltrim(K.log(copier.id), 0, LOG_LIMIT - 1);
    try { await notify(copier, row); } catch (error) { logger.warn?.(`copyd: notify ${copier.id}: ${error.message}`); }
    return row;
  }

  async function logOf(copier) {
    return (await store.lrange(K.log(copier.id), 0, LOG_LIMIT - 1)).map((text) => JSON.parse(text));
  }

  /// Realised today in one mode, in the copier's time zone. Rows whose result is not known yet
  /// count as zero, as in the app.
  async function realisedToday(copier, shadow) {
    const since = startOfDay(now(), copier.timeZone);
    const total = (await logOf(copier))
      .filter((row) => row.date >= since && Boolean(row.isShadow) === shadow && Number.isFinite(row.pnl))
      .reduce((sum, row) => sum + row.pnl, 0);
    return micros(total);
  }

  async function setPaused(copier, paused, detail) {
    const fresh = await json(K.copier(copier.id), copier);
    fresh.paused = paused;
    await save(K.copier(copier.id), fresh);
    copier.paused = paused;
    await record(copier, { trader: "", symbol: "", isLong: false, kind: paused ? "paused" : "resumed", detail });
  }

  // ---------- copiers ----------

  async function putCopier(copier) {
    const id = copierId(copier.network, copier.address);
    const before = await json(K.copier(id), null);
    const next = { paused: false, timeZone: "UTC", traders: {}, ...copier, id };
    await save(K.copier(id), next);
    await store.sadd(K.copiers, id);
    const was = new Set(Object.keys(before?.traders ?? {}));
    const now_ = new Set(Object.keys(next.traders).map((t) => t.toLowerCase()));
    for (const trader of now_) { await store.sadd(K.followers(trader), id); await store.sadd(K.traders, trader); }
    for (const trader of was) if (!now_.has(trader)) await store.srem(K.followers(trader), id);
    return next;
  }

  async function removeCopier(id) {
    const copier = await json(K.copier(id), null);
    if (!copier) return;
    for (const trader of Object.keys(copier.traders)) await store.srem(K.followers(trader), id);
    await store.srem(K.copiers, id);
    await store.del(K.copier(id));
  }

  // ---------- reading traders ----------

  /// Reads a trader, diffs against the stored baseline and applies the moves for every copier
  /// following them. Returns the moves found, for logs and tests.
  async function processTrader(address) {
    const trader = address.toLowerCase();
    const followers = await store.smembers(K.followers(trader));
    if (!followers.length) return [];
    const book = await readTrader(trader);
    if (!book || book.unreadable) return [];
    if (book.accountId && accounts.get(book.accountId) !== trader) {
      accounts.set(book.accountId, trader);
      await store.set(K.account(book.accountId), trader);
    }
    for (const position of Object.values(book.positions)) if (position.mark > 0) marks.set(position.symbol, position.mark);

    const base = await json(K.base(trader), null);
    if (!base) {
      // First sight of this trader: what they already hold is never copied.
      await save(K.base(trader), { at: now(), positions: book.positions, emptyOnce: false });
      return [];
    }
    const before = base.positions;
    const after = book.positions;
    // A whole book reading empty when it was not needs a second empty read before it acts.
    if (!Object.keys(after).length && Object.keys(before).length && !base.emptyOnce) {
      await save(K.base(trader), { ...base, emptyOnce: true });
      return [];
    }
    const found = diff(before, after);
    // Only a change of shape is written: marks move every read, and the diff only needs which
    // symbols are held on which side.
    if (found.length || base.emptyOnce) await save(K.base(trader), { at: now(), positions: after, emptyOnce: false });
    if (!found.length) return [];

    for (const id of followers) {
      const copier = await json(K.copier(id), null);
      if (!copier) continue;
      for (const move of found) {
        const rules = copier.traders[trader]?.rules;
        if (!rules) break;
        const context = { copier, trader, rules, portfolio: book.portfolio };
        if (move.kind === "opened") await openCopy(context, move.position);
        else if (move.kind === "flipped") {
          await closeCopy(context, move.position.symbol, "flipped", move.position.mark);
          await openCopy(context, move.position);
        } else if (rules.closeWithTrader) {
          await closeCopy(context, move.position.symbol, "closed", marks.get(move.position.symbol) ?? move.position.mark);
        }
      }
    }
    return found;
  }

  // ---------- opening ----------

  async function openCopy({ copier, trader, rules, portfolio }, position) {
    const shadow = rules.mode === "shadow";
    const symbol = position.symbol;
    const base = { trader, symbol, isLong: position.side === "long", isShadow: shadow };
    const skipped = (detail) => record(copier, { ...base, kind: "skipped", detail });

    if (copier.paused) return skipped("Auto-copy was paused.");
    if (!shadow && !executor) return skipped("Live copying from the server isn't switched on yet.");
    const market = (await marketsBySymbol()).get(symbol);
    if (!market) return skipped(`${symbol} isn't listed on Perpl ${copier.network}.`);
    const open = await json(K.open(copier.id), []);
    if (open.some((c) => c.trader === trader && c.symbol === symbol && Boolean(c.isShadow) === shadow)) {
      return skipped(`A copy of this trader's ${symbol} trade is already open.`);
    }
    const mark = shadow ? priceFrom(position.mark, market.config.priceDecimals) : await executor.mark(copier, market);
    if (!mark || mark.raw <= 0n) return skipped(`No live ${symbol} price to size from.`);

    const sameMode = open.filter((c) => Boolean(c.isShadow) === shadow);
    const result = plan({
      position, traderPortfolio: portfolio, rules, guards: copier.guards, market, mark,
      free: shadow ? SHADOW_PAPER_BALANCE : await executor.free(copier),
      openCopies: sameMode.map((c) => ({ symbol: c.symbol, side: c.isLong ? "long" : "short", notional: c.margin * c.leverage })),
      realisedToday: await realisedToday(copier, shadow),
    });
    if (!result.ok) {
      const detail = sentence(result, rules, copier.network);
      if (result.skip.kind === "dailyLossLimit" && !shadow) return setPaused(copier, true, detail);
      return skipped(detail);
    }

    const copyPlan = result.plan;
    const chase = chaseBps(position.entry, position.mark, copyPlan.side);
    const details = [`${copyPlan.margin.toFixed(2)} AUSD margin`];
    if (rules.direction === "fade") details.push("fading them");
    if (copyPlan.margin !== rules.marginPerTrade && rules.sizing === "conviction") details.push(`${(copyPlan.margin / rules.marginPerTrade).toFixed(1)}× conviction`);
    if (rules.stopLossPercent != null) details.push(`stop −${rules.stopLossPercent}%`);
    if (rules.takeProfitPercent != null) details.push(`take +${rules.takeProfitPercent}%`);

    if (shadow) {
      const fill = shadowFill({
        mark: position.mark, plan: copyPlan, takerFeeMicros: market.config.takerFeeMicros ?? DEFAULT_TAKER_FEE,
        maintenanceMarginFraction: market.config.maintenanceMarginFraction, rules,
      });
      open.push({
        id: randomUUID(), trader, marketId: market.id, symbol, isLong: copyPlan.side === "long",
        sizeRaw: copyPlan.draft.size.raw.toString(), leverage: copyPlan.leverage, margin: copyPlan.margin,
        openedAt: now(), isShadow: true, shadow: fill, lastMark: position.mark, theirEntry: position.entry,
      });
      await save(K.open(copier.id), open);
      return record(copier, {
        ...base, isLong: copyPlan.side === "long", kind: "opened", detail: details.join(" · "),
        leverage: copyPlan.leverage, margin: copyPlan.margin, slippageBps: chaseBps(position.mark, fill.entry, copyPlan.side),
        chaseBps: chase,
      });
    }
    return executor.open({ copier, trader, market, position, plan: copyPlan, details, record, save: (list) => save(K.open(copier.id), list), open });
  }

  // ---------- closing ----------

  async function closeCopy({ copier, trader }, symbol, verb, mark) {
    const reason = verb === "flipped" ? "They flipped, so the copy was closed first." : "Closed with the trader.";
    const open = await json(K.open(copier.id), []);
    const shadows = open.filter((c) => c.isShadow && c.trader === trader && c.symbol === symbol);
    if (shadows.length) {
      const markets_ = await marketsBySymbol();
      const fee = markets_.get(symbol)?.config.takerFeeMicros ?? DEFAULT_TAKER_FEE;
      for (const copy of shadows) {
        const price = mark > 0 ? mark : (copy.lastMark ?? copy.shadow.entry);
        await record(copier, {
          trader, symbol, isLong: copy.isLong, kind: "closed", detail: reason, isShadow: true,
          leverage: copy.leverage, margin: copy.margin, pnl: shadowPnL(copy.shadow, price, fee),
        });
      }
      await save(K.open(copier.id), open.filter((c) => !shadows.includes(c)));
    }
    const live = open.find((c) => !c.isShadow && c.trader === trader && c.symbol === symbol);
    if (live && executor) await executor.close({ copier, copy: live, verb, reason, record, open, save: (list) => save(K.open(copier.id), list) });
  }

  // ---------- shadow triggers ----------

  /// Every open shadow copy priced at the latest mark: liquidation first, then the stop at the
  /// mark that broke it, then the take at its own price.
  async function priceShadows(copier) {
    const open = await json(K.open(copier.id), []);
    if (!open.some((c) => c.isShadow)) return;
    const markets_ = await marketsBySymbol();
    const keep = [];
    let changed = false;
    for (const copy of open) {
      const mark = copy.isShadow ? marks.get(copy.symbol) : null;
      if (!copy.isShadow || !(mark > 0)) { keep.push(copy); continue; }
      const fee = markets_.get(copy.symbol)?.config.takerFeeMicros ?? DEFAULT_TAKER_FEE;
      const hit = shadowTriggered(copy.shadow, mark);
      if (!hit) { keep.push({ ...copy, lastMark: mark }); changed = changed || copy.lastMark !== mark; continue; }
      changed = true;
      const pnl = hit.exit === "liquidation" ? -copy.margin : shadowPnL(copy.shadow, hit.price, fee);
      await record(copier, {
        trader: copy.trader, symbol: copy.symbol, isLong: copy.isLong, isShadow: true,
        kind: hit.exit === "liquidation" ? "closed" : "protected",
        detail: hit.exit === "liquidation" ? "Liquidated: the margin was gone." : hit.exit === "stop" ? "Stop loss hit." : "Take profit hit.",
        leverage: copy.leverage, margin: copy.margin, pnl,
      });
    }
    if (changed) await save(K.open(copier.id), keep);
  }

  /// One pass over every followed trader, then every copier's shadows at the marks just read.
  async function sweep() {
    const traders = await store.smembers(K.traders);
    const found = {};
    for (const trader of traders) {
      if (!(await store.scard(K.followers(trader)))) { await store.srem(K.traders, trader); continue; }
      try { found[trader] = await processTrader(trader); }
      catch (error) { logger.warn?.(`copyd: ${trader}: ${error.message}`); }
    }
    for (const id of await store.smembers(K.copiers)) {
      const copier = await json(K.copier(id), null);
      if (copier) await priceShadows(copier);
    }
    return found;
  }

  return {
    putCopier, removeCopier, processTrader, sweep, priceShadows, setPaused,
    copier: (id) => json(K.copier(id), null),
    openCopies: (id) => json(K.open(id), []),
    log: (id) => store.lrange(K.log(id), 0, LOG_LIMIT - 1).then((rows) => rows.map((r) => JSON.parse(r))),
    traders: () => store.smembers(K.traders),
    /// The followed trader behind an exchange account id, once a read has seen them.
    traderForAccount: async (id) => accounts.get(id) ?? store.get(K.account(id)),
    marks,
  };
}
