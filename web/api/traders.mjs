import { createPublicClient, http } from "viem";

import { describe, shardKey, shardOf, statistics, tradesKey } from "./_history.mjs";
import { EXCHANGE_VIEWS } from "./_perpl-abi.mjs";
import { redisStore } from "./_store.mjs";

/// Perpl mainnet, read-only. Following is about real traders, so it reads the live venue
/// even though Desk trades on testnet; nothing here signs or moves funds.
export const EXCHANGE = "0x34B6552d57a35a1D042CcAe1951BD1C370112a6F";
const CONTEXT_URL = "https://app.perpl.xyz/api/v1/pub/context";
const COLLATERAL_DECIMALS = 6;
const PAGE = 50n;
const MAX_PAGES = 30;
const TOP = 25;
const MAX_FOLLOWED = 20;

export function formatFixed(raw, decimals, places = decimals) {
  const value = BigInt(raw);
  const negative = value < 0n;
  const digits = (negative ? -value : value).toString().padStart(decimals + 1, "0");
  const whole = digits.slice(0, digits.length - decimals);
  const fraction = digits.slice(digits.length - decimals, digits.length - decimals + places).replace(/0+$/, "");
  return `${negative ? "-" : ""}${whole}${fraction ? `.${fraction}` : ""}`;
}

/// Perp ids with a position, from the account's four 256-bit banks.
export function perpIdsFromBitmap(positions) {
  const ids = [];
  ["bank1", "bank2", "bank3", "bank4"].forEach((bank, index) => {
    let bits = BigInt(positions?.[bank] ?? 0n);
    for (let bit = 0n; bits > 0n; bit += 1n, bits >>= 1n) {
      if (bits & 1n) ids.push(Number(BigInt(index * 256) + bit));
    }
  });
  return ids;
}

/// One open position as a person reads it. Leverage is entry notional over the
/// collateral posted, which is what the venue sized the position with.
export function describePosition(position, mark, market) {
  const { price_decimals: priceDecimals, size_decimals: sizeDecimals } = market.config;
  const lot = BigInt(position.lotLNS);
  const entry = BigInt(position.pricePNS);
  const deposit = BigInt(position.depositCNS);
  const pnl = BigInt(position.pnlCNS);
  // price * lot carries price + size decimals; collateral carries six.
  const shift = priceDecimals + sizeDecimals - COLLATERAL_DECIMALS;
  const notional = (price) => (shift >= 0
    ? (price * lot) / 10n ** BigInt(shift)
    : price * lot * 10n ** BigInt(-shift));
  const entryNotional = notional(entry);
  return {
    market: market.name,
    marketId: market.id,
    side: Number(position.positionType) === 1 ? "short" : "long",
    entry: formatFixed(entry, priceDecimals),
    mark: formatFixed(mark, priceDecimals),
    size: formatFixed(lot, sizeDecimals),
    collateral: formatFixed(deposit, COLLATERAL_DECIMALS, 2),
    value: formatFixed(notional(BigInt(mark)), COLLATERAL_DECIMALS, 2),
    pnl: formatFixed(pnl, COLLATERAL_DECIMALS, 2),
    pnlPercent: deposit > 0n ? Number((pnl * 10000n) / deposit) / 100 : null,
    leverage: deposit > 0n ? Number((entryNotional * 10n) / deposit) / 10 : null,
    entryBlock: Number(position.entryBlock),
  };
}

/// Traders ranked by what their open positions are making right now. Ties and empty
/// books are ordered by value so the list is stable between refreshes.
export function rankTraders(positions, limit = TOP) {
  const byAccount = new Map();
  for (const { accountId, raw, described } of positions) {
    const entry = byAccount.get(accountId) ?? { accountId, pnl: 0n, value: 0n, positions: [] };
    entry.pnl += BigInt(raw.pnlCNS);
    entry.value += BigInt(Math.round(Number(described.value) * 1e6));
    entry.positions.push(described);
    byAccount.set(accountId, entry);
  }
  return [...byAccount.values()]
    .sort((a, b) => (b.pnl === a.pnl ? Number(b.value - a.value) : (b.pnl > a.pnl ? 1 : -1)))
    .slice(0, limit);
}

let contextCache = { at: 0, markets: null };

export async function openMarkets(fetchImpl = fetch) {
  if (contextCache.markets && Date.now() - contextCache.at < 10 * 60_000) return contextCache.markets;
  const response = await fetchImpl(CONTEXT_URL);
  if (!response.ok) throw new Error("context");
  const body = await response.json();
  const open = new Map(body.markets.filter((m) => m.config?.is_open).map((m) => [m.id, m]));
  contextCache = { at: Date.now(), markets: open };
  return open;
}

