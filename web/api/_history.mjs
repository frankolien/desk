// Trader history from Perpl's own position events.
//
// The exchange lists open positions but keeps no trade history, so this reads the event
// log instead: every open, partial close, close and liquidation on mainnet, streamed
// from HyperSync in block order and folded into one compact record per account. Each
// record carries running statistics and the last trades, so a profile, a score or a
// leaderboard is a lookup rather than a scan.
//
// Statistics live in sixteen Redis shards keyed by account id, about half a kilobyte per
// account; a run reads them with one MGET and writes back only the shards it changed. The
// last trades live under each account's own key and are written only when that account
// closes something. Perpl produces tens of thousands of position events a day from a few
// hundred accounts, and this split is what keeps a half-hourly run inside the free tier's
// commands and bandwidth.

export const TOPICS = {
  opened: "0x04cc3d2fc73a9dca30eba1d05eca80b1b1216350243580027046f434fed4db18",
  closed: "0x599b5f439ed4daf1f28ae8638e5439d3982e8001fb26dd8f70021b38672eb26f",
  liquidated: "0x6fc9c0ea1c0531654320ba06740c802447dbdef7c26cf749c4f12553cdd958a9",
  decreased: "0xcd4a9f7ae1cc250eaa0be6bdb30d07efaf0faafb4ff0e76d8fe09a8373e43f85",
};
const KIND_BY_TOPIC = Object.fromEntries(Object.entries(TOPICS).map(([kind, topic]) => [topic, kind]));

export const SHARDS = 16;
const RECENT_TRADES = 20;
const COLLATERAL = 1e6;
export const BACKFILL_BLOCKS = 7 * 216_000;
const FINALITY_LAG = 20;

export const shardOf = (accountId) => Number(BigInt(accountId) % BigInt(SHARDS));
export const shardKey = (shard) => `hist:shard:${shard}`;
export const tradesKey = (account) => `hist:trades:${account}`;

function word(hex, index) {
  return BigInt(`0x${hex.slice(2 + index * 64, 2 + (index + 1) * 64) || "0"}`);
}

const signed = (value) => BigInt.asIntN(256, value);

/// One log as the fields a record needs, or null when it is not a position event.
export function decodeEvent(log, timestamps) {
  const topic = String(log.topic0 ?? log.topics?.[0] ?? "").toLowerCase();
  const kind = KIND_BY_TOPIC[topic];
  if (!kind || typeof log.data !== "string") return null;
  const data = log.data;
  const base = {
    kind,
    block: Number(log.block_number),
    time: timestamps.get(Number(log.block_number)) ?? null,
    perp: Number(word(data, 0)),
    account: word(data, 1).toString(),
    isLong: Number(word(data, 2)) !== 1,
  };
  switch (kind) {
    case "opened":
      return { ...base, leverage: Number(word(data, 3)) / 100, deposit: Number(word(data, 4)) / COLLATERAL,
        priceRaw: word(data, 6), lotsRaw: word(data, 7) };
    case "closed":
      return { ...base, priceRaw: word(data, 3), pnl: Number(signed(word(data, 4))) / COLLATERAL,
        funding: Number(signed(word(data, 5))) / COLLATERAL };
    case "decreased":
      return { ...base, pnl: Number(signed(word(data, 7))) / COLLATERAL, funding: Number(signed(word(data, 8))) / COLLATERAL };
    default:
      return { ...base, priceRaw: word(data, 4), lotsRaw: word(data, 6), pnl: Number(signed(word(data, 7))) / COLLATERAL,
        funding: Number(signed(word(data, 8))) / COLLATERAL };
  }
}

export function emptyRecord() {
  return {
    addr: null, open: {}, n: 0, w: 0, l: 0, gp: 0, gl: 0, cum: 0, peak: 0, dd: 0,
    streak: 0, bestStreak: 0, worstStreak: 0, hold: 0, holdN: 0, lev: 0, levN: 0,
    longs: 0, shorts: 0, liq: 0, vol: 0, funding: 0, first: null, last: null, markets: {},
  };
}

const round = (value, places = 6) => Math.round(value * 10 ** places) / 10 ** places;

