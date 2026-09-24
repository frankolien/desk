import { ledgerKey, TRACKED_KEY } from "./_ledger.mjs";
import { currentPrices } from "./_wallet.mjs";
import { compactUsd } from "./_watch.mjs";

export const WINDOWS = { "1h": 3_600_000, "6h": 21_600_000, "24h": 86_400_000 };
export const DEFAULT_WINDOW = "6h";
export const EXCLUDED_SYMBOLS = new Set(["MON", "WMON", "USDC", "USDT", "AUSD", "USDE", "SUSDE", "SHMON", "GMON", "APRMON", "SMON"]);
export const MIN_BUY_USD = 100;
export const MIN_BUYERS = 2;
export const MIN_SCORE = 50;
export const STRONG_SCORE = 75;
export const CONCENTRATION_LIMIT = 0.7;
const LEADERS = 50;
const MAX_SIGNALS = 25;
const QUALIFY_TRADES = 20;
const QUALIFY_WIN_RATE = 0.55;
const BOT_TRADES_24H = 200;
const CACHE_S = 60;
const MGET_CHUNK = 100;

export const signalsKey = (window) => `signals:${window}`;

export function scoreToken({ buyers, netUsd, firstBuyShare, ageMs, windowMs, concentration }) {
  const fromBuyers = Math.min(40, 10 * buyers);
  const fromInflow = netUsd < 500 ? 0 : Math.max(0, Math.min(25, Math.round(5 + 10 * Math.log10(netUsd / 500))));
  const fromFirst = firstBuyShare * 15;
  const fromFreshness = 20 * Math.exp(-ageMs / (windowMs / 2));
  const penalty = concentration > CONCENTRATION_LIMIT ? 30 : 0;
  return Math.max(0, Math.min(100, Math.round(fromBuyers + fromInflow + fromFirst + fromFreshness - penalty)));
}

const windowWords = { "1h": "hour", "6h": "6 hours", "24h": "24 hours" };

export function sentence({ symbol, buyers, netUsd, window }) {
  const span = windowWords[window] ?? window;
  if (netUsd < 0) return `Smart money is leaving ${symbol} · −${compactUsd(netUsd)} net in the last ${span}`;
  return `${buyers} top trader${buyers === 1 ? "" : "s"} bought ${symbol} in the last ${span} · +${compactUsd(netUsd)} net`;
}

const winRate = (ledger) => {
  const decided = (ledger.wins ?? 0) + (ledger.losses ?? 0);
  return decided ? ledger.wins / decided : 0;
};

export function isBot(ledger, now) {
  const since = now - WINDOWS["24h"];
  return ledger.trades.filter((trade) => trade.time >= since).length > BOT_TRADES_24H;
}

async function mgetChunked(store, keys) {
  const out = [];
  for (let index = 0; index < keys.length; index += MGET_CHUNK) {
    out.push(...await store.mget(keys.slice(index, index + MGET_CHUNK)));
  }
  return out;
}

/// Ledgers of every wallet worth listening to, keyed by address.
export async function qualifiedLedgers({ store, now }) {
  const [leadersRaw, subscriptionIds, trackedList] = await Promise.all([
    store.get("hist:leaders"), store.smembers("alerts:subs"), store.smembers(TRACKED_KEY),
  ]);
  const trusted = new Set();
  for (const row of JSON.parse(leadersRaw ?? "[]").slice(0, LEADERS)) {
    if (typeof row.address === "string" && row.address) trusted.add(row.address.toLowerCase());
  }
  const records = await mgetChunked(store, subscriptionIds.map((id) => `alerts:sub:${id}`));
  for (const raw of records) {
    if (!raw) continue;
    for (const wallet of JSON.parse(raw).wallets ?? []) trusted.add(String(wallet.address).toLowerCase());
  }
  const tracked = new Set(trackedList.map((address) => String(address).toLowerCase()));
  const candidates = [...new Set([...trusted, ...tracked])];
  const ledgers = await mgetChunked(store, candidates.map(ledgerKey));

  const qualified = new Map();
  candidates.forEach((address, index) => {
    if (!ledgers[index]) return;
    const ledger = JSON.parse(ledgers[index]);
    if (!Array.isArray(ledger.trades)) return;
    const proven = ledger.trades.length >= QUALIFY_TRADES && winRate(ledger) >= QUALIFY_WIN_RATE;
    if (!trusted.has(address) && !proven) return;
    if (isBot(ledger, now)) return;
    qualified.set(address, ledger);
  });
  return qualified;
}

