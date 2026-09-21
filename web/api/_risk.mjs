import { okxGet, okxPost } from "./_okx.mjs";

/// Risk for a token, as reasons a person can check rather than a score they cannot:
/// each triggered reason carries a weight, the weights add up to a level, and the
/// reasons are shown while the number is not. No data is "unchecked", never "low".
///
///   GET /api/token-details?view=risk&chainIndex=143&address=0x…[&riskLevel=&communityRecognized=]

const NADFUN_TOKEN_URL = "https://api.nad.fun/token/";

const number = (value) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
};

const compact = (value) => {
  if (value >= 1e9) return `$${(value / 1e9).toFixed(1)}B`;
  if (value >= 1e6) return `$${(value / 1e6).toFixed(1)}M`;
  if (value >= 1e3) return `$${(value / 1e3).toFixed(1)}K`;
  return `$${Math.round(value)}`;
};

const ago = (seconds) => {
  if (seconds < 3600) return `${Math.max(1, Math.round(seconds / 60))} minutes ago`;
  if (seconds < 86_400) return `${Math.round(seconds / 3600)} hours ago`;
  return `${Math.round(seconds / 86_400)} days ago`;
};

export function okxRiskLevel(value) {
  const text = String(value ?? "").toLowerCase();
  if (text === "high" || text === "true" || Number(text) >= 3) return "high";
  if (text === "medium" || Number(text) === 2) return "medium";
  return null;
}

/// The largest holder is very often the pool itself. When its balance is about what
/// the pool would hold for the quoted liquidity, it is treated as the pool and left
/// out of the concentration count.
export function looksLikePool(holder, { liquidity, price }) {
  if (!holder || liquidity == null || price == null || price <= 0) return false;
  const poolTokens = (liquidity / 2) / price;
  return holder.amount > 0 && Math.abs(holder.amount - poolTokens) / poolTokens < 0.35;
}

export function assessToken({
  liquidity = null, marketCap = null, holders = [], trades = [], price = null,
  createdAt = null, creator = null, graduated = null, riskFlag = null, communityRecognized = null, now = Date.now(),
} = {}) {
  const reasons = [];
  const facts = [];
  const push = (code, weight, text) => reasons.push({ code, weight, text, severity: weight >= 6 ? "high" : weight >= 3 ? "caution" : "info" });

  let checked = false;

  if (liquidity != null) {
    checked = true;
    if (liquidity < 10_000) push("thin_liquidity", 6, `Liquidity is thin: ${compact(liquidity)} in pool`);
    else if (liquidity < 50_000) push("light_liquidity", 3, `Liquidity is light: ${compact(liquidity)} in pool`);
  }

  const ranked = holders
    .map((row) => ({ address: String(row.address ?? "").toLowerCase(), amount: number(row.amount) ?? 0, percent: number(row.percent) ?? 0 }))
    .sort((a, b) => b.percent - a.percent);
  if (ranked.length) {
    checked = true;
    const people = looksLikePool(ranked[0], { liquidity, price }) ? ranked.slice(1) : ranked;
    const topTen = people.slice(0, 10).reduce((sum, row) => sum + row.percent, 0);
    if (topTen > 50) push("concentrated", 6, `Top 10 wallets hold ${Math.round(topTen)}% of supply`);
    else if (topTen > 30) push("concentrated", 3, `Top 10 wallets hold ${Math.round(topTen)}% of supply`);
    if (creator) {
      const own = people.find((row) => row.address === String(creator).toLowerCase());
      if (own && own.percent > 10) push("creator_share", 3, `Creator wallet holds ${Math.round(own.percent)}% of supply`);
    }
  }

  if (createdAt != null) {
    checked = true;
    const age = now / 1000 - createdAt;
    if (age < 3600) push("brand_new", 6, `Launched ${ago(age)}`);
    else if (age < 86_400) push("new", 3, `Launched ${ago(age)}`);
    else facts.push({ code: "age", text: `Launched ${ago(age)}` });
  }

  if (trades.length >= 20) {
    checked = true;
    const sells = trades.filter((row) => String(row.type ?? row.side ?? "").toLowerCase() === "sell").length;
    if (sells === 0) push("no_sells", 3, `No sells seen in the last ${trades.length} trades`);
    else facts.push({ code: "sells", text: `${sells} of the last ${trades.length} trades were sells` });
  }

  // OKX's riskLevelControl: 1 is ordinary, 2 elevated, 3 and up flagged.
  if (riskFlag === "high") { checked = true; push("flagged", 6, "Flagged by OKX as high risk"); }
  else if (riskFlag === "medium") { checked = true; push("okx_medium", 3, "OKX rates this token medium risk"); }
  if (communityRecognized === false) { checked = true; push("unrecognized", 1, "Not recognized by the community yet"); }
  else if (communityRecognized === true) facts.push({ code: "recognized", text: "Recognized by the community" });
  if (graduated === false) push("bonding_curve", 1, "Still on the bonding curve");
  else if (graduated === true) facts.push({ code: "graduated", text: "Graduated to a pool" });
  if (marketCap != null) facts.push({ code: "market_cap", text: `Market cap ${compact(marketCap)}` });

  reasons.sort((a, b) => b.weight - a.weight);
  const total = reasons.reduce((sum, reason) => sum + reason.weight, 0);
  const level = !checked ? "unchecked" : total >= 6 ? "high" : total >= 3 ? "caution" : "low";
  return { level, reasons: reasons.map(({ code, text, severity }) => ({ code, text, severity })), facts, checkedAt: now };
}

