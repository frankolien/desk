import crypto from "node:crypto";

import { filter, headlines } from "./_news.mjs";
import { redisStore } from "./_store.mjs";

const TOKENS = {
  BTC: { chainIndex: "1", address: "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599", instrument: "BTC-USDT" },
  ETH: { chainIndex: "1", address: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2", instrument: "ETH-USDT" },
  SOL: { chainIndex: "501", address: "So11111111111111111111111111111111111111112", instrument: "SOL-USDT" },
  PUMP: { chainIndex: "501", address: "pumpCmXqMfrsAkQ5r49WcJnRayYRqmXz6ae8H7H9Dfn", instrument: "PUMP-USDT" },
};
const PERIODS = new Set(["1s", "1m", "3m", "5m", "15m", "30m", "1H", "4H", "1D"]);

async function signedGet(path, params) {
  const query = new URLSearchParams(params).toString();
  const requestPath = `${path}?${query}`;
  const timestamp = new Date().toISOString();
  const sign = crypto.createHmac("sha256", process.env.OKX_SECRET_KEY)
    .update(timestamp + "GET" + requestPath).digest("base64");
  const response = await fetch("https://web3.okx.com" + requestPath, {
    headers: {
      "OK-ACCESS-KEY": process.env.OKX_API_KEY,
      "OK-ACCESS-SIGN": sign,
      "OK-ACCESS-PASSPHRASE": process.env.OKX_PASSPHRASE,
      "OK-ACCESS-TIMESTAMP": timestamp,
    },
  });
  if (!response.ok) throw new Error(`OKX HTTP ${response.status}`);
  const body = await response.json();
  if (body.code !== "0") throw new Error(body.msg || `OKX code ${body.code}`);
  return body.data;
}

async function exchangeCandles(instrument, bar) {
  const query = new URLSearchParams({ instId: instrument, bar, limit: "80" });
  const response = await fetch(`https://www.okx.com/api/v5/market/candles?${query}`);
  if (!response.ok) throw new Error(`OKX exchange HTTP ${response.status}`);
  const body = await response.json();
  if (body.code !== "0" || !Array.isArray(body.data)) {
    throw new Error(body.msg || `OKX exchange code ${body.code}`);
  }
  return body.data;
}

async function dexCandles(identity, bar) {
  return signedGet("/api/v6/dex/market/candles", { ...identity, bar, limit: "80" });
}

export default async function handler(req, res) {
  if (req.method !== "GET") return res.status(405).json({ error: "GET required" });
  // Headlines share this function: same market vocabulary, and the function ceiling holds.
  if (req.query.view === "news") {
    try {
      const items = filter(await headlines({ store: redisStore() }), req.query.symbols);
      res.setHeader("Cache-Control", "public, s-maxage=300, stale-while-revalidate=900");
      return res.status(200).json({ observedAt: Date.now(), items });
    } catch {
      return res.status(502).json({ error: "News could not be read right now." });
    }
  }
  const symbol = String(req.query.symbol || "").toUpperCase();
  const bar = String(req.query.period || "1m");
  const known = TOKENS[symbol];
  const chainIndex = String(req.query.chainIndex || known?.chainIndex || "");
  const address = String(req.query.address || known?.address || "");
  const validChain = /^\d{1,10}$/.test(chainIndex);
  const validAddress = /^0x[a-fA-F0-9]{40}$/.test(address) || /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(address);
  if (!PERIODS.has(bar) || !validChain || !validAddress) return res.status(400).json({ error: "Unsupported market" });
  const limit = Math.min(100, Math.max(1, Number.parseInt(String(req.query.limit ?? "60"), 10) || 60));
  try {
    const common = { chainIndex, tokenContractAddress: address };
    const [candles, trades] = await Promise.all([
      known && known.chainIndex === chainIndex && known.address.toLowerCase() === address.toLowerCase()
        ? exchangeCandles(known.instrument, bar)
        : dexCandles(common, bar),
      signedGet("/api/v6/dex/market/trades", { ...common, limit: String(limit) }),
    ]);
    res.setHeader("Cache-Control", "public, s-maxage=3, stale-while-revalidate=10");
    return res.status(200).json({ symbol, chainIndex, address, bar, observedAt: Date.now(), candles, trades });
  } catch (error) {
    return res.status(502).json({ error: error.message });
  }
}