/// Per-token flows from the qualified ledgers inside the window.
export function aggregateTokens(ledgers, { now, windowMs }) {
  const since = now - windowMs;
  const tokens = new Map();
  for (const [address, ledger] of ledgers) {
    const seenBefore = new Set();
    ledger.trades.forEach((trade) => {
      const earlier = seenBefore.has(trade.token);
      seenBefore.add(trade.token);
      if (trade.time < since || trade.time > now) return;
      const entry = tokens.get(trade.token) ?? {
        token: trade.token, symbol: trade.symbol, buyersInflow: new Map(), sellsUsd: 0, buys: 0, firstBuys: 0, lastBuy: 0,
      };
      entry.symbol = trade.symbol ?? entry.symbol;
      if (trade.side === "sell") {
        entry.sellsUsd += trade.value;
      } else if (trade.side === "buy" && trade.value >= MIN_BUY_USD) {
        entry.buyersInflow.set(address, (entry.buyersInflow.get(address) ?? 0) + trade.value);
        entry.buys += 1;
        if (!earlier) entry.firstBuys += 1;
        entry.lastBuy = Math.max(entry.lastBuy, trade.time);
      }
      tokens.set(trade.token, entry);
    });
  }
  return [...tokens.values()].map((entry) => {
    const inflow = [...entry.buyersInflow.values()].reduce((sum, value) => sum + value, 0);
    const biggest = Math.max(0, ...entry.buyersInflow.values());
    return {
      token: entry.token,
      symbol: entry.symbol,
      buyers: [...entry.buyersInflow].sort((a, b) => b[1] - a[1]).map(([address]) => address),
      netUsd: inflow - entry.sellsUsd,
      firstBuyShare: entry.buys ? entry.firstBuys / entry.buys : 0,
      ageMs: entry.lastBuy ? Math.max(0, now - entry.lastBuy) : Infinity,
      concentration: inflow > 0 ? biggest / inflow : 0,
    };
  });
}



export async function computeSignals({ store, now = Date.now(), window = DEFAULT_WINDOW, prices = currentPrices }) {
  const windowMs = WINDOWS[window] ?? WINDOWS[DEFAULT_WINDOW];
  const ledgers = await qualifiedLedgers({ store, now });
  const ranked = aggregateTokens(ledgers, { now, windowMs })
    .filter((row) => !EXCLUDED_SYMBOLS.has(String(row.symbol ?? "").toUpperCase()))
    .filter((row) => row.buyers.length >= MIN_BUYERS)
    .map((row) => ({ ...row, score: scoreToken({ ...row, buyers: row.buyers.length, windowMs }) }))
    .filter((row) => row.score >= MIN_SCORE)
    .sort((a, b) => b.score - a.score || b.netUsd - a.netUsd)
    .slice(0, MAX_SIGNALS);
  let priced = new Map();
  try { priced = await prices("143", ranked.map((row) => row.token)); } catch { /* shown unpriced */ }
  return {
    observedAt: now,
    window,
    signals: ranked.map((row) => ({
      token: row.token,
      symbol: row.symbol,
      chainIndex: "143",
      score: row.score,
      strong: row.score >= STRONG_SCORE,
      summary: sentence({ symbol: row.symbol, buyers: row.buyers.length, netUsd: row.netUsd, window }),
      buyers: row.buyers.slice(0, 3).map((address) => ({ address })),
      distinct: row.buyers.length,
      netUsd: Math.round(row.netUsd * 100) / 100,
      firstBuyShare: Math.round(row.firstBuyShare * 1000) / 1000,
      warning: row.concentration > CONCENTRATION_LIMIT ? `1 wallet is ${Math.round(row.concentration * 100)}% of it` : null,
      price: priced.get(row.token) ?? null,
    })),
  };

}


export async function cachedSignals({ store, window = DEFAULT_WINDOW, now = Date.now(), prices }) {
  const key = signalsKey(window);
  const cached = await store.get(key).catch(() => null);
  if (cached) return JSON.parse(cached);
  const result = await computeSignals({ store, now, window, prices });
  await store.set(key, JSON.stringify(result), { ex: CACHE_S }).catch(() => {});
  return result;
}

