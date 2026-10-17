import crypto from "node:crypto";
import { chainName, isBuyable, isQuotable, nativeToken, CHAINS } from "./_chains.mjs";

function authHeaders(timestamp, requestPath) {
  const signature = crypto.createHmac("sha256", process.env.OKX_SECRET_KEY)
    .update(timestamp + "GET" + requestPath).digest("base64");
  return {
    "OK-ACCESS-KEY": process.env.OKX_API_KEY,
    "OK-ACCESS-SIGN": signature,
    "OK-ACCESS-PASSPHRASE": process.env.OKX_PASSPHRASE,
    "OK-ACCESS-TIMESTAMP": timestamp,
  };
}

async function okxGet(path, params) {
  const requestPath = `${path}?${new URLSearchParams(params)}`;
  const timestamp = new Date().toISOString();
  const response = await fetch("https://web3.okx.com" + requestPath, {
    headers: authHeaders(timestamp, requestPath),
  });
  const payload = await response.json();
  if (!response.ok || String(payload.code) !== "0") {
    throw new Error(payload.msg || `OKX HTTP ${response.status}`);
  }
  return Array.isArray(payload.data) ? payload.data : [];
}

function numeric(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function normalize(row) {
  const chainIndex = String(row.chainIndex || "");
  const contract = String(row.tokenContractAddress || "");
  const tags = row.tagList && typeof row.tagList === "object" ? row.tagList : {};
  return {
    id: `${chainIndex}:${contract}`,
    chainIndex,
    chainName: chainName(chainIndex),
    quotable: isQuotable(chainIndex),
    buyable: isBuyable(chainIndex),
    nativeSymbol: nativeToken(chainIndex)?.symbol ?? null,
    symbol: String(row.tokenSymbol || "").toUpperCase(),
    name: String(row.tokenName || row.tokenSymbol || "Unknown token"),
    logoURL: String(row.tokenLogoUrl || ""),
    contract,
    decimals: numeric(row.decimal ?? row.decimals),
    explorerURL: String(row.explorerUrl || ""),
    price: numeric(row.price),
    change: numeric(row.change),
    marketCap: numeric(row.marketCap),
    volume24H: numeric(row.volume ?? row.volume24H),
    liquidity: numeric(row.liquidity),
    holders: numeric(row.holders),
    communityRecognized: typeof tags.communityRecognized === "boolean"
      ? tags.communityRecognized : null,
    riskLevel: row.riskLevelControl == null ? null : String(row.riskLevelControl),
  };
}

// OKX refuses a call naming a chain it does not index; those are dropped and the call retried.
// Solana is left out on purpose: Desk's wallet cannot hold what it would buy there.
const SOLANA = "501";
const MONAD = "143";
let searchChains = Object.keys(CHAINS).filter((index) => CHAINS[index].rpc !== null && index !== SOLANA);

export async function searchTokens(query, { search = okxGet } = {}) {
  for (let attempt = 0; attempt < 4; attempt += 1) {
    try {
      const rows = await search("/api/v6/dex/market/token/search", { chains: searchChains.join(","), search: query, limit: "40" });
      return rankSearch(Array.isArray(rows) ? rows : [], query);
    } catch (error) {
      const refused = /Unsupported chain IDs?:\s*([\d,\s]+)/i.exec(error.message ?? "");
      if (!refused) throw error;
      const drop = new Set(refused[1].split(",").map((value) => value.trim()));
      searchChains = searchChains.filter((index) => !drop.has(index));
    }
  }
  throw new Error("Token search is unavailable.");
}

export function rankSearch(rows, query) {
  const wanted = String(query).trim().toLowerCase();
  const tier = (row) => {
    const symbol = String(row.tokenSymbol ?? "").toLowerCase();
    const name = String(row.tokenName ?? "").toLowerCase();
    if (symbol === wanted || String(row.tokenContractAddress ?? "").toLowerCase() === wanted) return 0;
    if (symbol.startsWith(wanted) || name.startsWith(wanted)) return 1;
    if (name.includes(wanted) || symbol.includes(wanted)) return 2;
    return 3;
  };
  return rows
    .map((row, index) => ({ row, index, tier: tier(row), home: String(row.chainIndex) === MONAD ? 0 : 1, cap: Number(row.marketCap) || 0 }))
    .sort((a, b) => a.tier - b.tier || a.home - b.home || b.cap - a.cap || a.index - b.index)
    .map(({ row }) => row);
}

export function homeFirst(tokens) {
  return tokens
    .filter((token) => token.chainIndex !== SOLANA)
    .map((token, index) => ({ token, index, home: token.chainIndex === MONAD ? 0 : 1 }))
    .sort((a, b) => a.home - b.home || a.index - b.index)
    .map(({ token }) => token);
}

/// Explore's "Crypto" chip: the big coins, ranked by their real market cap (CoinGecko), each
/// opening the token Desk can actually trade: Monad's own where one exists (BTC, ETH, MON),
/// otherwise the 1:1 peg on BNB Chain or Ethereum. Every peg here was checked to price within
/// 1% of its coin (17 Oct 2026); ATOM, TON and RENDER were left out for missing that.
export const CRYPTO_PEGS = {
  "bitcoin": ["143", "0x0555e30da8f98308edb960aa94c0db47230d2b9c"],
  "ethereum": ["143", "0xee8c0e9f1bffb4eb878d8f15f368a02a35481242"],
  "binancecoin": ["56", "0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c"],
  "ripple": ["56", "0x1d2f0da169ceb9fc7b3144628db156f3f6c60dbe"],
  "solana": ["56", "0x570a5d26f7765ecb712c0924e4de545b89fd43df"],
  "tron": ["56", "0xce7de646e7208a4ef112cb6ed5038fa6cc6b12e3"],
  "zcash": ["56", "0x1ba42e5193dfa8b03d15dd1b86a3113bbbef8eeb"],
  "dogecoin": ["56", "0xba2ae424d960c26247dd6c32edc70b295c744c43"],
  "chainlink": ["1", "0x514910771af9ca656af840dff83e8264ecf986ca"],
  "cardano": ["56", "0x3ee2200efb3400fabb9aacf31297cbdd1d435d47"],
  "near": ["56", "0x1fa4a73a3f0133f0025378af00236f3abdee5d63"],
  "bitcoin-cash": ["56", "0x8ff795a6f4d97e7887c79bea79aba5cc76444adf"],
  "litecoin": ["56", "0x4338665cbb7b2485a8855a139b75d5e34ab0db94"],
  "uniswap": ["1", "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"],
  "avalanche-2": ["56", "0x1ce0c2827e2ef14d5c4f29a091d735a204794041"],
  "shiba-inu": ["1", "0x95ad61b0a150d79219dcf64e1e6cc01f0b64c4ce"],
  "tether-gold": ["1", "0x68749665ff8d2d112fa859aa293f07a622782f38"],
  "bittensor": ["1", "0x77e06c9eccf2e797fd462a92b6d7642ef85b0a44"],
  "quant-network": ["1", "0x4a220e6096b25eadb88358cb44068a3248254675"],
  "crypto-com-chain": ["1", "0xa0b73e1ff0b80914ab6fe0444e65848c4c34450b"],
  "aave": ["1", "0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9"],
  "pepe": ["1", "0x6982508145454ce325ddbe47a25d4ec3d2311933"],
  "ondo-finance": ["1", "0xfaba6f8e4a5e8ab82f62fe7c39859fa577269be3"],
  "polkadot": ["56", "0x7083609fce4d1d8dc0c979aab8c869ea2c873402"],
  "world-liberty-financial": ["1", "0xda5e1988097297dcdc1f90d4dfe7909e847cbef6"],
  "mantle": ["1", "0x3c3a81e81dc49a522a592e7622a7e711c06bf354"],
  "pax-gold": ["1", "0x45804880de22913dafe09f4980848ece6ecbaf78"],
  "arbitrum": ["1", "0xb50721bcf8d664c30412cfbc6cf7a15145234ad1"],
  "ethena": ["1", "0x57e114b691db790c35207b2e685d4a43181e6061"],
  "pendle": ["1", "0x808507121b80c02388fad14726482e061b8da827"],
  "fetch-ai": ["1", "0xaea46a60368a7bd060eec7df8cba43b7ef41ad85"],
  "worldcoin-wld": ["1", "0x163f8c2467924be0ae7b5347228cabf260318753"],
  "ethereum-classic": ["56", "0x3d6545b08693dae087e957cb1180ee38b9e3c25e"],
  "filecoin": ["56", "0x0d8ce2a99bb6e3b7db580ed848240e4a0f9ae153"],
  "monad": ["143", "0x3bd359c1119da7da1d913d1c4d2b7c461115433a"]
};

const COINGECKO = "https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&order=market_cap_desc&per_page=150&page=1&price_change_percentage=24h";

function cryptoToken(coin, [chainIndex, contract]) {
  return {
    id: `${chainIndex}:${contract}`, chainIndex, chainName: chainName(chainIndex),
    quotable: isQuotable(chainIndex), buyable: isBuyable(chainIndex), nativeSymbol: nativeToken(chainIndex)?.symbol ?? null,
    symbol: String(coin.symbol ?? "").toUpperCase(), name: String(coin.name ?? coin.symbol ?? ""),
    logoURL: String(coin.image ?? ""), contract, decimals: null, explorerURL: "",
    price: numeric(coin.current_price), change: numeric(coin.price_change_percentage_24h),
    marketCap: numeric(coin.market_cap), volume24H: numeric(coin.total_volume),
    liquidity: null, holders: null, communityRecognized: true, riskLevel: null,
  };
}

export async function cryptoTokens({ fetchImpl = fetch } = {}) {
  const response = await fetchImpl(COINGECKO, { headers: { accept: "application/json" } });
  if (!response.ok) throw new Error(`coingecko ${response.status}`);
  const coins = await response.json();
  return (Array.isArray(coins) ? coins : [])
    .filter((coin) => CRYPTO_PEGS[coin.id])
    .map((coin) => cryptoToken(coin, CRYPTO_PEGS[coin.id]));
}

/// Most held: Monad's busy tokens, ordered by how many wallets hold them.
export const byHolders = (tokens) => [...tokens].sort((a, b) => (b.holders ?? 0) - (a.holders ?? 0));

export default async function handler(req, res) {
  if (req.method !== "GET") return res.status(405).json({ error: "GET required" });
  const query = String(req.query.q || "").trim().slice(0, 100);
  // `chain` narrows the trending list to one chain, so Monad has its own page of movers
  // instead of the few that make the global twenty.
  const chain = /^\d{1,10}$/.test(String(req.query.chain ?? "")) ? String(req.query.chain) : "";
  // `sort`: crypto (the curated coins), holders (Monad's tokens by holders); default trending.
  const sort = String(req.query.sort ?? "");
  try {
    if (!query && sort === "crypto") {
      // CoinGecko's free tier is rate limited; the edge serves one answer a minute to everyone.
      res.setHeader("Cache-Control", "s-maxage=60, stale-while-revalidate=600");
      return res.status(200).json({ mode: "crypto", observedAt: Date.now(), tokens: await cryptoTokens() });
    }
    const listChain = sort === "holders" ? (chain || MONAD) : chain;
    const rows = query
      ? await searchTokens(query)
      : await okxGet("/api/v6/dex/market/token/hot-token", {
          ...(listChain ? { chainIndex: listChain } : {}),
          rankingType: "4", rankingTimeFrame: "4", riskFilter: "true",
          stableTokenFilter: "true", limit: listChain ? "40" : "20",
        });
    let tokens = homeFirst(rows.map(normalize).filter((token) => token.symbol && token.contract));
    if (sort === "holders") tokens = byHolders(tokens);
    res.setHeader("Cache-Control", query
      ? "s-maxage=10, stale-while-revalidate=30"
      : "s-maxage=30, stale-while-revalidate=90");
    return res.status(200).json({ mode: query ? "search" : "trending", observedAt: Date.now(), tokens });
  } catch (error) {
    return res.status(502).json({ error: error.message || "Token discovery unavailable" });
  }
}
