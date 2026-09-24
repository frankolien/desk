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
  const isSolana = chainIndex === "501";
  // Solana addresses are case significant, so only EVM keys are folded.
  const key = `${chainIndex}:${isSolana ? tokenAddress : tokenAddress.toLowerCase()}`;
  if (decimalsCache.has(key)) return decimalsCache.get(key);

  const rpc = rpcEndpoint(chainIndex);
  const addressed = isSolana
    ? /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(tokenAddress)
    : /^0x[a-fA-F0-9]{40}$/.test(tokenAddress);
  if (!rpc || !addressed) return null;

  // Solana holds decimals on the mint rather than behind a contract call, so it is asked
  // a different question. Without this it answered "unknown decimals" for every token.
  const request = isSolana
    ? { jsonrpc: "2.0", id: 1, method: "getTokenSupply", params: [tokenAddress] }
    : {
        jsonrpc: "2.0", id: 1, method: "eth_call",
        params: [{ to: tokenAddress, data: DECIMALS_SELECTOR }, "latest"],
      };
  try {
    const response = await fetchImpl(rpc, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(request),
    });
    const payload = await response.json();
    const decimals = isSolana
      ? payload?.result?.value?.decimals
      : (typeof payload?.result === "string" && payload.result !== "0x"
          ? Number.parseInt(payload.result, 16)
          : null);
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


/// MON → AUSD on Monad mainnet, as a transaction the wallet can sign.
///
/// The only swap Desk signs on its own chain. It funds a mainnet desk from an exchange
/// withdrawal of MON without leaving the app, and it is bounded by construction: the
/// wallet sells its native token, so nothing is approved and the most a bad route can
/// take is the MON sent with the call.
export const MONAD = "143";
export const AUSD = "0x00000000efe302beaa2b3e6e1b18d08d69a9012a";
export const NATIVE_MON = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
/// 0x's AllowanceHolder, one address on every chain 0x deploys to.
export const ALLOWANCE_HOLDER = "0x0000000000001ff3684f28c67538d4d072c22734";
const SWAP_SLIPPAGE_BPS = "100";

/// The rule the app applies before signing, applied here too so a changed 0x answer is
/// refused at the edge instead of reaching a phone.
export function swapTransaction(quote, wei) {
  const tx = quote?.transaction;
  if (!tx || quote.liquidityAvailable === false) return null;
  const to = String(tx.to ?? "").toLowerCase();
  const data = String(tx.data ?? "").toLowerCase();
  const ok = to === ALLOWANCE_HOLDER
    && /^0x[0-9a-f]{8,}$/.test(data)
    && String(tx.value) === wei
    && String(quote.sellAmount) === wei
    && /^\d+$/.test(String(quote.buyAmount ?? "")) && quote.buyAmount !== "0"
    && /^\d+$/.test(String(quote.minBuyAmount ?? ""))
    && String(quote.buyToken ?? AUSD).toLowerCase() === AUSD
    && String(quote.sellToken ?? NATIVE_MON).toLowerCase() === NATIVE_MON;
  return ok ? { chainId: Number(MONAD), to: tx.to, data: tx.data, value: String(tx.value) } : null;
}

export function summarizeSwap(quote, transaction, wei) {
  return {
    observedAt: Date.now(),
    pay: { amount: readableUnits(wei, 18), wei, symbol: "MON" },
    receive: {
      amount: readableUnits(quote.buyAmount, 6),
      minimum: readableUnits(quote.minBuyAmount, 6),
      symbol: "AUSD",
    },
    feeMON: readableUnits(String(quote.totalNetworkFee ?? "0"), 18),
    sources: Array.isArray(quote.route?.fills)
      ? [...new Set(quote.route.fills.map((fill) => fill.source).filter(Boolean))] : [],
    transaction,
  };
}

async function swap(req, res) {
  const user = String(req.query.user || "");
  const wei = baseUnits(String(req.query.amount || ""), 18);
  if (!/^0x[a-fA-F0-9]{40}$/.test(user)) {
    return res.status(400).json({ error: "Valid quote parameters required", reason: "invalid" });
  }
  if (!wei || wei === "0") return res.status(400).json({ error: "Enter a valid amount", reason: "invalid" });
  if (!zeroXConfigured()) return res.status(503).json({ error: "No quote provider is configured for this chain.", reason: "unavailable" });

  const params = new URLSearchParams({
    chainId: MONAD, sellToken: NATIVE_MON, buyToken: AUSD, sellAmount: wei,
    taker: user, slippageBps: SWAP_SLIPPAGE_BPS,
  });
  let quote;
  try {
    const response = await fetch(`https://api.0x.org/swap/allowance-holder/quote?${params}`, {
      headers: { "0x-api-key": process.env.ZEROX_API_KEY, "0x-version": "v2" },
    });
    quote = await response.json();
    if (!response.ok) {
      return res.status(422).json({ error: "A live quote is unavailable right now.", reason: "unavailable" });
    }
  } catch {
    return res.status(502).json({ error: "The quote service could not be reached.", reason: "unreachable" });
  }
  if (quote.liquidityAvailable === false) {
    return res.status(422).json({ error: "There is not enough AUSD liquidity for this amount.", reason: "no-liquidity" });
  }
  const transaction = swapTransaction(quote, wei);
  if (!transaction) {
    return res.status(422).json({ error: "This route needs a transaction Desk does not sign.", reason: "unsupported-route" });
  }
  return res.status(200).json(summarizeSwap(quote, transaction, wei));
}

export default async function handler(req, res) {
  if (req.method !== "GET") return res.status(405).json({ error: "GET required" });
  res.setHeader("Cache-Control", "private, no-store");
  if (req.query.view === "swap") return swap(req, res);
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
