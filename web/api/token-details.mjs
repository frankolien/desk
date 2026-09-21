import { okxGet, okxPost } from "./_okx.mjs";
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

/// One OKX call for a whole table: `?view=prices&tokens=chain:addr,chain:addr` (up to 20).
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
    res.setHeader("Cache-Control", "public, s-maxage=3, stale-while-revalidate=10");
    return res.status(200).json({ observedAt: Date.now(), prices });
  } catch (error) {
    return res.status(502).json({ error: error.message });
  }
}

export default async function handler(req, res) {
  if (req.method !== "GET") return res.status(405).json({ error: "GET required" });
  if (req.query.view === "holdings") return handleHoldings(req, res);
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
