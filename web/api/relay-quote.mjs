import { encodeAbiParameters, encodeFunctionData } from "viem";
import { chainName, isBuyable, rpcEndpoint } from "./_chains.mjs";
import { AUSD as SEND_AUSD, prepare as prepareSend, status as sendStatus, submit as submitSend } from "./_send.mjs";
import { redisStore } from "./_store.mjs";
import { baseUnits, readableUnits, resolveDecimals } from "./swap-quote.mjs";

const RELAY = "https://api.relay.link";
const MONAD = 143;
const NATIVE = "0x0000000000000000000000000000000000000000";
export const DEPOSITORY = "0x4cd00e387622c35bddb9b4c962c136462338bc31";
const DEPOSIT_NATIVE = "0x49290c1c";

/// Selling a token on another chain for AUSD on Monad, with no gas on that chain: the wallet
/// runs Calibur, Uniswap's batch executor, by an EIP-7702 authorization signed off-chain, and
/// signs Relay's approval and deposit as one batch that Relay's relayer submits, taking the gas
/// from the proceeds. The approval's spender and the deposit's target are Relay's router, the
/// same contract on every chain, and nothing else is ever signed.
const AUSD = "0x00000000efe302beaa2b3e6e1b18d08d69a9012a";
export const CALIBUR = "0x000000009b1d0af20d8c6d0a44e162d11f9b8f00";
export const RELAY_ROUTER = "0xccc88a9d1b4ed6b0eaba998850414b24f1c315be";
const APPROVE = "0x095ea7b3";
const GET_SEQ = "0x6a1ea88d";
const CALIBUR_OVERHEAD = "80000";
const CALIBUR_ABI = [{
  name: "execute", type: "function", stateMutability: "payable", outputs: [],
  inputs: [
    { name: "signedBatchedCall", type: "tuple", components: [
      { name: "batchedCall", type: "tuple", components: [
        { name: "calls", type: "tuple[]", components: [{ name: "to", type: "address" }, { name: "value", type: "uint256" }, { name: "data", type: "bytes" }] },
        { name: "revertOnFailure", type: "bool" },
      ] },
      { name: "nonce", type: "uint256" }, { name: "keyHash", type: "bytes32" }, { name: "executor", type: "address" }, { name: "deadline", type: "uint256" },
    ] },
    { name: "wrappedSignature", type: "bytes" },
  ],
}];
const ZERO_WORD = "0x" + "0".repeat(64);
const word = (hex) => hex.toLowerCase().replace(/^0x/, "").padStart(64, "0");

const REASONS = {
  NO_SWAP_ROUTES_FOUND: ["no-route", "No route can fill this amount. Try a larger one."],
  AMOUNT_TOO_LOW: ["amount-too-low", "This amount is too small to cover the fill."],
  INVALID_OUTPUT_CURRENCY: ["unsupported-token", "Relay cannot deliver this token."],
  INVALID_INPUT_CURRENCY: ["unsupported-token", "Relay cannot deliver this token."],
  INSUFFICIENT_LIQUIDITY: ["no-liquidity", "There is not enough liquidity for this amount."],
};

const evmAddress = (value) => /^0x[a-fA-F0-9]{40}$/.test(value);

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

/// The same deposit paid in AUSD: Relay's approval on AUSD to the depository for exactly the
/// amount, then `depositErc20(depositor, AUSD, amount, id)` on the depository carrying nothing.
const DEPOSIT_ERC20 = "0xe8017952";
export function depositWithAUSD(quote, user, raw) {
  const items = (quote?.steps ?? []).flatMap((step) => (step.kind === "transaction" ? step.items ?? [] : [{ kind: step.kind }]));
  if (items.length !== 2 || items.some((item) => item.kind)) return null;
  const [approve, deposit] = items.map((item) => ({ to: String(item.data?.to ?? "").toLowerCase(), data: String(item.data?.data ?? "").toLowerCase(), value: String(item.data?.value ?? "0"), chainId: Number(item.data?.chainId) }));
  const approval = APPROVE + word(DEPOSITORY) + word(BigInt(raw).toString(16));
  const ok = approve.chainId === MONAD && deposit.chainId === MONAD && approve.value === "0" && deposit.value === "0"
    && approve.to === AUSD && approve.data === approval
    && deposit.to === DEPOSITORY && deposit.data.length === 2 + 8 + 64 * 4 && deposit.data.startsWith(DEPOSIT_ERC20)
    && deposit.data.slice(10, 74) === word(user) && deposit.data.slice(74, 138) === word(AUSD) && deposit.data.slice(138, 202) === word(BigInt(raw).toString(16));
  if (!ok) return null;
  const tx = items[1].data;
  return { transaction: { chainId: MONAD, to: tx.to, data: tx.data, value: "0" }, approval: { token: AUSD, spender: DEPOSITORY, amount: raw } };
}

