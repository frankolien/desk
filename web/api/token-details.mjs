import crypto from "node:crypto";

const TOKENS = {
  BTC: { chainIndex: "1", address: "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599" },
  ETH: { chainIndex: "1", address: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2" },
  SOL: { chainIndex: "501", address: "So11111111111111111111111111111111111111112" },
  PUMP: { chainIndex: "501", address: "pumpCmXqMfrsAkQ5r49WcJnRayYRqmXz6ae8H7H9Dfn" },
};

function headers(timestamp, method, requestPath, body = "") {
  const sign = crypto.createHmac("sha256", process.env.OKX_SECRET_KEY)
    .update(timestamp + method + requestPath + body).digest("base64");
  return {
    "Content-Type": "application/json",
    "OK-ACCESS-KEY": process.env.OKX_API_KEY,
    "OK-ACCESS-SIGN": sign,
    "OK-ACCESS-PASSPHRASE": process.env.OKX_PASSPHRASE,
    "OK-ACCESS-TIMESTAMP": timestamp,
  };
}

async function okxGet(path, params) {
  const requestPath = `${path}?${new URLSearchParams(params)}`;
  const timestamp = new Date().toISOString();
  const response = await fetch("https://web3.okx.com" + requestPath, {
    headers: headers(timestamp, "GET", requestPath),
  });
  const payload = await response.json();
  if (!response.ok || String(payload.code) !== "0") {
    throw new Error(payload.msg || `OKX HTTP ${response.status}`);
  }
  return payload.data;
}

async function okxPost(path, value) {
  const body = JSON.stringify(value);
  const timestamp = new Date().toISOString();
  const response = await fetch("https://web3.okx.com" + path, {
    method: "POST",
    headers: headers(timestamp, "POST", path, body),
    body,
  });
  const payload = await response.json();
  if (!response.ok || String(payload.code) !== "0") {
    throw new Error(payload.msg || `OKX HTTP ${response.status}`);
  }
  return payload.data;
}

export default async function handler(req, res) {
  if (req.method !== "GET") return res.status(405).json({ error: "GET required" });
  const symbol = String(req.query.symbol || "").toUpperCase();
  const token = TOKENS[symbol];
  if (!token) return res.status(400).json({ error: "Token details are not available for this market" });

  const identity = { chainIndex: token.chainIndex, tokenContractAddress: token.address };
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
