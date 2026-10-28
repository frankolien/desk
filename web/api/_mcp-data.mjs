/// What the MCP tools read, and how each answer is cut down for a model and a card.
/// Reads go through Desk's own public API, so they share the edge cache and the last-good
/// answers the app already uses; nothing here signs, trades or writes.

import { CHAINS } from "./_chains.mjs";

export const SITE = "https://trydesk.trade";
const OLD_API_HOST = "https://web-lovat-nine-49.vercel.app";

/// Images a card may load. The tools drop every other image URL, so the card's CSP and what
/// it actually loads are the same list.
export const IMAGE_HOSTS = [
  "https://static.oklink.com",
  "https://assets.coingecko.com",
  "https://coin-images.coingecko.com",
  "https://raw.githubusercontent.com",
  "https://storage.nadapp.net",
  "https://euc.li",
  "https://imagedelivery.net",
  SITE,
];

const SLUGS = {
  "143": "monad", "1": "ethereum", "8453": "base", "56": "bnb", "42161": "arbitrum", "10": "optimism",
  "137": "polygon", "501": "solana", "43114": "avalanche", "146": "sonic", "59144": "linea", "534352": "scroll",
  "80094": "berachain", "5000": "mantle", "130": "unichain", "2741": "abstract", "57073": "ink", "999": "hyperevm",
  "480": "worldchain", "9745": "plasma", "4663": "robinhood", "196": "xlayer", "4217": "tempo", "5042": "arc",
};
export const CHAIN_SLUGS = Object.values(SLUGS);
const INDEX_BY_SLUG = Object.fromEntries(Object.entries(SLUGS).map(([index, slug]) => [slug, index]));

export const chainIndexOf = (slug) => INDEX_BY_SLUG[String(slug ?? "").toLowerCase()] ?? null;
export const chainSlugOf = (index) => SLUGS[String(index)] ?? null;
const chainLabel = (index) => CHAINS[String(index)]?.name ?? `Chain ${index}`;

export const EVM_ADDRESS = /^0x[0-9a-fA-F]{40}$/;
export const SOLANA_ADDRESS = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;

/// A refusal the model can repeat to the person as it is.
export class DeskDataError extends Error {}

const num = (value) => {
  if (value === null || value === undefined || value === "") return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
};
const round = (value, places = 2) => {
  const n = num(value);
  return n == null ? null : Math.round(n * 10 ** places) / 10 ** places;
};
/// Prices of meme tokens live far below a cent; six significant digits keep them readable.
const price = (value) => {
  const n = num(value);
  if (n == null) return null;
  if (n === 0 || Math.abs(n) >= 1) return round(n, 4);
  return Number(n.toPrecision(6));
};
const iso = (ms) => (Number.isFinite(ms) && ms > 0 ? new Date(ms).toISOString() : null);

export function image(url) {
  if (typeof url !== "string" || !url.startsWith("https://")) return null;
  const fixed = url.startsWith(OLD_API_HOST) ? SITE + url.slice(OLD_API_HOST.length) : url;
  try {
    const origin = new URL(fixed).origin;
    return IMAGE_HOSTS.includes(origin) ? fixed : null;
  } catch {
    return null;
  }
}

export const links = {
  wallet: (address) => `${SITE}/app/wallet/${address}`,
  token: (chainIndex, contract) => `${SITE}/app/token/${chainIndex}/${contract}`,
  market: (name) => `${SITE}/app/trade/${encodeURIComponent(name)}`,
  traders: () => `${SITE}/app/traders`,
  markets: () => `${SITE}/app/markets`,
};

/// Desk's public API, read with a deadline. Each failure becomes a sentence for the person.
export function deskApi({ base = process.env.MCP_API_BASE || SITE, fetchImpl = fetch, timeoutMs = 12_000 } = {}) {
  return async function get(path, query = {}, { timeout = timeoutMs, missing = null } = {}) {
    const search = new URLSearchParams(Object.entries(query).filter(([, v]) => v !== undefined && v !== null && v !== "")).toString();
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeout);
    let response;
    try {
      response = await fetchImpl(`${base}${path}${search ? `?${search}` : ""}`, {
        headers: { accept: "application/json", "user-agent": "desk-mcp/1" }, signal: controller.signal,
      });
    } catch (error) {
      throw new DeskDataError(error?.name === "AbortError"
        ? "Desk's market data took too long to answer. Try again in a moment."
        : "Desk's market data could not be reached. Try again in a moment.");
    } finally {
      clearTimeout(timer);
    }
    const body = await response.json().catch(() => null);
    if (response.status === 404 && missing) throw new DeskDataError(missing);
    if (!response.ok) throw new DeskDataError(body?.error ? `Desk could not read that: ${body.error}` : "Desk's market data is unavailable right now. Try again in a moment.");
    return body;
  };
}

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// MARK: Wallets

