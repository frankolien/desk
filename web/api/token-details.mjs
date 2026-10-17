import { okxGet, okxPost } from "./_okx.mjs";
import { chainName } from "./_chains.mjs";
import { handleHoldings } from "./_holdings.mjs";
import { handleRisk } from "./_risk.mjs";
import { handleEarly } from "./_early.mjs";

const TOKENS = {
  BTC: { chainIndex: "1", address: "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599" },
  ETH: { chainIndex: "1", address: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2" },
  SOL: { chainIndex: "501", address: "So11111111111111111111111111111111111111112" },
  PUMP: { chainIndex: "501", address: "pumpCmXqMfrsAkQ5r49WcJnRayYRqmXz6ae8H7H9Dfn" },
};

const TOKEN_ID = /^(\d{1,10}):(0x[a-fA-F0-9]{40}|[1-9A-HJ-NP-Za-km-z]{32,44})$/;
const PRICE_BATCH = 20;
const number = (value) => { const n = Number(value); return Number.isFinite(n) ? n : null; };

async function handlePrices(req, res) {
  const ids = [...new Set(String(req.query.tokens ?? "").split(",").map((v) => v.trim()).filter(Boolean))].slice(0, PRICE_BATCH);
  const parsed = ids.map((id) => TOKEN_ID.exec(id)).filter(Boolean).map((m) => ({ chainIndex: m[1], tokenContractAddress: m[2] }));
  if (!parsed.length) return res.status(400).json({ error: "tokens must be chain:address pairs." });
  try {
    const rows = await okxPost("/api/v6/dex/market/price-info", parsed);
    const prices = (Array.isArray(rows) ? rows : []).map((row) => ({
      chainIndex: String(row.chainIndex ?? ""), contract: String(row.tokenContractAddress ?? ""),
      price: number(row.price), change5m: number(row.priceChange5M), change1h: number(row.priceChange1H), change24h: number(row.priceChange24H),
      volume24H: number(row.volume24H), marketCap: number(row.marketCap), liquidity: number(row.liquidity), holders: number(row.holders),
      txs5m: number(row.txs5M), time: number(row.time),
    }));
    res.setHeader("Cache-Control", "public, s-maxage=1, stale-while-revalidate=2");
    return res.status(200).json({ observedAt: Date.now(), prices });
  } catch (error) {
    return res.status(502).json({ error: error.message });
  }
}

const SPARKLINE_BATCH = 10;

async function handleSparklines(req, res) {
  const ids = [...new Set(String(req.query.tokens ?? "").split(",").map((v) => v.trim()).filter(Boolean))].slice(0, SPARKLINE_BATCH);
  const parsed = ids.map((id) => TOKEN_ID.exec(id)).filter(Boolean).map((m) => ({ chainIndex: m[1], contract: m[2] }));
  if (!parsed.length) return res.status(400).json({ error: "tokens must be chain:address pairs." });
  // One at a time, with one retry: OKX's per-key limit is shared with the rest of Desk, and ten
  // candle calls at once came back mostly refused.
  const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const one = async ({ chainIndex, contract }) => {
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const rows = await okxGet("/api/v6/dex/market/candles", { chainIndex, tokenContractAddress: contract, bar: "1H", limit: "24" });
        const closes = (Array.isArray(rows) ? rows : []).map((row) => number(row[4])).filter((v) => v !== null).reverse();
        return { chainIndex, contract, closes };
      } catch {
        if (attempt === 0) await pause(600);
      }
    }
    return { chainIndex, contract, closes: [] };
  };
  const series = [];
  for (const id of parsed) series.push(await one(id));
  // A gap is likely a refusal, not a token without trades: don't keep it for five minutes.
  const complete = series.every((row) => row.closes.length > 0);
  res.setHeader("Cache-Control", complete ? "public, s-maxage=300, stale-while-revalidate=900" : "public, s-maxage=15");
  return res.status(200).json({ observedAt: Date.now(), series });
}

// CoinGecko's and DexScreener's names for the chains Desk shows tokens on.
const GECKO_PLATFORM = { "1": "ethereum", "10": "optimistic-ethereum", "56": "binance-smart-chain", "137": "polygon-pos", "143": "monad", "8453": "base", "42161": "arbitrum-one" };
const DEX_CHAIN = { "1": "ethereum", "10": "optimism", "56": "bsc", "137": "polygon", "143": "monad", "8453": "base", "42161": "arbitrum" };

/// The first paragraph of CoinGecko's description, as plain text, at most a few sentences.
export function plainDescription(html) {
  const text = String(html ?? "").split(/\r?\n\r?\n/)[0].replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim();
  if (text.length <= 320) return text || null;
  const cut = text.slice(0, 320);
  return cut.slice(0, Math.max(cut.lastIndexOf(". ") + 1, 200)).trim() + (cut.lastIndexOf(". ") > 200 ? "" : "…");
}

