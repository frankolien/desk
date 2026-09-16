import crypto from "node:crypto";
import {
  ZEROX_CHAINS, chainName, isQuotable, nativeToken, rpcEndpoint,
} from "./_chains.mjs";

/// `decimals()`. Resolved from the chain rather than required from the caller: the
/// discovery feed returns a null decimal for every token OKX trends, so a client that had
/// to supply one could never ask for a quote at all.
const DECIMALS_SELECTOR = "0x313ce567";
const decimalsCache = new Map();

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

export function validAddress(value) {
  return /^0x[a-fA-F0-9]{40}$/.test(value) || /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(value);
}

export function baseUnits(text, decimals) {
  if (!/^\d+(\.\d+)?$/.test(text)) return null;
  const [whole, fraction = ""] = text.split(".");
  if (fraction.length > decimals) return null;
  const result = `${whole}${fraction.padEnd(decimals, "0")}`.replace(/^0+(?=\d)/, "");
  return result === "" ? "0" : result;
}

export function readableUnits(text, decimals) {
  if (!/^\d+$/.test(String(text || ""))) return null;
  if (decimals === 0) return String(text);
  const padded = String(text).padStart(decimals + 1, "0");
  const whole = padded.slice(0, -decimals) || "0";
  const fraction = decimals === 0 ? "" : padded.slice(-decimals).replace(/0+$/, "");
  return fraction ? `${whole}.${fraction}` : whole;
}

/// A token's decimals, from the caller's hint when it has one and from the chain when it
/// does not. Cached: the same token is quoted repeatedly while someone edits an amount.
export async function resolveDecimals(chainIndex, tokenAddress, hint, fetchImpl = fetch) {
  if (Number.isInteger(hint) && hint >= 0 && hint <= 30) return hint;
  const key = `${chainIndex}:${tokenAddress.toLowerCase()}`;
  if (decimalsCache.has(key)) return decimalsCache.get(key);

  const rpc = rpcEndpoint(chainIndex);
  if (!rpc || !/^0x[a-fA-F0-9]{40}$/.test(tokenAddress)) return null;
  try {
    const response = await fetchImpl(rpc, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0", id: 1, method: "eth_call",
        params: [{ to: tokenAddress, data: DECIMALS_SELECTOR }, "latest"],
      }),
    });
    const payload = await response.json();
    const result = payload?.result;
    if (typeof result !== "string" || result === "0x") return null;
    const decimals = Number.parseInt(result, 16);
    if (!Number.isInteger(decimals) || decimals < 0 || decimals > 30) return null;
    decimalsCache.set(key, decimals);
    return decimals;
  } catch {
    return null;
  }
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
  const side = String(req.query.side || "buy").toLowerCase();
  const readableAmount = String(req.query.amount || "");
  const hinted = Number(req.query.tokenDecimals);

  // Malformed input and an unsupported chain are different answers. They used to share
  // one 400, so the app could not tell a bad request from a chain Desk cannot price.
  if (!validAddress(tokenAddress) || !["buy", "sell"].includes(side)) {
    return res.status(400).json({ error: "Valid quote parameters required" });
  }
  const native = nativeToken(chainIndex);
  if (!isQuotable(chainIndex) || !native) {
    return res.status(422).json({
      error: `Desk cannot quote on ${chainName(chainIndex)} yet.`,
      reason: "unsupported-chain",
      chainIndex,
      chainName: chainName(chainIndex),
    });
  }

  const tokenDecimals = await resolveDecimals(
    chainIndex, tokenAddress, Number.isInteger(hinted) ? hinted : undefined);
  if (tokenDecimals === null) {
    return res.status(422).json({
      error: "This token's decimal precision could not be confirmed on-chain, so it cannot be quoted safely.",
      reason: "unknown-decimals",
      chainIndex,
      chainName: chainName(chainIndex),
    });
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
    return res.status(503).json({
      error: chainIndex === "501"
        ? "OKX quote credentials are not configured."
        : "No quote provider is configured for this chain.",
    });
  }

  const failures = [];
  for (const [provider, quoteRequest] of attempts) {
    try {
      const quote = await quoteRequest(request);
      const destinationDecimals = side === "buy" ? tokenDecimals : native.decimals;
      res.setHeader("Cache-Control", "private, no-store");
      return res.status(200).json({
        observedAt: Date.now(), side, nativeSymbol: native.symbol, provider,
        chainName: chainName(chainIndex), tokenDecimals,
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