/// An address as given, or the wallet a name points to (ENS, .nad, Desk @tag, Farcaster, .sol).
export async function resolveWallet(get, input) {
  const text = String(input ?? "").trim();
  if (EVM_ADDRESS.test(text)) return { address: text.toLowerCase(), via: "address" };
  if (SOLANA_ADDRESS.test(text)) return { address: text, via: "address" };
  if (!text || text.length > 80) throw new DeskDataError("Give a wallet address, or a name such as vitalik.eth or a .nad name.");
  const found = await get("/api/traders", { view: "lookup", q: text }, { missing: `No wallet answers to "${text}".` });
  if (!found?.address) throw new DeskDataError(`No wallet answers to "${text}".`);
  return { address: EVM_ADDRESS.test(found.address) ? found.address.toLowerCase() : found.address, via: found.via ?? null };
}

export async function loadWallet(get, input, { now = Date.now, pause = wait } = {}) {
  const { address } = await resolveWallet(get, input);
  const query = { view: "wallet", address, chainIndex: "143", contract: "" };
  let resource = await get("/api/activity", query, { timeout: 25_000 });
  // A held copy older than two minutes is rebuilding; one more ask usually gets the new one.
  if (resource?.refreshing && (resource.ageMs ?? 0) > 120_000) {
    await pause(2_500);
    resource = await get("/api/activity", query, { timeout: 25_000 }).catch(() => resource);
  }
  const [perps, leftOut] = await Promise.all([
    resource?.desk?.account && EVM_ADDRESS.test(address)
      ? get("/api/traders", { view: "trader", address }).then((view) => view?.traders?.[0] ?? null).catch(() => null)
      : null,
    unsellable(get, resource?.holdings ?? []),
  ]);
  return shapeWallet(resource, perps, { now, leftOut });
}

/// Airdropped spam carries a price but no market: no pool, no volume, nobody to sell to. A
/// holding like that, or one worth twenty times its whole pool, can't be turned into dollars,
/// so it is left out of the totals rather than reported as wealth.
export async function unsellable(get, holdings) {
  const candidates = holdings
    .filter((row) => row.contract && (num(row.value) ?? 0) >= 1_000)
    .sort((a, b) => (num(b.value) ?? 0) - (num(a.value) ?? 0))
    .slice(0, 20);
  if (!candidates.length) return [];
  const answer = await get("/api/token-details", {
    view: "prices", tokens: candidates.map((row) => `${row.chainIndex}:${row.contract}`).join(","),
  }, { timeout: 5_000 }).catch(() => null);
  if (!answer?.prices) return [];
  const market = new Map(answer.prices.map((row) => [`${row.chainIndex}:${String(row.contract).toLowerCase()}`, row]));
  const out = [];
  for (const row of candidates) {
    const quote = market.get(`${row.chainIndex}:${String(row.contract).toLowerCase()}`);
    if (!quote) continue;
    const liquidity = num(quote.liquidity) ?? 0;
    const volume = num(quote.volume24H) ?? 0;
    const value = num(row.value) ?? 0;
    const reason = liquidity <= 0 && volume <= 0 ? "no market" : liquidity > 0 && value > 20 * liquidity ? "worth far more than its pool" : null;
    if (reason) out.push({ chainIndex: String(row.chainIndex), contract: String(row.contract).toLowerCase(), symbol: String(row.symbol ?? ""), value, reason });
  }
  return out;
}

