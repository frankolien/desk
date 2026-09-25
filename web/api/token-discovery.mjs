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
    // Said here so the app can retire Buy and Sell before someone types an amount and
    // waits on a quote that was never going to arrive.
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

// Every chain Desk can show, so a Monad or BNB contract pasted into search is found.
// OKX's search refuses a call naming a chain it does not index, and says which; those
// are dropped and the call retried, and the surviving list is kept for the process.
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

/// What was typed comes first: an exact symbol, then a symbol or name that starts
/// with it, then everything else by market cap.
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

/// Monad's own tokens lead; the rest keep their order. Solana never appears.
export function homeFirst(tokens) {
  return tokens
    .filter((token) => token.chainIndex !== SOLANA)
    .map((token, index) => ({ token, index, home: token.chainIndex === MONAD ? 0 : 1 }))
    .sort((a, b) => a.home - b.home || a.index - b.index)
    .map(({ token }) => token);
}

export default async function handler(req, res) {
  if (req.method !== "GET") return res.status(405).json({ error: "GET required" });
  const query = String(req.query.q || "").trim().slice(0, 100);
  try {
    const rows = query
      ? await searchTokens(query)
      : await okxGet("/api/v6/dex/market/token/hot-token", {
          rankingType: "4", rankingTimeFrame: "4", riskFilter: "true",
          stableTokenFilter: "true", limit: "20",
        });
    const tokens = homeFirst(rows.map(normalize).filter((token) => token.symbol && token.contract));
    res.setHeader("Cache-Control", query
      ? "s-maxage=10, stale-while-revalidate=30"
      : "s-maxage=30, stale-while-revalidate=90");
    return res.status(200).json({ mode: query ? "search" : "trending", observedAt: Date.now(), tokens });
  } catch (error) {
    return res.status(502).json({ error: error.message || "Token discovery unavailable" });
  }
}
