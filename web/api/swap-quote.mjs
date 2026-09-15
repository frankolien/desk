import crypto from "node:crypto";

const NATIVE = {
  "501": { address: "11111111111111111111111111111111", symbol: "SOL", decimals: 9 },
};
const EVM_NATIVE = { address: "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", decimals: 18 };
const EVM_SYMBOLS = {
  "1": "ETH", "10": "ETH", "56": "BNB", "137": "POL", "143": "MON",
  "196": "OKB", "8453": "ETH", "42161": "ETH",
};
const ZEROX_CHAINS = new Set(["1", "10", "56", "137", "143", "8453", "42161"]);

function okxConfigured() {
  return Boolean(process.env.OKX_API_KEY && process.env.OKX_SECRET_KEY && process.env.OKX_PASSPHRASE);
}

function zeroXConfigured() {
  return Boolean(process.env.ZEROX_API_KEY);
}

function headers(timestamp, requestPath) {
  const signature = crypto.createHmac("sha256", process.env.OKX_SECRET_KEY)
    .update(timestamp + "GET" + requestPath).digest("base64");
  return {
    "OK-ACCESS-KEY": process.env.OKX_API_KEY,
    "OK-ACCESS-SIGN": signature,
    "OK-ACCESS-PASSPHRASE": process.env.OKX_PASSPHRASE,
    "OK-ACCESS-TIMESTAMP": timestamp,
  };
}

function validAddress(value) {
  return /^0x[a-f0-9]{40}$/.test(value) || /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(value);
}

function baseUnits(text, decimals) {
  if (!/^\d+(\.\d+)?$/.test(text)) return null;
  const [whole, fraction = ""] = text.split(".");
  if (fraction.length > decimals) return null;
  const result = `${whole}${fraction.padEnd(decimals, "0")}`.replace(/^0+(?=\d)/, "");
  return result === "" ? "0" : result;
}

function readableUnits(text, decimals) {
  if (!/^\d+$/.test(String(text || ""))) return null;
  if (decimals === 0) return String(text);
  const padded = String(text).padStart(decimals + 1, "0");
  const whole = padded.slice(0, -decimals) || "0";
  const fraction = decimals === 0 ? "" : padded.slice(-decimals).replace(/0+$/, "");
  return fraction ? `${whole}.${fraction}` : whole;
}

async function okxQuote({ chainIndex, amount, fromTokenAddress, toTokenAddress }) {
  const params = { chainIndex, amount, fromTokenAddress, toTokenAddress };
  const requestPath = `/api/v6/dex/aggregator/quote?${new URLSearchParams(params)}`;
  const timestamp = new Date().toISOString();
  const response = await fetch("https://web3.okx.com" + requestPath, {
    headers: headers(timestamp, requestPath),
  });
  const payload = await response.json();
  if (!response.ok || String(payload.code) !== "0") {
    throw new Error(String(payload.msg || `OKX HTTP ${response.status}`));
  }
  const quote = Array.isArray(payload.data) ? payload.data[0] ?? null : payload.data;
  const router = quote?.routerResult || quote || {};
  if (!router.toTokenAmount) throw new Error("OKX returned no quote amount");
  return {
    toTokenAmount: router.toTokenAmount,
    priceImpactPercentage: router.priceImpactPercentage ?? quote?.priceImpactPercentage ?? null,
    estimateGasFee: router.estimateGasFee ?? quote?.estimateGasFee ?? null,
  };
}

async function zeroXQuote({ chainIndex, amount, fromTokenAddress, toTokenAddress }) {
  const params = new URLSearchParams({
    chainId: chainIndex,
    sellToken: fromTokenAddress,
    buyToken: toTokenAddress,
    sellAmount: amount,
  });
  const response = await fetch(`https://api.0x.org/swap/allowance-holder/price?${params}`, {
    headers: {
      "0x-api-key": process.env.ZEROX_API_KEY,
      "0x-version": "v2",
      "Content-Type": "application/json",
    },
  });
  const payload = await response.json();
  if (!response.ok) {
    throw new Error(String(payload.message || payload.reason || `0x HTTP ${response.status}`));
  }
  if (payload.liquidityAvailable === false || !payload.buyAmount) {
    throw new Error("0x found no liquidity for this pair");
  }
  return {
    toTokenAmount: payload.buyAmount,
    priceImpactPercentage: null,
    estimateGasFee: payload.totalNetworkFee ?? null,
  };
}

export default async function handler(req, res) {
  if (req.method !== "GET") return res.status(405).json({ error: "GET required" });
  const chainIndex = String(req.query.chainIndex || "");
  const tokenAddress = String(req.query.tokenAddress || "");
  const tokenDecimals = Number(req.query.tokenDecimals);
  const side = String(req.query.side || "buy").toLowerCase();
  const readableAmount = String(req.query.amount || "");
  const native = NATIVE[chainIndex] || (EVM_SYMBOLS[chainIndex]
    ? { ...EVM_NATIVE, symbol: EVM_SYMBOLS[chainIndex] } : null);
  if (!native || !validAddress(tokenAddress) || !Number.isInteger(tokenDecimals)
      || tokenDecimals < 0 || tokenDecimals > 30 || !["buy", "sell"].includes(side)) {
    return res.status(400).json({ error: "Valid quote parameters required" });
  }
  const sourceDecimals = side === "buy" ? native.decimals : tokenDecimals;
  const amount = baseUnits(readableAmount, sourceDecimals);
  if (!amount || amount === "0") return res.status(400).json({ error: "Enter a valid amount" });
  const fromTokenAddress = side === "buy" ? native.address : tokenAddress;
  const toTokenAddress = side === "buy" ? tokenAddress : native.address;
  const request = { chainIndex, amount, fromTokenAddress, toTokenAddress };
  const attempts = [];
  if (okxConfigured()) attempts.push(["okx", okxQuote]);
  if (ZEROX_CHAINS.has(chainIndex) && zeroXConfigured()) attempts.push(["0x", zeroXQuote]);
  if (attempts.length === 0) {
    const detail = chainIndex === "501"
      ? "OKX quote credentials are not configured."
      : "No quote provider is configured for this chain.";
    return res.status(503).json({ error: detail });
  }

  const failures = [];
  for (const [provider, quoteRequest] of attempts) {
    try {
      const quote = await quoteRequest(request);
      const destinationDecimals = side === "buy" ? tokenDecimals : native.decimals;
      res.setHeader("Cache-Control", "private, no-store");
      return res.status(200).json({
        observedAt: Date.now(), side, nativeSymbol: native.symbol, provider,
        quote: {
          toAmountReadable: readableUnits(quote.toTokenAmount, destinationDecimals),
          priceImpactPercentage: quote.priceImpactPercentage,
          estimateGasFee: quote.estimateGasFee,
        },
      });
    } catch (error) {
      failures.push(`${provider}: ${error.message || "quote unavailable"}`);
    }
  }
  return res.status(502).json({ error: "Quote unavailable", providers: failures });
}