export function shapeWallet(resource, perps = null, { now = Date.now, leftOut = [] } = {}) {
  if (!resource?.address) throw new DeskDataError("That wallet could not be read right now.");
  const identity = resource.identity ?? {};
  const ledger = resource.ledger ?? {};
  const logos = resource.logos ?? {};
  const dropped = new Set(leftOut.map((row) => `${row.chainIndex}:${row.contract}`));
  const kept = (row) => !dropped.has(`${row.chainIndex}:${String(row.contract ?? "").toLowerCase()}`);
  const holdings = (resource.holdings ?? [])
    .filter((row) => kept(row) && (num(row.value) ?? 0) >= 1)
    .sort((a, b) => (num(b.value) ?? 0) - (num(a.value) ?? 0))
    .slice(0, 10)
    .map((row) => ({
      chain: chainSlugOf(row.chainIndex) ?? String(row.chainIndex), symbol: String(row.symbol ?? ""),
      contract: row.contract || null, balance: round(row.balance, 6), valueUsd: round(row.value),
    }));
  const trades = (ledger.trades ?? []).slice(0, 10).map((trade) => ({
    time: iso(trade.time), side: trade.side === "sell" ? "sell" : "buy", symbol: String(trade.symbol ?? ""),
    token: String(trade.token ?? ""), valueUsd: round(trade.value), gainUsd: trade.side === "sell" ? round(trade.gain) : null,
  }));
  const ratio = (value) => (num(value) == null ? null : round(num(value) * 100, 1));
  const window = (w) => (w ? { realizedUsd: round(w.realized), trades: num(w.trades) ?? 0, winRatePercent: ratio(w.winRate) } : null);
  const positions = (perps?.positions ?? []).map((p) => ({
    market: String(p.market), side: p.side === "short" ? "short" : "long", sizeUsd: round(p.value), entryPrice: price(p.entry),
    markPrice: price(p.mark), pnlUsd: round(p.pnl), pnlPercent: round(p.pnlPercent), leverage: round(p.leverage, 1),
  }));
  const shaped = {
    address: resource.address,
    name: identity.name ?? null,
    nameSource: identity.name ? (identity.source ?? null) : null,
    x: identity.x ?? null,
    portfolioUsd: num(resource.portfolio) == null ? null
      : round(Math.max(0, num(resource.portfolio) - leftOut.reduce((sum, row) => sum + row.value, 0))),
    chains: (resource.chains ?? [])
      .map((row) => ({
        chain: chainSlugOf(row.chainIndex) ?? String(row.chainIndex),
        valueUsd: round((num(row.value) ?? 0) - leftOut.filter((x) => x.chainIndex === String(row.chainIndex)).reduce((sum, x) => sum + x.value, 0)),
      }))
      .filter((row) => (row.valueUsd ?? 0) >= 1)
      .sort((a, b) => b.valueUsd - a.valueUsd)
      .slice(0, 8),
    holdings,
    leftOut: leftOut.map((row) => ({ chain: chainSlugOf(row.chainIndex) ?? row.chainIndex, symbol: row.symbol, contract: row.contract, reason: row.reason })),
    monadTrading: {
      status: ["ready", "indexing", "unavailable"].includes(ledger.status) ? ledger.status : "unavailable",
      realizedUsd: round(ledger.realized), unrealizedUsd: round(ledger.unrealized), winRatePercent: ratio(ledger.winRate),
      last7d: window(ledger.last7d), last30d: window(ledger.last30d), recentTrades: trades,
    },
    perps: perps ? {
      account: String(perps.accountId ?? resource.desk?.account ?? ""), unrealizedPnlUsd: round(perps.pnl),
      collateralUsd: round(resource.desk?.collateral), positions,
    } : null,
    labels: (resource.labels ?? []).map((label) => String(label.text ?? "")).filter(Boolean),
    asOf: iso(num(resource.observedAt) ?? now()),
    url: links.wallet(resource.address),
  };
  const art = {};
  for (const row of holdings) {
    const index = chainIndexOf(row.chain);
    const url = image(logos[`${index}:${row.contract ?? ""}`] ?? logos[`${index}:${(row.contract ?? "").toLowerCase()}`]);
    if (url) art[`${row.chain}:${row.contract ?? ""}`] = url;
  }
  for (const trade of trades) {
    const url = image(logos[`143:${trade.token}`]);
    if (url) art[`monad:${trade.token}`] = url;
  }
  return { data: shaped, images: { avatar: image(identity.avatar), tokens: art } };
}

// MARK: Tokens