/// `depositTransaction` checks only what leaves the wallet; nothing binds what arrives but
/// Relay's request id, so a quote paying a different token or chain is refused here.
export function matchesRoute(quote, chainIndex, token, paying = NATIVE) {
  const out = quote?.details?.currencyOut?.currency;
  const into = quote?.details?.currencyIn?.currency;
  if (!out || !into) return false;
  if (Number(out.chainId) !== Number(chainIndex)) return false;
  if (String(out.address ?? "").toLowerCase() !== String(token).toLowerCase()) return false;
  if (Number(into.chainId) !== MONAD) return false;
  return String(into.address ?? "").toLowerCase() === paying.toLowerCase();
}

/// Relay's two calls for a sale, and nothing else: an approval on the sold token, to the
/// router, for exactly the amount sold, then a deposit on the router carrying nothing. The
/// route must pay the token on that chain and deliver AUSD on Monad.
export function saleCalls(quote, chainIndex, token, raw) {
  const items = (quote?.steps ?? []).flatMap((step) => (step.kind === "transaction" ? step.items ?? [] : [{ kind: step.kind }]));
  if (items.length !== 2 || items.some((item) => item.kind)) return null;
  const calls = items.map((item) => ({ to: String(item.data?.to ?? "").toLowerCase(), data: String(item.data?.data ?? "").toLowerCase(), value: String(item.data?.value ?? "0"), chainId: Number(item.data?.chainId) }));
  const approval = APPROVE + word(RELAY_ROUTER) + word(BigInt(raw).toString(16));
  const ok = calls.every((call) => call.value === "0" && call.chainId === Number(chainIndex) && /^0x[0-9a-f]{8,}$/.test(call.data))
    && calls[0].to === String(token).toLowerCase() && calls[0].data === approval
    && calls[1].to === RELAY_ROUTER;
  const into = quote?.details?.currencyIn?.currency;
  const out = quote?.details?.currencyOut?.currency;
  const routed = Number(into?.chainId) === Number(chainIndex) && String(into?.address ?? "").toLowerCase() === String(token).toLowerCase()
    && Number(out?.chainId) === MONAD && String(out?.address ?? "").toLowerCase() === AUSD;
  return ok && routed ? calls.map(({ to, data }) => ({ to, value: "0", data })) : null;
}

export function summarizeSale(quote, calls, raw, decimals, symbol, account) {
  const details = quote.details ?? {};
  const fees = quote.fees ?? {};
  const usd = (value) => (value == null || Number.isNaN(Number(value)) ? null : String(value));
  const feeUsd = ["gas", "relayer"].map((key) => Number(fees[key]?.amountUsd)).filter(Number.isFinite).reduce((sum, value) => sum + value, 0);
  return {
    requestId: quote.steps[0].requestId,
    chainId: Number(details.currencyIn?.currency?.chainId),
    calls,
    pay: { amount: readableUnits(raw, decimals), raw, symbol, usd: usd(details.currencyIn?.amountUsd) },
    receive: {
      amount: details.currencyOut?.amountFormatted,
      minimum: formatUnits(details.currencyOut?.minimumAmount, 6),
      usd: usd(details.currencyOut?.amountUsd),
      symbol: "AUSD",
    },
    feeUsd: String(Math.round(feeUsd * 100) / 100),
    seconds: details.timeEstimate ?? null,
    account,
  };
}

/// Calibur's `execute(SignedBatchedCall, wrappedSignature)` for the batch the wallet signed:
/// the signature covers every field, so a changed call fails on chain rather than runs.
export function executeCalldata({ calls, nonce, signature }) {
  const signedBatchedCall = {
    batchedCall: { calls: calls.map((call) => ({ to: call.to, value: BigInt(call.value ?? "0"), data: call.data })), revertOnFailure: true },
    nonce: BigInt(nonce), keyHash: ZERO_WORD, executor: "0x" + "0".repeat(40), deadline: 0n,
  };
  const wrapped = encodeAbiParameters([{ type: "bytes" }, { type: "bytes" }], [signature, "0x"]);
  return encodeFunctionData({ abi: CALIBUR_ABI, functionName: "execute", args: [signedBatchedCall, wrapped] });
}