async function nadfunToken(address, fetchImpl) {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 3_000);
    const response = await fetchImpl(`${NADFUN_TOKEN_URL}${address}`, { signal: controller.signal });
    clearTimeout(timer);
    if (!response.ok) return null;
    const info = (await response.json())?.token_info;
    if (!info) return null;
    return {
      createdAt: number(info.created_at),
      creator: info.creator?.account_id ?? null,
      graduated: typeof info.is_graduated === "boolean" ? info.is_graduated : null,
    };
  } catch {
    return null;
  }
}

export async function handleRisk(req, res, { fetchImpl = fetch, okx = { get: okxGet, post: okxPost } } = {}) {
  const chainIndex = String(req.query.chainIndex ?? "");
  const address = String(req.query.address ?? "");
  if (!/^\d{1,10}$/.test(chainIndex) || !(/^0x[a-fA-F0-9]{40}$/.test(address) || (chainIndex === "501" && /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(address)))) {
    return res.status(400).json({ error: "chainIndex and a token address are required." });
  }
  const identity = { chainIndex, tokenContractAddress: address };
  const flag = req.query.riskLevel == null ? null : okxRiskLevel(String(req.query.riskLevel));
  const recognized = req.query.communityRecognized == null ? null : String(req.query.communityRecognized) === "true";
  try {
    const [priceRows, holderRows, tradeRows, launch] = await Promise.all([
      okx.post("/api/v6/dex/market/price-info", [identity]).catch(() => null),
      okx.get("/api/v6/dex/market/token/holder", { ...identity, limit: "20" }).catch(() => null),
      okx.get("/api/v6/dex/market/trades", { ...identity, limit: "100" }).catch(() => null),
      chainIndex === "143" ? nadfunToken(address, fetchImpl) : null,
    ]);
    const info = Array.isArray(priceRows) ? priceRows[0] : priceRows;
    const holders = (Array.isArray(holderRows) ? holderRows : holderRows?.holderList ?? [])
      .map((row) => ({ address: row.holderWalletAddress, amount: row.holdAmount, percent: row.holdPercent }));
    const assessment = assessToken({
      liquidity: number(info?.liquidity), marketCap: number(info?.marketCap), price: number(info?.price),
      holders, trades: Array.isArray(tradeRows) ? tradeRows : [],
      createdAt: launch?.createdAt ?? null, creator: launch?.creator ?? null, graduated: launch?.graduated ?? null,
      riskFlag: flag, communityRecognized: recognized,
    });
    res.setHeader("Cache-Control", "public, s-maxage=60, stale-while-revalidate=300");
    return res.status(200).json({ chainIndex, address, ...assessment });
  } catch (error) {
    return res.status(502).json({ error: error.message });
  }
}