function shapeListed(row) {
  return {
    chain: chainSlugOf(row.chainIndex) ?? String(row.chainIndex),
    contract: String(row.contract ?? ""),
    symbol: String(row.symbol ?? ""),
    name: String(row.name ?? ""),
    priceUsd: price(row.price),
    change24hPercent: round(row.change),
    marketCapUsd: round(row.marketCap, 0),
    liquidityUsd: round(row.liquidity, 0),
    volume24hUsd: round(row.volume24H, 0),
    // Search answers carry 0 for a count they don't have.
    holders: num(row.holders) || null,
    url: links.token(row.chainIndex, row.contract),
  };
}

const listImages = (rows) => Object.fromEntries(rows
  .map((row) => [`${chainSlugOf(row.chainIndex) ?? row.chainIndex}:${row.contract}`, image(row.logoURL)])
  .filter(([, url]) => url));

export async function searchTokens(get, { query, chain = null }) {
  const text = String(query ?? "").trim();
  if (!text) throw new DeskDataError("Give a token name, symbol or contract address to search for.");
  const body = await get("/api/token-discovery", { q: text.slice(0, 80) });
  const wanted = chain ? chainIndexOf(chain) : null;
  const rows = (body?.tokens ?? []).filter((row) => row.contract && (!wanted || String(row.chainIndex) === wanted)).slice(0, 10);
  return { data: { query: text, tokens: rows.map(shapeListed) }, images: { tokens: listImages(rows) } };
}

export async function trendingTokens(get, { chain = "monad", now = Date.now } = {}) {
  const index = chain === "all" ? null : chainIndexOf(chain);
  if (chain !== "all" && !index) throw new DeskDataError(`Desk doesn't list tokens on "${chain}".`);
  const body = await get("/api/token-discovery", index ? { chain: index } : {});
  const rows = (body?.tokens ?? []).filter((row) => row.contract).slice(0, 15);
  return {
    data: { chain: index ? chainSlugOf(index) : "all", tokens: rows.map(shapeListed), asOf: iso(num(body?.observedAt) ?? now()) },
    images: { tokens: listImages(rows) },
  };
}

/// How many bars each interval shows: two days of hours, a week of four-hour bars, a month of days.
export const INTERVALS = { "1H": 48, "4H": 42, "1D": 30 };

function tokenKey(chain, contract) {
  const index = chainIndexOf(chain);
  if (!index) throw new DeskDataError(`Desk doesn't cover tokens on "${chain}".`);
  const address = String(contract ?? "").trim();
  if (!(EVM_ADDRESS.test(address) || (index === "501" && SOLANA_ADDRESS.test(address)))) {
    throw new DeskDataError("That isn't a token contract address on that chain.");
  }
  return { index, contract: index === "501" ? address : address.toLowerCase() };
}

export async function loadToken(get, { chain, contract, candles = null, now = Date.now }) {
  const key = tokenKey(chain, contract);
  const [listing, details, risk, chart] = await Promise.all([
    get("/api/token-discovery", { q: key.contract }).catch(() => null),
    get("/api/token-details", { chainIndex: key.index, address: key.contract }),
    get("/api/token-details", { view: "risk", chainIndex: key.index, address: key.contract }).catch(() => null),
    candles ? loadCandles(get, { chain, contract: key.contract, interval: candles }).catch(() => null) : null,
  ]);
  return { ...shapeToken({ index: key.index, contract: key.contract, listing, details, risk, now }), candles: chart?.data?.candles ?? [] };
}

export async function loadCandles(get, { chain, contract, interval = "1H" }) {
  const key = tokenKey(chain, contract);
  const bars = INTERVALS[interval];
  if (!bars) throw new DeskDataError("Intervals are 1H, 4H or 1D.");
  const body = await get("/api/market-snapshot", { chainIndex: key.index, address: key.contract, period: interval, limit: "1" });
  const candles = (Array.isArray(body?.candles) ? body.candles : [])
    .map((row) => (Array.isArray(row) ? { time: num(row[0]), open: price(row[1]), high: price(row[2]), low: price(row[3]), close: price(row[4]) } : null))
    .filter((bar) => bar && bar.time && [bar.open, bar.high, bar.low, bar.close].every((v) => v != null))
    .sort((a, b) => a.time - b.time)
    .slice(-bars)
    .map((bar) => ({ ...bar, time: iso(bar.time) }));
  if (!candles.length) throw new DeskDataError("Desk has no price history for that token yet.");
  return { data: { chain: chainSlugOf(key.index), contract: key.contract, interval, candles } };
}