function summary(accountId, address, pnl, positions, balance = null) {
  return {
    accountId: String(accountId),
    address,
    pnl: formatFixed(pnl, COLLATERAL_DECIMALS, 2),
    balance: balance === null ? null : formatFixed(balance, COLLATERAL_DECIMALS, 2),
    positions: positions.sort((a, b) => Number(b.value) - Number(a.value)),
  };
}

export function chainReader(rpcURL = process.env.MONAD_MAINNET_RPC || "https://rpc.monad.xyz") {
  const client = createPublicClient({ transport: http(rpcURL, { timeout: 10_000, batch: true }) });
  const read = (functionName, args) => client.readContract({ address: EXCHANGE, abi: EXCHANGE_VIEWS, functionName, args });

  return {
    async allPositions(market) {
      const out = [];
      let start = 0n;
      for (let page = 0; page < MAX_PAGES; page += 1) {
        const [rows, count, mark, valid] = await read("getPositionsV2", [BigInt(market.id), start, PAGE]);
        if (!valid) return out;
        for (const row of rows.slice(0, Number(count))) out.push({ row, mark });
        const last = rows[Number(count) - 1];
        if (BigInt(count) < PAGE || !last || last.nextNodeId === 0n) return out;
        start = last.nextNodeId;
      }
      return out;
    },
    async accountById(id) {
      return read("getAccountById", [BigInt(id)]);
    },
    async accountByAddress(address) {
      return read("getAccountByAddr", [address]);
    },
    /// Open whatever the mark says. A missing mark is not a closed position, and reading
    /// it as one would tell every follower the trader had left.
    async openPosition(perpId, accountId) {
      const [row, mark, valid] = await read("getPositionV2", [BigInt(perpId), BigInt(accountId)]);
      return row.lotLNS > 0n ? { row, mark: valid ? mark : row.pricePNS } : null;
    },
  };
}

/// One trader's book, or `unreadable` when the chain would not answer.
///
/// The distinction is the whole point: auto-copy diffs this against what it saw last time,
/// so a read that failed must never arrive as a trader holding nothing. That is a wave of
/// closes on positions the trader still holds.
/// A wallet with no Perpl account reverts; a chain that would not answer throws something
/// else. The first is a fact about the trader, the second is an absence of facts, and only
/// the second must stop auto-copy from diffing.
export function isRevert(error) {
  for (let cause = error; cause; cause = cause.cause) {
    if (cause.name === "ContractFunctionRevertedError" || cause.name === "ExecutionRevertedError") return true;
  }
  return false;
}

async function trader(chain, book, address) {
  let account;
  try {
    account = await chain.accountByAddress(address);
  } catch (error) {
    if (isRevert(error)) return null;
    return { unreadable: true };
  }
  if (!account || account.accountId === 0n) return null;
  const ids = perpIdsFromBitmap(account.positions).filter((id) => book.has(id));
  let found;
  try {
    // `openPosition`, not `position`: a mark the venue would not price is not a close.
    found = await Promise.all(ids.map((id) => chain.openPosition(id, account.accountId)));
  } catch {
    return { unreadable: true };
  }
  let pnl = 0n;
  const positions = [];
  found.forEach((entry, index) => {
    if (!entry) return;
    pnl += BigInt(entry.row.pnlCNS);
    positions.push(describePosition(entry.row, entry.mark, book.get(ids[index])));
  });
  return summary(account.accountId, account.accountAddr, pnl, positions, account.balanceCNS);
}

const validAddress = (value) => /^0x[a-fA-F0-9]{40}$/.test(value);

/// One sentence from a language model, grounded only in the figures, when a key is set.
/// Cached for a day so a popular profile costs one call, not one per view.
async function styleSummary({ store, fetchImpl, account, stats, apiKey = process.env.ANTHROPIC_API_KEY }) {
  if (!apiKey || !store || stats.trades < 5) return null;
  const cacheKey = `hist:ai:${account}:${stats.trades}`;
  const cached = await store.get(cacheKey).catch(() => null);
  if (cached) return cached;
  try {
    const response = await fetchImpl("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "content-type": "application/json", "x-api-key": apiKey, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({
        model: "claude-haiku-4-5",
        max_tokens: 120,
        system: "You describe a perpetual futures trader's style for a mobile trading app, in one or two short plain sentences (max 35 words). Use only the statistics given. No advice, no hype, no emojis, no numbers that are not in the data.",
        messages: [{ role: "user", content: JSON.stringify({
          trades: stats.trades, winRate: stats.winRate, profitFactor: stats.profitFactor, realisedAUSD: stats.realised,
          maxDrawdownAUSD: stats.maxDrawdown, averageHoldMinutes: stats.averageHoldSeconds && Math.round(stats.averageHoldSeconds / 60),
          averageLeverage: stats.averageLeverage, bestMarket: stats.bestMarket?.symbol, worstMarket: stats.worstMarket?.symbol,
          liquidations: stats.liquidations, tags: stats.tags,
        }) }],
      }),
    });
    if (!response.ok) return null;
    const text = (await response.json()).content?.find((part) => part.type === "text")?.text?.trim();
    if (text) await store.set(cacheKey, text, { ex: 24 * 3600 }).catch(() => {});
    return text ?? null;
  } catch {
    return null;
  }
}

