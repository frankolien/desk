import { concatHex, encodeFunctionData, keccak256, recoverTypedDataAddress, stringToHex, toHex } from "viem";
import { isSolanaAddress } from "./_chains.mjs";

/// The any-chain send (docs/any-chain-send.md): a wallet's AUSD leaves Monad for any address
/// on any chain Agora or Relay reaches, with Desk paying Monad's gas. The wallet signs an AUSD
/// permit for DeskSend and a Send pinning the calls; copyd submits; Relay fills the far side.
export const MONAD = 143;
export const SOLANA = 792703809;
export const AUSD = "0x00000000efe302beaa2b3e6e1b18d08d69a9012a";
/// DeskSend on Monad: the deterministic CREATE2 address of contracts/src/DeskSend.sol, salt zero.
export const SEND_CONTRACT = "0x41fa5ca5b73fb6ea8e3ca219f8f2bc8ce35fa04e";
export const RELAY_DEPOSITORY = "0x4cd00e387622c35bddb9b4c962c136462338bc31";
export const RELAY_ROUTER = "0xccc88a9d1b4ed6b0eaba998850414b24f1c315be";
export const USDC_SOLANA = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
export const MIN_RAW = 1_000_000n;          // $1
export const MAX_RAW = 25_000_000_000n;     // $25,000 a send
export const DEADLINE_S = 180;
export const PREP_TTL_S = 240;
export const JOB_TTL_S = 7 * 86_400;
export const MAX_IMPACT_PERCENT = 1;

/// Where AUSD can go. On each chain the tokens it may arrive as, in order of preference:
/// Relay is asked for each and the one that delivers the most wins, so a thin AUSD pool (Base,
/// Arbitrum tonight) never costs the person anything. Solana takes USDC. Anything else is
/// refused rather than guessed.
const USDC = {
  1: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", 8453: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", 42161: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
  43114: "0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e", 137: "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359",
};
const evmChoices = (chainId) => [{ symbol: "AUSD", currency: AUSD }, { symbol: "USDC", currency: USDC[chainId] }];
export const DESTINATIONS = {
  [MONAD]: { name: "Monad", vm: "evm", choices: [{ symbol: "AUSD", currency: AUSD }] },
  1: { name: "Ethereum", vm: "evm", choices: evmChoices(1) },
  8453: { name: "Base", vm: "evm", choices: evmChoices(8453) },
  42161: { name: "Arbitrum", vm: "evm", choices: evmChoices(42161) },
  43114: { name: "Avalanche", vm: "evm", choices: evmChoices(43114) },
  137: { name: "Polygon", vm: "evm", choices: evmChoices(137) },
  [SOLANA]: { name: "Solana", vm: "svm", choices: [{ symbol: "USDC", currency: USDC_SOLANA }] },
};

export const K = {
  prep: (id) => `send:prep:${id}`,
  job: (id) => `send:job:${id}`,
  jobs: "send:jobs",
  recent: (user) => `send:recent:${user.toLowerCase()}`,
};

const evm = (value) => /^0x[a-fA-F0-9]{40}$/.test(String(value ?? ""));
const low = (value) => String(value).toLowerCase();
export const amountRaw = (text) => {
  const m = /^(\d{1,9})(?:\.(\d{1,6}))?$/.exec(String(text ?? "").trim());
  if (!m) return null;
  return BigInt(m[1]) * 1_000_000n + BigInt((m[2] ?? "").padEnd(6, "0"));
};
export const display = (raw) => { const n = BigInt(raw); return `${n / 1_000_000n}.${String(n % 1_000_000n).padStart(6, "0").slice(0, 2)}`; };

/// Who the money is for: an EVM address with a chain (Monad unless said), or a Solana address.
export function destinationOf({ to, chainId }) {
  const recipient = String(to ?? "").trim();
  const first = (known) => ({ symbol: known.choices[0].symbol, currency: known.choices[0].currency });
  if (isSolanaAddress(recipient) && !evm(recipient)) return { chainId: SOLANA, recipient, ...DESTINATIONS[SOLANA], ...first(DESTINATIONS[SOLANA]) };
  if (!evm(recipient)) return null;
  const chain = Number(chainId ?? MONAD);
  const known = DESTINATIONS[chain];
  if (!known || known.vm !== "evm") return null;
  return { chainId: chain, recipient: recipient.toLowerCase(), ...known, ...first(known) };
}

/// keccak256 over (to ‖ keccak256(data)) per call, as DeskSend.hashCalls does.
export const hashCalls = (calls) => keccak256(concatHex(calls.map((call) => concatHex([low(call.to), keccak256(call.data)]))));
export const destinationTag = (chainId, recipient) => keccak256(stringToHex(`${chainId}:${recipient}`));

