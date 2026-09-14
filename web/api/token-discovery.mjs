import crypto from "node:crypto";

const CHAIN_NAMES = { "1": "Ethereum", "501": "Solana" };

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
    chainName: CHAIN_NAMES[chainIndex] || `Chain ${chainIndex}`,
    symbol: String(row.tokenSymbol || "").toUpperCase(),
    name: String(row.tokenName || row.tokenSymbol || "Unknown token"),
    logoURL: String(row.tokenLogoUrl || ""),
    contract,
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

export default async function handler(req, res) {
  if (req.method !== "GET") return res.status(405).json({ error: "GET required" });
  const query = String(req.query.q || "").trim().slice(0, 100);
  try {
    const rows = query
      ? await okxGet("/api/v6/dex/market/token/search", {
          chains: "1,501", search: query, limit: "30",
        })
      : await okxGet("/api/v6/dex/market/token/hot-token", {
          rankingType: "4", rankingTimeFrame: "4", riskFilter: "true",
          stableTokenFilter: "true", limit: "20",
        });
    const tokens = rows.map(normalize).filter((token) => token.symbol && token.contract);
    res.setHeader("Cache-Control", query
      ? "s-maxage=10, stale-while-revalidate=30"
      : "s-maxage=30, stale-while-revalidate=90");
    return res.status(200).json({ mode: query ? "search" : "trending", observedAt: Date.now(), tokens });
  } catch (error) {
    return res.status(502).json({ error: error.message || "Token discovery unavailable" });
  }
}