export function shapeToken({ index, contract, listing, details, risk, now = Date.now }) {
  const info = details?.priceInfo;
  if (!info) throw new DeskDataError("Desk has no market data for that token.");
  const same = (row) => String(row.chainIndex) === index && String(row.contract ?? "").toLowerCase() === contract.toLowerCase();
  const listed = (listing?.tokens ?? []).find(same) ?? null;
  const holders = Array.isArray(details.holders) ? details.holders : [];
  const topTen = holders.slice(0, 10).reduce((sum, row) => sum + (num(row.holdPercent) ?? 0), 0);
  const token = {
    chain: chainSlugOf(index),
    chainName: chainLabel(index),
    contract,
    symbol: String(listed?.symbol ?? details.symbol ?? ""),
    name: String(listed?.name ?? ""),
    priceUsd: price(info.price),
    changePercent: { "5m": round(info.priceChange5M), "1h": round(info.priceChange1H), "4h": round(info.priceChange4H), "24h": round(info.priceChange24H) },
    marketCapUsd: round(info.marketCap, 0),
    liquidityUsd: round(info.liquidity, 0),
    volume24hUsd: round(info.volume24H, 0),
    trades24h: num(info.txs24H),
    holders: num(info.holders),
    topTenHoldersPercent: round(num(risk?.metrics?.topTen) ?? (holders.length ? topTen : null), 1),
  };
  const assessed = risk && risk.level ? {
    level: String(risk.level),
    reasons: (risk.reasons ?? []).map((r) => String(r.text ?? "")).filter(Boolean).slice(0, 5),
    facts: (risk.facts ?? []).map((r) => String(r.text ?? "")).filter(Boolean).slice(0, 5),
    creatorHoldsPercent: round(risk.metrics?.creator, 2),
  } : null;
  return {
    data: { token, risk: assessed, asOf: iso(num(info.time) ?? num(details.observedAt) ?? now()), url: links.token(index, contract) },
    images: { token: image(listed?.logoURL) },
  };
}

// MARK: Smart money

export async function loadSmartMoney(get, { scope = "all", limit = 12, now = Date.now } = {}) {
  const body = await get("/api/token-details", { view: "smart-money" }, { timeout: 25_000 });
  const pick = scope === "monad" ? (body?.monad ?? []) : scope === "other" ? (body?.trades ?? []) : [...(body?.monad ?? []), ...(body?.trades ?? [])];
  const rows = pick.filter((row) => row.token).slice(0, Math.max(1, Math.min(20, limit)));
  return {
    data: {
      scope,
      trades: rows.map((row) => ({
        wallet: String(row.wallet ?? ""),
        otherWallets: Math.max(0, (num(row.walletCount) ?? 1) - 1),
        chain: chainSlugOf(row.chainIndex) ?? String(row.chainIndex),
        token: String(row.token),
        symbol: String(row.symbol ?? ""),
        name: String(row.name ?? ""),
        side: row.side === "sell" ? "sell" : "buy",
        valueUsd: round(row.usd),
        time: iso(num(row.time)),
        marketCapUsd: round(row.marketCap, 0),
        liquidityUsd: round(row.liquidity, 0),
        change24hPercent: round(row.change24h),
        walletWinRatePercent: round(row.winRate, 1),
        walletRealizedUsd: round(row.realized),
        url: links.token(row.chainIndex, row.token),
      })),
      asOf: iso(num(body?.observedAt) ?? now()),
    },
    images: { tokens: Object.fromEntries(rows.map((row) => [`${chainSlugOf(row.chainIndex) ?? row.chainIndex}:${row.token}`, image(row.logoURL)]).filter(([, url]) => url)) },
  };
}

// MARK: Perpl

