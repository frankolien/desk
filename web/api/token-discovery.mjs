import crypto from "node:crypto";
import { chainName, isBuyable, isQuotable, nativeToken, CHAINS } from "./_chains.mjs";
import { okxPost } from "./_okx.mjs";

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

/// Explore's "Crypto" chip: the established coins people mean by crypto, Monad's own first,
/// so the list is never just whatever memecoin is hot. Names say what the wrapped token is.
export const CRYPTO = [
  { chainIndex: "143", contract: "0x3bd359c1119da7da1d913d1c4d2b7c461115433a", name: "Monad" },
  { chainIndex: "143", contract: "0xee8c0e9f1bffb4eb878d8f15f368a02a35481242", name: "Ethereum" },
  { chainIndex: "143", contract: "0x0555e30da8f98308edb960aa94c0db47230d2b9c", name: "Bitcoin" },
  { chainIndex: "56", contract: "0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c", name: "BNB" },
  { chainIndex: "1", contract: "0x514910771af9ca656af840dff83e8264ecf986ca", name: "Chainlink" },
  { chainIndex: "1", contract: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984", name: "Uniswap" },
  { chainIndex: "1", contract: "0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9", name: "Aave" },
  { chainIndex: "56", contract: "0xba2ae424d960c26247dd6c32edc70b295c744c43", name: "Dogecoin" },
  { chainIndex: "1", contract: "0x6982508145454ce325ddbe47a25d4ec3d2311933", name: "Pepe" },
  { chainIndex: "1", contract: "0x95ad61b0a150d79219dcf64e1e6cc01f0b64c4ce", name: "Shiba Inu" },
  { chainIndex: "1", contract: "0xfaba6f8e4a5e8ab82f62fe7c39859fa577269be3", name: "Ondo" },
];

/// The curated coins, named by OKX's basic info and priced by its price info in two calls.
export async function cryptoTokens({ post = okxPost } = {}) {
  const identities = CRYPTO.map(({ chainIndex, contract }) => ({ chainIndex, tokenContractAddress: contract }));
  const [basics, prices] = await Promise.all([
    post("/api/v6/dex/market/token/basic-info", identities).catch(() => []),
    post("/api/v6/dex/market/price-info", identities),
  ]);
  const key = (row) => `${row.chainIndex}:${String(row.tokenContractAddress ?? "").toLowerCase()}`;
  const basic = new Map((Array.isArray(basics) ? basics : []).map((row) => [key(row), row]));
  const price = new Map((Array.isArray(prices) ? prices : []).map((row) => [key(row), row]));
  return CRYPTO.map((entry) => {
    const id = `${entry.chainIndex}:${entry.contract}`;
    const info = basic.get(id) ?? {};
    const live = price.get(id);
    if (!live) return null;
    return normalize({
      ...info, ...live, chainIndex: entry.chainIndex, tokenContractAddress: entry.contract,
      tokenName: entry.name, tokenSymbol: info.tokenSymbol ?? entry.name,
      change: live.priceChange24H, volume: live.volume24H,
    });
  }).filter(Boolean);
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
      res.setHeader("Cache-Control", "s-maxage=60, stale-while-revalidate=180");
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