function realise(record, pnl, time) {
  record.cum = round(record.cum + pnl);
  record.peak = Math.max(record.peak, record.cum);
  record.dd = round(Math.max(record.dd, record.peak - record.cum));
  if (time) record.last = Math.max(record.last ?? 0, time);
}

/// A closed round trip: [closed at, symbol, long 1 / short 0, entry, exit, pnl, held seconds,
/// leverage, liquidated 1 / 0].
/// Folds one event into an account's record, and returns the trade it completed, if any.
/// `market` supplies the symbol and decimals.
export function applyEvent(record, event, market) {
  const symbol = market?.name ?? `#${event.perp}`;
  const priceScale = 10 ** (market?.config?.price_decimals ?? 0);
  const sizeScale = 10 ** (market?.config?.size_decimals ?? 0);
  const key = `${event.perp}:${event.isLong ? "L" : "S"}`;
  if (event.time) record.first = Math.min(record.first ?? event.time, event.time);

  if (event.kind === "opened") {
    const price = Number(event.priceRaw) / priceScale;
    record.open[key] = { t: event.time, entry: price, lev: event.leverage, r: 0 };
    record.vol = round(record.vol + price * (Number(event.lotsRaw) / sizeScale), 2);
    record.lev += event.leverage;
    record.levN += 1;
    if (event.isLong) record.longs += 1; else record.shorts += 1;
    if (event.time) record.last = Math.max(record.last ?? 0, event.time);
    return null;
  }

  record.funding = round(record.funding + (event.funding ?? 0));
  realise(record, event.pnl, event.time);
  const position = record.open[key];
  if (event.kind === "decreased") {
    if (position) position.r = round(position.r + event.pnl);
    return null;
  }

  // closed or liquidated: the round trip ends here.
  const total = round((position?.r ?? 0) + event.pnl);
  const exit = event.priceRaw != null ? Number(event.priceRaw) / priceScale : null;
  const holdSeconds = position?.t && event.time ? Math.max(0, event.time - position.t) : null;
  delete record.open[key];

  record.n += 1;
  if (total > 0) {
    record.w += 1;
    record.gp = round(record.gp + total);
    record.streak = record.streak > 0 ? record.streak + 1 : 1;
  } else {
    record.l += 1;
    record.gl = round(record.gl - total);
    record.streak = record.streak < 0 ? record.streak - 1 : -1;
  }
  record.bestStreak = Math.max(record.bestStreak, record.streak);
  record.worstStreak = Math.min(record.worstStreak, record.streak);
  if (holdSeconds != null) {
    record.hold += holdSeconds;
    record.holdN += 1;
  }
  if (event.kind === "liquidated") record.liq += 1;
  const bucket = record.markets[symbol] ?? [0, 0];
  record.markets[symbol] = [round(bucket[0] + total), bucket[1] + 1];
  return [event.time, symbol, event.isLong ? 1 : 0, position?.entry ?? null, exit, total,
    holdSeconds, position?.lev ?? null, event.kind === "liquidated" ? 1 : 0];
}

/// Newest first, at most the recent window.
export function mergeTrades(existing, added) {
  return [...added].reverse().concat(existing ?? []).slice(0, RECENT_TRADES);
}