async function rpc(fetchImpl, chainIndex, method, params) {
  const endpoint = rpcEndpoint(chainIndex);
  if (!endpoint) throw new Error("no rpc");
  const response = await fetchImpl(endpoint, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const payload = await response.json();
  if (payload.error) throw new Error(payload.error.message || "rpc error");
  return payload.result;
}

/// Whether the wallet already runs Calibur on that chain, its transaction count for the
/// authorization if not, and Calibur's sequence for the batch.
async function accountState(fetchImpl, chainIndex, user) {
  const code = await rpc(fetchImpl, chainIndex, "eth_getCode", [user, "latest"]);
  const delegated = String(code ?? "").toLowerCase() === "0xef0100" + CALIBUR.slice(2);
  const count = await rpc(fetchImpl, chainIndex, "eth_getTransactionCount", [user, "latest"]);
  let batchNonce = "0";
  if (delegated) {
    const seq = await rpc(fetchImpl, chainIndex, "eth_call", [{ to: user, data: GET_SEQ + "0".repeat(64) }, "latest"]);
    if (/^0x[0-9a-f]+$/i.test(String(seq))) batchNonce = BigInt(seq).toString();
  }
  return { delegated, authorizationNonce: Number.parseInt(String(count), 16), batchNonce };
}

const relayHeaders = () => ({ "content-type": "application/json", ...(process.env.RELAY_API_KEY ? { "x-api-key": process.env.RELAY_API_KEY } : {}) });

async function sell(fetchImpl, req, res) {
  const user = String(req.query.user || "");
  const chainIndex = String(req.query.chainIndex || "");
  const token = String(req.query.tokenAddress || "");
  const symbol = String(req.query.symbol || "TOKEN").slice(0, 12);
  if (!evmAddress(user) || !evmAddress(token) || !/^\d{1,10}$/.test(chainIndex) || Number(chainIndex) === MONAD) {
    return res.status(400).json({ error: "Valid quote parameters required", reason: "invalid" });
  }
  if (!isBuyable(chainIndex) || !rpcEndpoint(chainIndex)) {
    return res.status(422).json({ error: `Selling on ${chainName(chainIndex)} is not available yet.`, reason: "unsupported-chain" });
  }
  const decimals = await resolveDecimals(chainIndex, token, undefined, fetchImpl);
  if (decimals === null) return res.status(422).json({ error: "This token's decimal precision could not be confirmed on-chain, so it cannot be quoted safely.", reason: "unknown-decimals" });
  const raw = baseUnits(String(req.query.amount || ""), decimals);
  if (!raw || raw === "0") return res.status(400).json({ error: "Enter a valid amount", reason: "invalid" });

  let quote;
  try {
    const response = await fetchImpl(`${RELAY}/quote/v2`, {
      method: "POST", headers: relayHeaders(),
      body: JSON.stringify({
        user, recipient: user,
        originChainId: Number(chainIndex), originCurrency: token,
        destinationChainId: MONAD, destinationCurrency: AUSD,
        amount: raw, tradeType: "EXACT_INPUT", originGasOverhead: CALIBUR_OVERHEAD,
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
  const calls = saleCalls(quote, chainIndex, token, raw);
  if (!calls) return res.status(422).json({ error: "This route needs a transaction Desk does not sign.", reason: "unsupported-route" });
  let account;
  try {
    account = await accountState(fetchImpl, chainIndex, user);
  } catch {
    return res.status(502).json({ error: `${chainName(chainIndex)} could not be reached.`, reason: "unreachable" });
  }
  return res.status(200).json(summarizeSale(quote, calls, raw, decimals, symbol, account));
}

async function balance(fetchImpl, req, res) {
  const user = String(req.query.user || "");
  const chainIndex = String(req.query.chainIndex || "");
  const token = String(req.query.tokenAddress || "");
  if (!evmAddress(user) || !evmAddress(token) || !rpcEndpoint(chainIndex)) {
    return res.status(400).json({ error: "Valid parameters required", reason: "invalid" });
  }
  try {
    const decimals = await resolveDecimals(chainIndex, token, undefined, fetchImpl);
    const held = await rpc(fetchImpl, chainIndex, "eth_call", [{ to: token, data: "0x70a08231" + word(user) }, "latest"]);
    const raw = /^0x[0-9a-f]*$/i.test(String(held)) && held !== "0x" ? BigInt(held).toString() : "0";
    if (decimals === null) return res.status(422).json({ error: "This token's decimals could not be read.", reason: "unknown-decimals" });
    return res.status(200).json({ raw, decimals, readable: readableUnits(raw, decimals) });
  } catch {
    return res.status(502).json({ error: `${chainName(chainIndex)} could not be reached.`, reason: "unreachable" });
  }
}

const hex = (text, bytes) => new RegExp(`^0x[0-9a-fA-F]{${bytes * 2}}$`).test(String(text ?? ""));

async function execute(fetchImpl, req, res) {
  if (!process.env.RELAY_API_KEY) return res.status(503).json({ error: "Gasless selling is not configured yet.", reason: "unavailable" });
  const body = typeof req.body === "string" ? (() => { try { return JSON.parse(req.body); } catch { return null; } })() : req.body;
  const { chainId, user, requestId, calls, batchNonce, signature, authorization } = body ?? {};
  const callsOk = Array.isArray(calls) && calls.length === 2 && calls.every((call) => evmAddress(call?.to) && /^0x[0-9a-fA-F]{8,}$/.test(String(call?.data ?? "")) && String(call?.value ?? "0") === "0");
  const authorizationOk = authorization == null || (Number.isInteger(authorization.nonce) && authorization.nonce >= 0 && [0, 1].includes(authorization.yParity) && hex(authorization.r, 32) && hex(authorization.s, 32));
  if (!Number.isInteger(chainId) || chainId === MONAD || !evmAddress(user) || !hex(requestId, 32) || !callsOk || !/^\d{1,78}$/.test(String(batchNonce ?? "")) || !hex(signature, 65) || !authorizationOk) {
    return res.status(400).json({ error: "Valid execution parameters required", reason: "invalid" });
  }
  const data = executeCalldata({ calls, nonce: batchNonce, signature });
  const payload = {
    executionKind: "rawCalls",
    data: {
      chainId, to: user, data, value: "0",
      ...(authorization ? { authorizationList: [{ chainId, address: CALIBUR, nonce: authorization.nonce, yParity: authorization.yParity, r: authorization.r, s: authorization.s }] } : {}),
    },
    executionOptions: { subsidizeFees: false, ...(process.env.RELAY_REFERRER ? { referrer: process.env.RELAY_REFERRER } : {}) },
    requestId,
  };
  try {
    const response = await fetchImpl(`${RELAY}/execute`, { method: "POST", headers: relayHeaders(), body: JSON.stringify(payload) });
    const out = await response.json().catch(() => ({}));
    if (!response.ok) {
      // Relay's own words, for the ticket's failure line and the log; never the payload.
      const detail = String(out?.message ?? out?.error ?? "").slice(0, 200);
      console.error("relay execute refused", response.status, detail);
      return res.status(422).json({ error: "Relay could not take this sale right now.", reason: "refused", detail });
    }
    return res.status(200).json({ requestId: out.requestId ?? requestId });
  } catch {
    return res.status(502).json({ error: "Relay could not be reached.", reason: "unreachable" });
  }
}

export function summarize(quote, transaction, paid = null) {
  const details = quote.details ?? {};
  const fees = quote.fees ?? {};
  const usd = (value) => (value == null || Number.isNaN(Number(value)) ? null : String(value));
  const feeUsd = ["gas", "relayer"]
    .map((key) => Number(fees[key]?.amountUsd))
    .filter((value) => Number.isFinite(value))
    .reduce((sum, value) => sum + value, 0);
  return {
    requestId: quote.steps[0].requestId,
    pay: { amount: details.currencyIn?.amountFormatted, usd: usd(details.currencyIn?.amountUsd), symbol: paid ? "AUSD" : "MON", ...(paid ? { raw: paid } : {}) },
    receive: {
      amount: details.currencyOut?.amountFormatted,
      minimum: formatUnits(details.currencyOut?.minimumAmount, details.currencyOut?.currency?.decimals),
      usd: usd(details.currencyOut?.amountUsd),
      symbol: details.currencyOut?.currency?.symbol,
    },
    feeUsd: String(Math.round(feeUsd * 100) / 100),
    impactPercent: details.totalImpact?.percent ?? null,
    seconds: details.timeEstimate ?? null,
    transaction: transaction.transaction ?? transaction,
    ...(transaction.approval ? { approval: transaction.approval } : {}),
  };
}

function formatUnits(raw, decimals) {
  if (!/^\d+$/.test(String(raw ?? "")) || !Number.isInteger(decimals)) return null;
  const padded = String(raw).padStart(decimals + 1, "0");
  const whole = padded.slice(0, padded.length - decimals);
  const fraction = decimals ? padded.slice(-decimals).replace(/0+$/, "") : "";
  return fraction ? `${whole}.${fraction}` : whole;
}

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

const NONCES = "0x7ecebe00";
const readBody = (req) => (typeof req.body === "string" ? (() => { try { return JSON.parse(req.body); } catch { return null; } })() : req.body);

/// The any-chain send (docs/any-chain-send.md): `send` prepares what to sign, `send-submit`
/// queues the signed pair for copyd, `send-status` follows it to the far chain.
async function sendViews(fetchImpl, store, req, res) {
  const view = req.query.view;
  if (!store) return res.status(503).json({ error: "Sending is not configured.", reason: "unavailable" });
  if (view === "send-submit") {
    if (req.method !== "POST") return res.status(405).json({ error: "POST required" });
    const out = await submitSend({ store, body: readBody(req) });
    return res.status(out.status).json(out.body);
  }
  if (req.method !== "GET") return res.status(405).json({ error: "GET required" });
  if (view === "send-status") {
    const out = await sendStatus({ store, fetchImpl, id: String(req.query.id ?? "") });
    return res.status(out.status).json(out.body);
  }
  const nonces = async (user) => {
    const hex = await rpc(fetchImpl, String(MONAD), "eth_call", [{ to: SEND_AUSD, data: NONCES + word(user) }, "latest"]);
    if (!/^0x[0-9a-f]{64}$/i.test(String(hex))) throw new Error("nonce");
    return BigInt(hex).toString();
  };
  const out = await prepareSend({ store, fetchImpl, nonces, user: String(req.query.user ?? ""), to: String(req.query.to ?? ""), chainId: req.query.chainId, amount: String(req.query.amount ?? "") });
  return res.status(out.status).json(out.body);
}

export function createHandler(fetchImpl = fetch, store = redisStore()) {
  return async function handler(req, res) {
    res.setHeader("Cache-Control", "private, no-store");
    if (["send", "send-submit", "send-status"].includes(req.query?.view)) return sendViews(fetchImpl, store, req, res);
    if (req.query?.view === "execute") {
      if (req.method !== "POST") return res.status(405).json({ error: "POST required" });
      return execute(fetchImpl, req, res);
    }
    if (req.method !== "GET") return res.status(405).json({ error: "GET required" });
    if (wantsStatus(req)) return status(fetchImpl, req, res);
    if (req.query?.view === "sell") return sell(fetchImpl, req, res);
    if (req.query?.view === "balance") return balance(fetchImpl, req, res);
    const user = String(req.query.user || "");
    const chainIndex = String(req.query.chainIndex || "");
    const token = String(req.query.tokenAddress || "");
    // Paid in MON by default, the chain's own coin; `pay=AUSD` pays from the wallet's dollars.
    const paysAUSD = String(req.query.pay || "MON").toUpperCase() === "AUSD";
    const wei = baseUnits(String(req.query.amount || ""), paysAUSD ? 6 : 18);

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
          originChainId: MONAD, originCurrency: paysAUSD ? AUSD : NATIVE,
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

    const transaction = paysAUSD ? depositWithAUSD(quote, user, wei) : depositTransaction(quote, user, wei);
    if (!transaction || !matchesRoute(quote, chainIndex, token, paysAUSD ? AUSD : NATIVE)) {
      return res.status(422).json({ error: "This route needs a transaction Desk does not sign.", reason: "unsupported-route" });
    }
    return res.status(200).json(summarize(quote, transaction, paysAUSD ? wei : null));
  };
}

export default createHandler();
