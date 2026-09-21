import { chainName, isBuyable } from "./_chains.mjs";
import { baseUnits } from "./swap-quote.mjs";

const RELAY = "https://api.relay.link";
const MONAD = 143;
const NATIVE = "0x0000000000000000000000000000000000000000";
export const DEPOSITORY = "0x4cd00e387622c35bddb9b4c962c136462338bc31";
const DEPOSIT_NATIVE = "0x49290c1c";

const REASONS = {
  NO_SWAP_ROUTES_FOUND: ["no-route", "No route can fill this amount. Try a larger one."],
  AMOUNT_TOO_LOW: ["amount-too-low", "This amount is too small to cover the fill."],
  INVALID_OUTPUT_CURRENCY: ["unsupported-token", "Relay cannot deliver this token."],
  INVALID_INPUT_CURRENCY: ["unsupported-token", "Relay cannot deliver this token."],
  INSUFFICIENT_LIQUIDITY: ["no-liquidity", "There is not enough liquidity for this amount."],
};

const evmAddress = (value) => /^0x[a-fA-F0-9]{40}$/.test(value);

/// The same rule the app applies before signing, applied here too so a changed Relay
/// response is refused at the edge instead of reaching a phone.
export function depositTransaction(quote, user, wei) {
  if (quote?.steps?.length !== 1) return null;
  const [step] = quote.steps;
  if (step.kind !== "transaction" || step.items?.length !== 1) return null;
  const tx = step.items[0].data;
  const data = String(tx?.data ?? "").toLowerCase();
  const ok = tx?.chainId === MONAD
    && String(tx.to).toLowerCase() === DEPOSITORY
    && data.length === 2 + 8 + 64 + 64
    && data.startsWith(DEPOSIT_NATIVE)
    && data.slice(10, 74) === user.toLowerCase().slice(2).padStart(64, "0")
    && String(tx.value) === wei;
  return ok ? { chainId: MONAD, to: tx.to, data: tx.data, value: String(tx.value) } : null;
}

/// The quote has to describe the route that was asked for.
///
/// `depositTransaction` checks what leaves the wallet — chain, depository, selector,
/// depositor and value — and is airtight on that. It says nothing about what arrives,
/// because the only thing binding this deposit to a destination is Relay's own request id
/// inside the calldata. So the figures the sheet shows are checked against the route the
/// caller asked for: a quote that pays out a different token, or on a different chain, is
/// refused rather than displayed.
export function matchesRoute(quote, chainIndex, token) {
  const out = quote?.details?.currencyOut?.currency;
  const into = quote?.details?.currencyIn?.currency;
  if (!out || !into) return false;
  if (Number(out.chainId) !== Number(chainIndex)) return false;
  if (String(out.address ?? "").toLowerCase() !== String(token).toLowerCase()) return false;
  if (Number(into.chainId) !== MONAD) return false;
  return String(into.address ?? "").toLowerCase() === NATIVE.toLowerCase();
}

export function summarize(quote, transaction) {
  const details = quote.details ?? {};
  const fees = quote.fees ?? {};
  const usd = (value) => (value == null || Number.isNaN(Number(value)) ? null : String(value));
  const feeUsd = ["gas", "relayer"]
    .map((key) => Number(fees[key]?.amountUsd))
    .filter((value) => Number.isFinite(value))
    .reduce((sum, value) => sum + value, 0);
  return {
    requestId: quote.steps[0].requestId,
    pay: { amount: details.currencyIn?.amountFormatted, usd: usd(details.currencyIn?.amountUsd) },
    receive: {
      amount: details.currencyOut?.amountFormatted,
      minimum: formatUnits(details.currencyOut?.minimumAmount, details.currencyOut?.currency?.decimals),
      usd: usd(details.currencyOut?.amountUsd),
      symbol: details.currencyOut?.currency?.symbol,
    },
    feeUsd: String(Math.round(feeUsd * 100) / 100),
    impactPercent: details.totalImpact?.percent ?? null,
    seconds: details.timeEstimate ?? null,
    transaction,
  };
}