/// The figures a person reads, the tags that describe a style, and one score.
export function statistics(record) {
  const n = record.n;
  const winRate = n ? record.w / n : null;
  const profitFactor = record.gl > 0 ? record.gp / record.gl : (record.gp > 0 ? null : 0);
  const averageHold = record.holdN ? record.hold / record.holdN : null;
  const averageLeverage = record.levN ? record.lev / record.levN : null;
  const markets = Object.entries(record.markets).map(([symbol, [pnl, count]]) => ({ symbol, pnl, count }));
  const best = markets.length ? markets.reduce((a, b) => (b.pnl > a.pnl ? b : a)) : null;
  const worst = markets.length ? markets.reduce((a, b) => (b.pnl < a.pnl ? b : a)) : null;
  const busiest = markets.length ? markets.reduce((a, b) => (b.count > a.count ? b : a)) : null;
  const opens = record.longs + record.shorts;

  const tags = [];
  if (averageHold != null) {
    if (averageHold < 15 * 60) tags.push("Scalper");
    else if (averageHold < 24 * 3600) tags.push("Day trader");
    else tags.push("Swing trader");
  }
  if (averageLeverage != null && averageLeverage >= 10) tags.push("High leverage");
  else if (averageLeverage != null && averageLeverage <= 3) tags.push("Low leverage");
  if (busiest && n >= 5 && busiest.count / n >= 0.6) tags.push(`${busiest.symbol} specialist`);
  if (opens >= 5 && record.longs / opens >= 0.75) tags.push("Long-biased");
  if (opens >= 5 && record.shorts / opens >= 0.75) tags.push("Short-biased");
  if (record.liq > 0) tags.push(record.liq === 1 ? "Liquidated once" : `Liquidated ${record.liq}×`);

  return {
    trades: n, wins: record.w, losses: record.l,
    winRate, profitFactor, realised: round(record.cum, 2), grossProfit: round(record.gp, 2), grossLoss: round(record.gl, 2),
    maxDrawdown: round(record.dd, 2), bestStreak: record.bestStreak, worstStreak: -record.worstStreak, currentStreak: record.streak,
    averageHoldSeconds: averageHold, averageLeverage, liquidations: record.liq, volume: round(record.vol, 2),
    funding: round(record.funding, 2), since: record.first, lastActive: record.last,
    bestMarket: best && best.pnl > 0 ? best : null, worstMarket: worst && worst.pnl < 0 ? worst : null,
    tags, score: score(record),
  };
}

/// 0–100. Win rate, profit factor and drawdown against what was won, weighted by how many
/// trades back them and how much money moved, less a penalty for each liquidation. A lucky
/// handful of trades, or hundreds of trades worth cents, cannot outrank a real record.
export function score(record) {
  if (!record.n) return null;
  const winRate = record.w / record.n;
  const profitFactor = record.gl > 0 ? Math.min(record.gp / record.gl, 3) : (record.gp > 0 ? 3 : 0);
  const drawdown = Math.min(record.dd / Math.max(record.gp, 1), 1);
  const raw = 45 * winRate + 35 * (profitFactor / 3) + 20 * (1 - drawdown);
  const confidence = Math.min(1, record.n / 20) * Math.min(1, (record.gp + record.gl) / 250);
  return Math.max(0, Math.min(100, Math.round(raw * confidence - Math.min(record.liq * 5, 25))));
}

const duration = (seconds) => {
  if (seconds == null) return null;
  if (seconds < 3600) return `${Math.max(1, Math.round(seconds / 60))} min`;
  if (seconds < 86_400) return `${Math.round(seconds / 3600)} h`;
  return `${Math.round(seconds / 86_400)} d`;
};

/// A sentence built only from the figures, so it can never claim what the data does not show.
export function describe(stats) {
  if (!stats.trades) return "No closed trades on record yet.";
  const parts = [];
  const style = stats.tags.find((tag) => /Scalper|Day trader|Swing trader/.test(tag));
  const hold = duration(stats.averageHoldSeconds);
  parts.push(`${style ?? "Trader"}${hold ? ` holding about ${hold}` : ""}${stats.averageLeverage ? ` at ${stats.averageLeverage.toFixed(1)}× on average` : ""}.`);
  parts.push(`Wins ${Math.round(stats.winRate * 100)}% of ${stats.trades} closed trades${stats.bestMarket ? `, best on ${stats.bestMarket.symbol}` : ""}.`);
  if (stats.maxDrawdown > 0 && stats.grossProfit > 0) {
    const ratio = stats.maxDrawdown / stats.grossProfit;
    parts.push(ratio < 0.25 ? "Keeps drawdowns small." : ratio > 0.75 ? "Gives back a lot on bad runs." : "Drawdowns are moderate.");
  }
  if (stats.liquidations) parts.push(`Has been liquidated ${stats.liquidations === 1 ? "once" : `${stats.liquidations} times`}.`);
  return parts.join(" ");
}