export const SEND_TYPES = {
  Send: [
    { name: "from", type: "address" }, { name: "amount", type: "uint256" }, { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" }, { name: "callsHash", type: "bytes32" }, { name: "destination", type: "bytes32" },
  ],
};
export const PERMIT_TYPES = {
  Permit: [
    { name: "owner", type: "address" }, { name: "spender", type: "address" }, { name: "value", type: "uint256" },
    { name: "nonce", type: "uint256" }, { name: "deadline", type: "uint256" },
  ],
};
const DOMAIN_TYPE = [{ name: "name", type: "string" }, { name: "version", type: "string" }, { name: "chainId", type: "uint256" }, { name: "verifyingContract", type: "address" }];

export function sendTypedData({ contract, from, amount, nonce, deadline, callsHash, destination }) {
  return {
    types: { EIP712Domain: DOMAIN_TYPE, ...SEND_TYPES }, primaryType: "Send",
    domain: { name: "Desk Send", version: "1", chainId: String(MONAD), verifyingContract: contract },
    message: { from, amount: String(amount), nonce: String(nonce), deadline: String(deadline), callsHash, destination },
  };
}

export function permitTypedData({ owner, spender, value, nonce, deadline }) {
  return {
    types: { EIP712Domain: DOMAIN_TYPE, ...PERMIT_TYPES }, primaryType: "Permit",
    domain: { name: "AUSD", version: "1", chainId: String(MONAD), verifyingContract: AUSD },
    message: { owner, spender, value: String(value), nonce: String(nonce), deadline: String(deadline) },
  };
}

/// viem wants the numbers as bigints and no EIP712Domain entry in `types`.
const forViem = (typed) => ({
  domain: { ...typed.domain, chainId: BigInt(typed.domain.chainId) },
  types: Object.fromEntries(Object.entries(typed.types).filter(([name]) => name !== "EIP712Domain")),
  primaryType: typed.primaryType,
  message: Object.fromEntries(Object.entries(typed.message).map(([key, value]) => [key, /^\d+$/.test(String(value)) && !/^0x/.test(String(value)) ? BigInt(value) : value])),
});

const APPROVE = "0x095ea7b3", TRANSFER = "0xa9059cbb";
const word = (hex) => low(hex).replace(/^0x/, "").padStart(64, "0");

/// The same fence DeskSend.check applies, so a bad quote is refused here, not on chain, and the
/// recipient of a Monad send is what the person typed.
export function checkCalls(calls, { destination, amount }) {
  if (!Array.isArray(calls) || calls.length === 0 || calls.length > 3) return "wrong number of calls";
  for (const call of calls) {
    if (!evm(call?.to) || !/^0x([0-9a-fA-F]{2})*$/.test(String(call?.data ?? ""))) return "malformed call";
    if (call.value != null && String(call.value) !== "0") return "a call carries value";
    const to = low(call.to), data = low(call.data);
    if (to === RELAY_DEPOSITORY || to === RELAY_ROUTER) continue;
    if (to !== AUSD || data.length !== 2 + 136) return `call to ${to}`;
    const selector = data.slice(0, 10);
    if (selector === TRANSFER) {
      if (destination.chainId !== MONAD) return "a transfer on a cross-chain send";
      if (data.slice(10, 74) !== word(destination.recipient) || BigInt("0x" + data.slice(74)) !== BigInt(amount)) return "transfer not to the recipient";
      continue;
    }
    if (selector !== APPROVE) return "unknown AUSD call";
    const spender = "0x" + data.slice(34, 74);
    if (spender !== RELAY_DEPOSITORY && spender !== RELAY_ROUTER) return "approval to a stranger";
    if (BigInt("0x" + data.slice(74)) > BigInt(amount)) return "approval above the amount";
  }
  if (destination.chainId === MONAD) {
    return calls.length === 1 && low(calls[0].data).startsWith(TRANSFER) ? null : "a Monad send is one transfer";
  }
  return calls.some((call) => low(call.to) === RELAY_DEPOSITORY || low(call.to) === RELAY_ROUTER) ? null : "no Relay deposit";
}

export const transferCall = (recipient, amount) => ({ to: AUSD, value: "0", data: TRANSFER + word(recipient) + toHex(BigInt(amount), { size: 32 }).slice(2) });

const REASONS = {
  NO_SWAP_ROUTES_FOUND: "No route can deliver this amount there right now.",
  AMOUNT_TOO_LOW: "This amount is too small to send there.",
  INSUFFICIENT_LIQUIDITY: "There is not enough liquidity for this amount right now.",
};

/// A Relay route from DeskSend to the recipient, as the calls DeskSend will run.
export async function relayRoute({ fetchImpl, contract, destination, amount, refundTo, apiKey }) {
  const response = await fetchImpl("https://api.relay.link/quote", {
    method: "POST", headers: { "content-type": "application/json", ...(apiKey ? { "x-api-key": apiKey } : {}) },
    body: JSON.stringify({
      user: contract, recipient: destination.recipient, refundTo,
      originChainId: MONAD, destinationChainId: destination.chainId,
      originCurrency: AUSD, destinationCurrency: destination.currency,
      amount: String(amount), tradeType: "EXACT_INPUT",
    }),
  });
  const quote = await response.json().catch(() => ({}));
  if (!response.ok) throw Object.assign(new Error(REASONS[quote?.errorCode] ?? "A route is unavailable right now."), { reason: quote?.errorCode ?? "unavailable" });
  const steps = quote.steps ?? [];
  if (steps.some((step) => step.kind !== "transaction")) throw Object.assign(new Error("This route needs a step Desk does not sign."), { reason: "unsupported-route" });
  const calls = steps.flatMap((step) => step.items.map((item) => ({ to: item.data.to, value: String(item.data.value ?? "0"), data: item.data.data })));
  const requestId = steps.find((step) => step.requestId)?.requestId ?? null;
  const out = quote.details?.currencyOut;
  const impact = Number(quote.details?.totalImpact?.percent ?? 0);
  return {
    calls, requestId,
    out: { raw: String(out?.amount ?? "0"), formatted: out?.amountFormatted ?? null, symbol: out?.currency?.symbol ?? destination.symbol },
    feeUsd: Number(quote.fees?.relayer?.amountUsd ?? 0) + Number(quote.fees?.app?.amountUsd ?? 0),
    seconds: Number(quote.details?.timeEstimate ?? 0),
    impact,
  };
}

const randomId = () => toHex(crypto.getRandomValues(new Uint8Array(16)));

/// What the app shows and signs for one send. Stored for a few minutes under its id so the
/// submission can only run what was prepared.
export async function prepare({ store, fetchImpl, nonces, user, to, chainId, amount, contract = process.env.SEND_CONTRACT || SEND_CONTRACT, apiKey = process.env.RELAY_API_KEY, now = Date.now }) {
  if (!evm(user)) return { status: 400, body: { error: "A wallet address is required.", reason: "invalid" } };
  const destination = destinationOf({ to, chainId });
  if (!destination) return { status: 400, body: { error: "That address is not one Desk can send to. Monad, Ethereum, Base, Arbitrum, Avalanche, Polygon and Solana work.", reason: "unsupported-destination" } };
  if (destination.chainId === MONAD && destination.recipient === low(user)) return { status: 400, body: { error: "That is this wallet.", reason: "self" } };
  const raw = amountRaw(amount);
  if (raw == null || raw < MIN_RAW) return { status: 400, body: { error: "The smallest send is $1.", reason: "amount-too-low" } };
  if (raw > MAX_RAW) return { status: 400, body: { error: "The largest send is $25,000.", reason: "amount-too-high" } };

  let nonce;
  try { nonce = BigInt(await nonces(user)); } catch { return { status: 502, body: { error: "Monad could not be reached.", reason: "unreachable" } }; }
  let route = null, calls;
  if (destination.chainId === MONAD) {
    calls = [transferCall(destination.recipient, raw)];
  } else {
    // Every token the chain takes is quoted; the one that lands the most is the one sent.
    const tried = await Promise.all(destination.choices.map(async (choice) => {
      try { return { choice, route: await relayRoute({ fetchImpl, contract, destination: { ...destination, ...choice }, amount: raw, refundTo: user, apiKey }) }; }
      catch (error) { return { choice, error }; }
    }));
    const best = tried.filter((t) => t.route).sort((a, b) => Number(BigInt(b.route.out.raw) - BigInt(a.route.out.raw)))[0];
    if (!best) { const error = tried[0].error; return { status: 422, body: { error: error.message, reason: error.reason ?? "unavailable" } }; }
    route = best.route;
    destination.symbol = best.choice.symbol;
    destination.currency = best.choice.currency;
    if (route.impact < -MAX_IMPACT_PERCENT) return { status: 422, body: { error: `This route would lose ${Math.abs(route.impact).toFixed(1)}% on the way. Try a different amount or chain.`, reason: "impact" } };
    calls = route.calls;
  }
  const problem = checkCalls(calls, { destination, amount: raw });
  if (problem) return { status: 422, body: { error: "This route needs a call Desk does not sign.", reason: "unsupported-route", detail: problem } };

  const deadline = Math.floor(now() / 1000) + DEADLINE_S;
  const id = randomId();
  const intent = { from: low(user), amount: String(raw), nonce: String(nonce), deadline: String(deadline), callsHash: hashCalls(calls), destination: destinationTag(destination.chainId, destination.recipient) };
  const typed = { send: sendTypedData({ contract: low(contract), ...intent }), permit: permitTypedData({ owner: low(user), spender: low(contract), value: raw, nonce, deadline }) };
  const summary = {
    chainId: destination.chainId, chain: destination.name, recipient: destination.recipient, symbol: destination.symbol,
    amount: display(raw), arrives: route ? Number(route.out.formatted).toFixed(2) : display(raw), feeUsd: route ? Number(route.feeUsd.toFixed(4)) : 0, seconds: route ? route.seconds : 1,
  };
  const record = { id, user: low(user), contract: low(contract), calls, intent, destination: summary, requestId: route?.requestId ?? null, preparedAt: now() };
  await store.set(K.prep(id), JSON.stringify(record), { ex: PREP_TTL_S });
  return { status: 200, body: { id, contract: low(contract), expiresAt: deadline * 1000, calls, intent, typedData: typed, ...summary } };
}

const sig65 = (value) => /^0x[a-fA-F0-9]{130}$/.test(String(value ?? ""));

/// The signed pair, checked against what was prepared, then queued for copyd to submit.
export async function submit({ store, body, now = Date.now }) {
  const id = String(body?.id ?? "");
  if (!/^0x[a-f0-9]{32}$/.test(id) || !sig65(body?.signature) || !sig65(body?.permit)) return { status: 400, body: { error: "A prepared send and two signatures are required.", reason: "invalid" } };
  const stored = await store.get(K.prep(id));
  if (!stored) return { status: 410, body: { error: "This send has expired. Start it again.", reason: "expired" } };
  const prep = typeof stored === "string" ? JSON.parse(stored) : stored;
  if (Number(prep.intent.deadline) * 1000 < now() + 20_000) return { status: 410, body: { error: "This send has expired. Start it again.", reason: "expired" } };
  const sendTyped = sendTypedData({ contract: prep.contract, ...prep.intent });
  const permitTyped = permitTypedData({ owner: prep.user, spender: prep.contract, value: prep.intent.amount, nonce: prep.intent.nonce, deadline: prep.intent.deadline });
  let signer, permitter;
  try {
    signer = await recoverTypedDataAddress({ ...forViem(sendTyped), signature: body.signature });
    permitter = await recoverTypedDataAddress({ ...forViem(permitTyped), signature: body.permit });
  } catch { return { status: 400, body: { error: "The signatures could not be read.", reason: "bad-signature" } }; }
  if (low(signer) !== prep.user || low(permitter) !== prep.user) return { status: 401, body: { error: "Those signatures are not this wallet's.", reason: "bad-signature" } };
  const job = { ...prep, signature: body.signature, permit: body.permit, status: "queued", queuedAt: now() };
  const fresh = await store.set(K.job(id), JSON.stringify(job), { ex: JOB_TTL_S, nx: true });
  if (!fresh) return { status: 409, body: { error: "This send was already submitted.", reason: "duplicate" } };
  await store.del(K.prep(id)).catch(() => {});
  await store.rpush(K.jobs, id);
  await store.lpush(K.recent(prep.user), id).catch(() => {});
  await store.ltrim(K.recent(prep.user), 0, 19).catch(() => {});
  return { status: 200, body: { id, status: "queued" } };
}

/// Where a send stands: queued, sent (Monad hash), filled (Relay delivered), or failed.
export async function status({ store, fetchImpl, id, apiKey = process.env.RELAY_API_KEY }) {
  if (!/^0x[a-f0-9]{32}$/.test(String(id ?? ""))) return { status: 400, body: { error: "A send id is required.", reason: "invalid" } };
  const stored = await store.get(K.job(id));
  if (!stored) return { status: 404, body: { error: "No such send.", reason: "unknown" } };
  const job = typeof stored === "string" ? JSON.parse(stored) : stored;
  const out = { id, status: job.status, hash: job.hash ?? null, reason: job.reason ?? null, destination: job.destination, requestId: job.requestId ?? null, destinationTx: null };
  if (job.status === "sent" && job.requestId && fetchImpl) {
    try {
      const response = await fetchImpl(`https://api.relay.link/intents/status/v3?requestId=${job.requestId}`, { headers: apiKey ? { "x-api-key": apiKey } : {} });
      const relay = response.ok ? await response.json() : {};
      if (relay.status === "success") { out.status = "filled"; out.destinationTx = Array.isArray(relay.txHashes) ? relay.txHashes.at(-1) ?? null : null; }
      else if (relay.status === "failure" || relay.status === "refund") { out.status = "refunded"; }
    } catch {}
  }
  return { status: 200, body: out };
}

export const SEND_ABI = [{
  name: "send", type: "function", stateMutability: "nonpayable", outputs: [],
  inputs: [
    { name: "intent", type: "tuple", components: [
      { name: "from", type: "address" }, { name: "amount", type: "uint256" }, { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" }, { name: "callsHash", type: "bytes32" }, { name: "destination", type: "bytes32" },
    ] },
    { name: "signature", type: "bytes" }, { name: "v", type: "uint8" }, { name: "r", type: "bytes32" }, { name: "s", type: "bytes32" },
    { name: "calls", type: "tuple[]", components: [{ name: "to", type: "address" }, { name: "data", type: "bytes" }] },
  ],
}];

/// DeskSend.send calldata for a queued job.
export function sendCalldata(job) {
  const permit = job.permit;
  const r = permit.slice(0, 66), s = "0x" + permit.slice(66, 130);
  let v = Number.parseInt(permit.slice(130, 132), 16);
  if (v < 27) v += 27;
  return encodeFunctionData({
    abi: SEND_ABI, functionName: "send",
    args: [
      { from: job.intent.from, amount: BigInt(job.intent.amount), nonce: BigInt(job.intent.nonce), deadline: BigInt(job.intent.deadline), callsHash: job.intent.callsHash, destination: job.intent.destination },
      job.signature, v, r, s,
      job.calls.map((call) => ({ to: call.to, data: call.data })),
    ],
  });
}

/// copyd's side: pops queued sends, simulates each as Desk's key, submits, records the hash.
export function createSendWorker({ store, chain, contract = process.env.SEND_CONTRACT || SEND_CONTRACT, logger = console, now = Date.now }) {
  async function one(id) {
    const stored = await store.get(K.job(id));
    if (!stored) return;
    const job = typeof stored === "string" ? JSON.parse(stored) : stored;
    if (job.status !== "queued") return;
    const save = (patch) => store.set(K.job(id), JSON.stringify({ ...job, ...patch }), { ex: JOB_TTL_S });
    if (Number(job.intent.deadline) * 1000 < now() + 5_000) { await save({ status: "failed", reason: "expired" }); return; }
    if (chain.ausdBalance) {
      const held = await chain.ausdBalance(job.intent.from).catch(() => null);
      if (held != null && BigInt(held) < BigInt(job.intent.amount)) { await save({ status: "failed", reason: "not-enough-ausd" }); return; }
    }
    const data = sendCalldata(job);
    try {
      await chain.simulate({ to: contract, data });
    } catch (error) {
      await save({ status: "failed", reason: reasonOf(error) });
      logger.warn(`send ${id}: ${reasonOf(error)}`);
      return;
    }
    await save({ status: "sending" });
    let hash;
    try { hash = await chain.send({ to: contract, data }); }
    catch (error) { await save({ status: "failed", reason: reasonOf(error) }); return; }
    await save({ status: "sending", hash });
    const receipt = await chain.wait(hash);
    await save({ status: receipt.status === "success" ? "sent" : "failed", hash, reason: receipt.status === "success" ? null : "reverted", sentAt: now() });
    logger.log(`send ${id}: ${receipt.status} ${hash}`);
  }
  return {
    async tick() {
      let n = 0;
      for (;;) {
        const id = await store.lpop(K.jobs);
        if (!id) return n;
        n += 1;
        try { await one(String(id)); } catch (error) { logger.error(`send ${id}: ${error.message}`); }
      }
    },
  };
}

export function reasonOf(error) {
  const text = String(error?.shortMessage ?? error?.message ?? error ?? "");
  if (/Expired/.test(text)) return "expired";
  if (/WrongNonce/.test(text)) return "already-used";
  if (/insufficient|exceeds balance|transfer amount|e450d38c/i.test(text)) return "not-enough-ausd";
  if (/CallFailed/.test(text)) return "route-failed";
  if (/BadSignature|WrongCalls|NotAllowed/.test(text)) return "refused";
  return text.slice(0, 120) || "failed";
}