function formatUnits(raw, decimals) {
  if (!/^\d+$/.test(String(raw ?? "")) || !Number.isInteger(decimals)) return null;
  const padded = String(raw).padStart(decimals + 1, "0");
  const whole = padded.slice(0, padded.length - decimals);
  const fraction = decimals ? padded.slice(-decimals).replace(/0+$/, "") : "";
  return fraction ? `${whole}.${fraction}` : whole;
}

/// Relay's own words, folded to the four states a buyer needs to see.
export function phase(status) {
  switch (status) {
    case "success": return "filled";
    case "refund": case "refunded": return "refunded";
    case "failure": return "failed";
    default: return "pending";
  }
}

async function status(fetchImpl, req, res) {
  const requestId = String(req.query.requestId || "");
  if (!/^0x[a-fA-F0-9]{64}$/.test(requestId)) {
    return res.status(400).json({ error: "A request id is required." });
  }
  try {
    const response = await fetchImpl(`${RELAY}/intents/status/v3?requestId=${requestId}`, {
      headers: process.env.RELAY_API_KEY ? { "x-api-key": process.env.RELAY_API_KEY } : {},
    });
    if (!response.ok) return res.status(502).json({ error: "Relay status is unavailable." });
    const body = await response.json();
    return res.status(200).json({
      phase: phase(body.status),
      destinationTx: Array.isArray(body.txHashes) ? body.txHashes.at(-1) ?? null : null,
    });
  } catch {
    return res.status(502).json({ error: "Relay status is unavailable." });
  }
}

// `/api/relay-status` is rewritten here with `view=status`; the path is checked too in
// case the rewrite ever drops the destination's own query.
const wantsStatus = (req) => req.query?.view === "status" || String(req.url ?? "").split("?")[0].endsWith("/relay-status");

export function createHandler(fetchImpl = fetch) {
  return async function handler(req, res) {
    res.setHeader("Cache-Control", "private, no-store");
    if (req.method !== "GET") return res.status(405).json({ error: "GET required" });
    if (wantsStatus(req)) return status(fetchImpl, req, res);
    const user = String(req.query.user || "");
    const chainIndex = String(req.query.chainIndex || "");
    const token = String(req.query.tokenAddress || "");
    const wei = baseUnits(String(req.query.amount || ""), 18);

    if (!evmAddress(user) || !evmAddress(token)) {
      return res.status(400).json({ error: "Valid quote parameters required", reason: "invalid" });
    }
    if (!wei || wei === "0") return res.status(400).json({ error: "Enter a valid amount", reason: "invalid" });
    if (!isBuyable(chainIndex)) {
      return res.status(422).json({
        error: `Buying on ${chainName(chainIndex)} is not available yet.`,
        reason: "unsupported-chain",
      });
    }

    let quote;
    try {
      const response = await fetchImpl(`${RELAY}/quote`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          ...(process.env.RELAY_API_KEY ? { "x-api-key": process.env.RELAY_API_KEY } : {}),
        },
        body: JSON.stringify({
          user, recipient: user,
          originChainId: MONAD, originCurrency: NATIVE,
          destinationChainId: Number(chainIndex), destinationCurrency: token,
          amount: wei, tradeType: "EXACT_INPUT",
        }),
      });
      quote = await response.json();
      if (!response.ok) {
        const [reason, error] = REASONS[quote?.errorCode] ?? ["unavailable", "A live quote is unavailable right now."];
        return res.status(422).json({ error, reason });
      }
    } catch {
      return res.status(502).json({ error: "The quote service could not be reached.", reason: "unreachable" });
    }

    const transaction = depositTransaction(quote, user, wei);
    if (!transaction || !matchesRoute(quote, chainIndex, token)) {
      return res.status(422).json({ error: "This route needs a transaction Desk does not sign.", reason: "unsupported-route" });
    }
    return res.status(200).json(summarize(quote, transaction));
  };
}

export default createHandler();