export async function loadTopTraders(get, { limit = 10, names = true, now = Date.now } = {}) {
  const body = await get("/api/traders", { view: "top" }, { timeout: 20_000 });
  const rows = (body?.traders ?? []).slice(0, Math.max(1, Math.min(25, limit)));
  let identities = {};
  if (names && rows.length) {
    // Names are a nicety: a slow lookup never holds up the board.
    const lookup = get("/api/traders", { view: "identity", addresses: rows.map((row) => row.address).join(",") }, { timeout: 2_500 })
      .then((answer) => answer?.identities ?? {}).catch(() => ({}));
    identities = await lookup;
  }
  const traders = rows.map((row, i) => {
    const who = identities[row.address?.toLowerCase()] ?? identities[row.address] ?? null;
    return {
      rank: i + 1,
      address: String(row.address),
      name: who?.name ?? null,
      unrealizedPnlUsd: round(row.pnl),
      positions: (row.positions ?? []).map((p) => ({
        market: String(p.market), side: p.side === "short" ? "short" : "long", sizeUsd: round(p.value),
        entryPrice: price(p.entry), markPrice: price(p.mark), pnlUsd: round(p.pnl), pnlPercent: round(p.pnlPercent),
        leverage: round(p.leverage, 1),
      })),
      url: links.wallet(row.address),
    };
  });
  return {
    data: { exchange: "Perpl", traders, asOf: iso(num(body?.observedAt) ?? now()) },
    images: { avatars: Object.fromEntries(rows.map((row) => [row.address, image((identities[row.address?.toLowerCase()] ?? {}).avatar)]).filter(([, url]) => url)) },
  };
}

export async function loadTraderStats(get, { address }) {
  if (!EVM_ADDRESS.test(String(address ?? ""))) throw new DeskDataError("Perpl traders are 0x addresses.");
  const body = await get("/api/traders", { view: "history", address }, { timeout: 20_000, missing: "That wallet has no trading history on Perpl." });
  const s = body?.stats;
  if (!s) throw new DeskDataError("That wallet has no trading history on Perpl.");
  const seconds = (value) => (num(value) ? iso(num(value) * 1000) : null);
  return {
    data: {
      address: String(body.address ?? address),
      summary: typeof body.summary === "string" ? body.summary : null,
      stats: {
        closedTrades: num(s.trades) ?? 0,
        winRatePercent: num(s.winRate) == null ? null : round(num(s.winRate) * 100, 1),
        realizedPnlUsd: round(s.realised),
        profitFactor: round(s.profitFactor),
        maxDrawdownUsd: round(s.maxDrawdown),
        averageLeverage: round(s.averageLeverage, 1),
        averageHoldMinutes: num(s.averageHoldSeconds) == null ? null : round(num(s.averageHoldSeconds) / 60, 1),
        liquidations: num(s.liquidations) ?? 0,
        volumeUsd: round(s.volume, 0),
        bestMarket: s.bestMarket?.symbol ?? null,
        worstMarket: s.worstMarket?.symbol ?? null,
        style: Array.isArray(s.tags) ? s.tags.map(String).slice(0, 4) : [],
        firstTrade: seconds(s.since),
        lastActive: seconds(s.lastActive),
      },
      recentTrades: (body.trades ?? []).slice(0, 10).map((t) => ({
        time: seconds(t.time), market: String(t.market), side: t.side === "short" ? "short" : "long",
        entryPrice: price(t.entry), exitPrice: price(t.exit), pnlUsd: round(t.pnl), leverage: round(t.leverage, 1),
        liquidated: Boolean(t.liquidated),
      })),
      url: links.wallet(String(body.address ?? address)),
    },
  };
}

export async function loadMarkets(get, { market = null, now = Date.now } = {}) {
  const body = await get("/api/v1/markets");
  const rows = body?.data?.markets ?? [];
  const wanted = market ? String(market).toUpperCase().replace(/[-/ ]?(USD|PERP|AUSD)$/, "") : null;
  const picked = rows.filter((row) => row.isOpen !== false && (!wanted || String(row.name).toUpperCase() === wanted));
  if (wanted && !picked.length) throw new DeskDataError(`Perpl has no ${wanted} market. Open markets: ${rows.map((r) => r.name).join(", ")}.`);
  return {
    data: {
      exchange: "Perpl",
      collateral: String(body?.data?.collateral ?? "AUSD"),
      markets: picked.map((row) => ({
        market: String(row.name),
        markPrice: price(row.mark),
        change24hPercent: num(row.change) == null ? null : round(num(row.change) * 100),
        volume24hUsd: round(row.volume24h, 0),
        openInterestUsd: round(row.openInterest, 0),
        fundingRatePercent: num(row.fundingRate) == null ? null : round(num(row.fundingRate) * 100, 4),
        fundingIntervalMinutes: num(row.fundingIntervalSec) == null ? null : Math.round(num(row.fundingIntervalSec) / 60),
        maxLeverage: num(row.maxLeverage),
        url: links.market(row.name),
      })),
      asOf: iso(num(body?.data?.head?.time) ?? now()),
    },
  };
}