export function createHandler({ chain = chainReader(), fetchImpl = fetch, store = redisStore() } = {}) {
  return async function handler(req, res) {
    if (req.method !== "GET") return res.status(405).json({ error: "GET required" });
    const view = String(req.query.view || "top");

    if (view === "history" || view === "scores") {
      if (!store) return res.status(503).json({ error: "Trader history isn't configured on this server." });
      try {
        if (view === "scores") {
          const leaders = JSON.parse(await store.get("hist:leaders") ?? "[]").slice(0, 25);
          const accounts = await Promise.all(leaders.map((row) => chain.accountById(row.account).catch(() => null)));
          res.setHeader("Cache-Control", "public, s-maxage=300, stale-while-revalidate=900");
          return res.status(200).json({
            traders: leaders.map((row, index) => ({ ...row, address: accounts[index]?.accountAddr ?? row.address }))
              .filter((row) => row.address),
          });
        }
        const address = String(req.query.address ?? "");
        if (!validAddress(address)) return res.status(400).json({ error: "A wallet address is required." });
        const account = await chain.accountByAddress(address);
        if (!account || account.accountId === 0n) return res.status(200).json({ address, stats: null, trades: [] });
        const id = account.accountId.toString();
        const [shard, trades] = await store.mget([shardKey(shardOf(id)), tradesKey(id)]);
        const record = shard ? JSON.parse(shard)[id] : null;
        if (!record) return res.status(200).json({ address, accountId: id, stats: null, trades: [] });
        const stats = statistics(record);
        const ai = await styleSummary({ store, fetchImpl, account: id, stats });
        res.setHeader("Cache-Control", "public, s-maxage=120, stale-while-revalidate=600");
        return res.status(200).json({
          address, accountId: id, stats, summary: ai ?? describe(stats), summarySource: ai ? "ai" : "figures",
          trades: (trades ? JSON.parse(trades) : []).map(([time, market, long, entry, exit, pnl, hold, leverage, liquidated]) => ({
            time, market, side: long ? "long" : "short", entry, exit, pnl, holdSeconds: hold, leverage, liquidated: Boolean(liquidated),
          })),
        });
      } catch {
        return res.status(502).json({ error: "Trader history could not be read right now." });
      }
    }

    let book;
    try {
      book = await openMarkets(fetchImpl);
    } catch {
      return res.status(502).json({ error: "Perpl's market list is unavailable." });
    }

    try {
      if (view === "top") {
        const scanned = await Promise.all([...book.values()].map(async (market) =>
          (await chain.allPositions(market)).map(({ row, mark }) => ({
            accountId: row.accountId, raw: row, described: describePosition(row, mark, market),
          }))));
        const ranked = rankTraders(scanned.flat());
        const accounts = await Promise.all(ranked.map((entry) => chain.accountById(entry.accountId)));
        res.setHeader("Cache-Control", "public, s-maxage=60, stale-while-revalidate=300");
        return res.status(200).json({
          observedAt: Date.now(),
          traders: ranked.map((entry, index) =>
            summary(entry.accountId, accounts[index].accountAddr, entry.pnl, entry.positions)),
        });
      }

      if (view === "trader" || view === "following") {
        const addresses = String(req.query.addresses ?? req.query.address ?? "")
          .split(",").map((value) => value.trim()).filter(Boolean);
        if (addresses.length === 0 || addresses.length > MAX_FOLLOWED || !addresses.every(validAddress)) {
          return res.status(400).json({ error: `Between 1 and ${MAX_FOLLOWED} wallet addresses are required.` });
        }
        const traders = await Promise.all(addresses.map((address) => trader(chain, book, address)));
        // Auto-copy asks for a reading no older than the request itself. Private either
        // way: the addresses are in the URL, so a shared cache would hold one person's
        // follow list keyed by exactly the tuple that identifies them.
        res.setHeader("Cache-Control", req.query.fresh === "1"
          ? "private, no-store" : "private, max-age=10");
        return res.status(200).json({
          observedAt: Date.now(),
          traders: traders.map((found, index) => found?.unreadable
            ? { address: addresses[index], accountId: null, positions: [], unreadable: true }
            : found ?? { address: addresses[index], accountId: null, positions: [] }),
        });
      }
      return res.status(400).json({ error: "Unknown view." });
    } catch {
      return res.status(502).json({ error: "Perpl mainnet could not be read right now." });
    }
  };
}

let defaultHandler;
export default function handler(req, res) {
  defaultHandler ??= createHandler();
  return defaultHandler(req, res);
}