/// Reads position events from HyperSync, folds them into the shards, and advances the
/// cursor. Stops at the deadline and resumes from the cursor on the next run.
export async function indexHistory({ store, hypersync, markets, now = Date.now, deadline }) {
  const height = await hypersync.height();
  const tip = height - FINALITY_LAG;
  let cursor = Number(await store.get("hist:cursor")) || Math.max(0, tip - BACKFILL_BLOCKS);
  const start = cursor;
  if (cursor >= tip) return { from: start, to: cursor, events: 0, accounts: 0, behind: 0 };

  const shards = (await store.mget(Array.from({ length: SHARDS }, (_, index) => shardKey(index))))
    .map((raw) => (raw ? JSON.parse(raw) : {}));
  const touched = new Set();
  const completed = new Map();
  let events = 0;

  while (cursor < tip && now() < deadline) {
    const page = await hypersync.query({ from: cursor, to: tip, topics: Object.values(TOPICS) });
    const timestamps = new Map(page.blocks.map((block) => [Number(block.number), Number(block.timestamp)]));
    for (const log of page.logs) {
      const event = decodeEvent(log, timestamps);
      if (!event) continue;
      const shard = shardOf(event.account);
      const record = shards[shard][event.account] ?? emptyRecord();
      const trade = applyEvent(record, event, markets.get(event.perp));
      if (trade) completed.set(event.account, [...(completed.get(event.account) ?? []), trade]);
      shards[shard][event.account] = record;
      touched.add(shard);
      events += 1;
    }
    if (!(page.nextBlock > cursor)) break;
    cursor = page.nextBlock;
  }

  const accounts = [...completed.keys()];
  const previous = await store.mget(accounts.map(tradesKey));
  await store.setMany([
    ...[...touched].map((shard) => [shardKey(shard), JSON.stringify(shards[shard])]),
    ...accounts.map((account, index) => [
      tradesKey(account),
      JSON.stringify(mergeTrades(previous[index] ? JSON.parse(previous[index]) : [], completed.get(account))),
    ]),
    ["hist:cursor", String(cursor)],
    ["hist:leaders", JSON.stringify(leaders(shards))],
  ], 30 * 24 * 3600);
  return { from: start, to: cursor, events, accounts: accounts.length, behind: tip - cursor };
}

/// The best-scoring accounts with enough trades to mean something.
export function leaders(shards, limit = 50) {
  const rows = [];
  for (const shard of shards) {
    for (const [account, record] of Object.entries(shard)) {
      if (record.n < 5) continue;
      rows.push({ account, address: record.addr, score: score(record), trades: record.n,
        winRate: record.w / record.n, realised: round(record.cum, 2) });
    }
  }
  return rows.sort((a, b) => b.score - a.score || b.realised - a.realised).slice(0, limit);
}

export function hypersyncClient({ token = process.env.HYPERSYNC_TOKEN, url = "https://143.hypersync.xyz", fetchImpl = fetch } = {}) {
  if (!token) return null;
  const headers = { "content-type": "application/json", authorization: `Bearer ${token.trim()}` };
  return {
    async height() {
      const response = await fetchImpl(`${url}/height`, { headers });
      if (!response.ok) throw new Error(`hypersync ${response.status}`);
      return Number((await response.json()).height);
    },
    async query({ from, to, topics, exchange = "0x34B6552d57a35a1D042CcAe1951BD1C370112a6F" }) {
      const response = await fetchImpl(`${url}/query`, {
        method: "POST",
        headers,
        body: JSON.stringify({
          from_block: from,
          to_block: to,
          logs: [{ address: [exchange], topics: [topics] }],
          field_selection: { log: ["block_number", "data", "topic0"], block: ["number", "timestamp"] },
        }),
      });
      if (!response.ok) throw new Error(`hypersync ${response.status}`);
      const body = await response.json();
      const batches = Array.isArray(body.data) ? body.data : [body.data ?? {}];
      return {
        logs: batches.flatMap((batch) => batch.logs ?? []),
        blocks: batches.flatMap((batch) => batch.blocks ?? []),
        nextBlock: Number(body.next_block),
      };
    },
  };
}