/// What a token is and who made it, for the token page's Info tab: OKX's advanced info
/// (creator, launch time, top-10 share), CoinGecko's description and supply, and the
/// project's own links from CoinGecko or DexScreener. Each part is optional.
export async function tokenProfile({ chainIndex, address, get = okxGet, fetchImpl = fetch }) {
  const json = (url) => fetchImpl(url, { headers: { accept: "application/json" } }).then((r) => (r.ok ? r.json() : null));
  const platform = GECKO_PLATFORM[chainIndex];
  const dexChain = DEX_CHAIN[chainIndex];
  const [advanced, gecko, dex] = await Promise.allSettled([
    get("/api/v6/dex/market/token/advanced-info", { chainIndex, tokenContractAddress: address }),
    platform ? json(`https://api.coingecko.com/api/v3/coins/${platform}/contract/${address.toLowerCase()}`) : null,
    dexChain ? json(`https://api.dexscreener.com/tokens/v1/${dexChain}/${address}`) : null,
  ]);
  const okx = advanced.status === "fulfilled" ? (Array.isArray(advanced.value) ? advanced.value[0] : advanced.value) ?? {} : {};
  const coin = gecko.status === "fulfilled" && gecko.value && !gecko.value.error ? gecko.value : null;
  const info = dex.status === "fulfilled" && Array.isArray(dex.value) ? dex.value.find((pair) => pair?.info)?.info ?? null : null;
  const site = coin?.links?.homepage?.find((url) => /^https?:\/\//.test(url ?? ""))
    ?? info?.websites?.find((w) => /^https?:\/\//.test(w?.url ?? ""))?.url ?? null;
  const twitterUrl = info?.socials?.find((social) => social?.type === "twitter")?.url;
  const handle = coin?.links?.twitter_screen_name || (twitterUrl ? String(twitterUrl).split("/").filter(Boolean).pop() : null);
  const created = number(okx.createTime);
  return {
    description: plainDescription(coin?.description?.en),
    website: site,
    x: handle ? String(handle).replace(/^@/, "") : null,
    creator: /^0x[a-fA-F0-9]{40}$/.test(String(okx.creatorAddress ?? "")) ? okx.creatorAddress : null,
    createdAt: created && created > 1e12 ? created : created ? created * 1000 : null,
    top10Percent: number(okx.top10HoldPercent),
    maxSupply: [coin?.market_data?.max_supply, coin?.market_data?.total_supply].map(number).find((v) => v > 0) ?? null,
  };
}

const percentOf = (value) => { const n = number(value); return n === null ? null : n <= 1 ? n * 100 : n; };

/// Chains OKX scores smart money on that Desk can buy on (through Relay). Monad isn't one yet.
export const SMART_CHAINS = ["8453", "56", "1"];

/// Signals' Smart Money feed: OKX's smart-money buy signals (wallets it rates as consistently
/// profitable) on Base, BNB Chain and Ethereum, newest first. Each is one token bought by one or
/// more such wallets, with the total in USD and the share they've sold since; the token's day
/// move and liquidity come from price-info, and the lead wallet's 30-day win rate and realized
/// PnL from its portfolio overview (at most 10 wallets a refresh).
export async function smartMoneyFeed({ get = okxGet, post = okxPost, limit = 30 } = {}) {
  const lists = await Promise.all(SMART_CHAINS.map((chainIndex) =>
    post("/api/v6/dex/market/signal/list", { chainIndex, walletType: "1", minAmountUsd: "100", limit: "30" }).catch(() => [])));
  const signals = lists.flat()
    .filter((row) => row?.token?.tokenAddress && /^0x[a-fA-F0-9]{40}$/.test(row.token.tokenAddress))
    .sort((a, b) => Number(b.timestamp) - Number(a.timestamp))
    .slice(0, limit);
  const key = (chainIndex, address) => `${chainIndex}:${String(address).toLowerCase()}`;
  const ids = [...new Map(signals.map((row) => [key(row.chainIndex, row.token.tokenAddress), { chainIndex: String(row.chainIndex), tokenContractAddress: row.token.tokenAddress }])).values()];
  const leads = [...new Map(signals.map((row) => {
    const lead = String(row.triggerWalletAddress ?? "").split(",")[0];
    return [key(row.chainIndex, lead), { chainIndex: String(row.chainIndex), lead }];
  })).values()].filter((row) => /^0x[a-fA-F0-9]{40}$/.test(row.lead)).slice(0, 10);
  const [prices, overviews] = await Promise.all([
    ids.length ? post("/api/v6/dex/market/price-info", ids.slice(0, 20)).catch(() => []) : [],
    Promise.all(leads.map(({ chainIndex, lead }) => get("/api/v6/dex/market/portfolio/overview", { chainIndex, walletAddress: lead, timeFrame: "4" })
      .then((value) => [key(chainIndex, lead), Array.isArray(value) ? value[0] : value]).catch(() => null))),
  ]);
  const live = new Map((Array.isArray(prices) ? prices : []).map((row) => [key(row.chainIndex, row.tokenContractAddress), row]));
  const stats = new Map(overviews.filter(Boolean));
  return signals.map((row) => {
    const chainIndex = String(row.chainIndex);
    const wallets = String(row.triggerWalletAddress ?? "").split(",").filter((w) => /^0x[a-fA-F0-9]{40}$/.test(w));
    const price = live.get(key(chainIndex, row.token.tokenAddress)) ?? {};
    const wallet = stats.get(key(chainIndex, wallets[0] ?? ""));
    return {
      id: String(row.cursor ?? `${chainIndex}:${row.token.tokenAddress}:${row.timestamp}`),
      wallet: wallets[0] ?? null, walletCount: number(row.triggerWalletCount) ?? wallets.length,
      chainIndex, chainName: chainName(chainIndex), token: row.token.tokenAddress,
      symbol: String(row.token.symbol ?? "").toUpperCase(), name: String(row.token.name ?? row.token.symbol ?? ""),
      logoURL: String(row.token.logo ?? ""), side: "buy", usd: number(row.amountUsd), time: number(row.timestamp),
      soldPercent: number(row.soldRatioPercent), marketCap: number(row.token.marketCapUsd), holders: number(row.token.holders),
      change24h: number(price.priceChange24H), liquidity: number(price.liquidity),
      winRate: percentOf(wallet?.winRate), realized: number(wallet?.realizedPnlUsd),
    };
  });
}

async function handleSmartMoney(req, res) {
  try {
    const trades = await smartMoneyFeed();
    res.setHeader("Cache-Control", "public, s-maxage=30, stale-while-revalidate=90");
    return res.status(200).json({ observedAt: Date.now(), trades });
  } catch (error) {
    return res.status(502).json({ error: error.message });
  }
}

async function handleProfile(req, res) {
  const chainIndex = String(req.query.chainIndex ?? "");
  const address = String(req.query.address ?? "");
  if (!/^\d{1,10}$/.test(chainIndex) || !/^0x[a-fA-F0-9]{40}$/.test(address)) return res.status(400).json({ error: "Valid token identity required" });
  const profile = await tokenProfile({ chainIndex, address });
  res.setHeader("Cache-Control", "public, s-maxage=3600, stale-while-revalidate=86400");
  return res.status(200).json(profile);
}

export default async function handler(req, res) {
  if (req.method !== "GET") return res.status(405).json({ error: "GET required" });
  if (req.query.view === "profile") return handleProfile(req, res);
  if (req.query.view === "smart-money") return handleSmartMoney(req, res);
  if (req.query.view === "holdings") return handleHoldings(req, res);
  if (req.query.view === "sparklines") return handleSparklines(req, res);
  if (req.query.view === "risk") return handleRisk(req, res);
  if (req.query.view === "early") return handleEarly(req, res);
  if (req.query.view === "prices") return handlePrices(req, res);
  // The worker on Railway prices trades through here, so OKX's key stays on Vercel.
  if (req.query.view === "candle") {
    const secret = process.env.CRON_SECRET;
    if (!secret || req.headers.authorization !== `Bearer ${secret}`) return res.status(401).json({ error: "Unauthorized." });
    const { chainIndex, contract, bar, after } = req.query;
    const validContract = /^0x[a-fA-F0-9]{40}$/.test(String(contract)) || (String(chainIndex) === "501" && /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(String(contract)));
    if (!/^\d{1,10}$/.test(String(chainIndex)) || !validContract
      || !["1m", "1H", "1D"].includes(String(bar)) || !/^\d{1,16}$/.test(String(after))) {
      return res.status(400).json({ error: "chainIndex, contract, bar and after are required." });
    }
    try {
      const rows = await okxGet("/api/v6/dex/market/historical-candles", {
        chainIndex: String(chainIndex), tokenContractAddress: String(contract), bar: String(bar), limit: "1", after: String(after),
      });
      res.setHeader("Cache-Control", "private, max-age=3600");
      return res.status(200).json({ rows: Array.isArray(rows) ? rows : [] });
    } catch (error) {
      return res.status(502).json({ error: error.message });
    }
  }
  const symbol = String(req.query.symbol || "").toUpperCase();
  const known = TOKENS[symbol];
  const chainIndex = String(req.query.chainIndex || known?.chainIndex || "");
  const address = String(req.query.address || known?.address || "");
  const validChain = /^\d{1,10}$/.test(chainIndex);
  const validAddress = /^0x[a-fA-F0-9]{40}$/.test(address) || /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(address);
  if (!validChain || !validAddress) return res.status(400).json({ error: "Valid token identity required" });

  const identity = { chainIndex, tokenContractAddress: address };
  try {
    const [priceRows, holderRows] = await Promise.all([
      okxPost("/api/v6/dex/market/price-info", [identity]),
      okxGet("/api/v6/dex/market/token/holder", { ...identity, limit: "20" }),
    ]);
    res.setHeader("Cache-Control", "s-maxage=15, stale-while-revalidate=45");
    return res.status(200).json({
      symbol,
      observedAt: Date.now(),
      priceInfo: Array.isArray(priceRows) ? priceRows[0] ?? null : priceRows,
      holders: Array.isArray(holderRows) ? holderRows : holderRows?.holderList ?? [],
    });
  } catch (error) {
    return res.status(502).json({ error: error.message });
  }
}
