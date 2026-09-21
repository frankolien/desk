import { CHAINS, SOLANA_WSOL, isSolanaAddress } from "./_chains.mjs";
import { NATIVE, applyMovement, emptyLedger, ledgerKey } from "./_ledger.mjs";

/// A Solana wallet's ledger, in the same shape as a Monad one, read from the public
/// RPC: each signature's transaction, the wallet's own token balances before and after,
/// and the lamports it paid or received. Trades are priced off OKX candles like Monad's.

export const SOLANA = "501";
export { isSolanaAddress };
const STABLES = new Set([
  "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", // USDC
  "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCdd7HKNVe6", // USDT
]);
/// Rent for a token account is 0.002 SOL; anything under this is rent or fees, not a payment.
const SOL_DUST = 5_000_000n;
const LEDGER_TTL_S = 30 * 24 * 3600;

export function solanaRpc(url = process.env.SOLANA_RPC || CHAINS[SOLANA].rpc, fetchImpl = fetch) {
  return async function rpc(method, params) {
    const response = await fetchImpl(url, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    });
    if (response.status === 429) throw new Error("solana 429");
    const body = await response.json();
    if (body.error) throw new Error(`solana ${body.error.code}: ${body.error.message}`);
    return body.result;
  };
}

/// One transaction as a movement of the wallet's own tokens. Stablecoin and SOL legs
/// only say which way money went; the asset leg is priced from candles, as on Monad.
export function solanaMovement(wallet, signature, tx) {
  const meta = tx?.meta;
  if (!meta || meta.err) return null;
  const keys = (tx.transaction?.message?.accountKeys ?? []).map((key) => (typeof key === "string" ? { pubkey: key, signer: false } : key));
  const index = keys.findIndex((key) => key.pubkey === wallet);
  let lamports = index >= 0 ? BigInt(meta.postBalances?.[index] ?? 0) - BigInt(meta.preBalances?.[index] ?? 0) : 0n;
  if (index === 0 || keys[index]?.signer) lamports += BigInt(meta.fee ?? 0);

  const deltas = new Map();
  const tally = (rows, sign) => {
    for (const row of rows ?? []) {
      if (row.owner !== wallet || !row.mint) continue;
      const entry = deltas.get(row.mint) ?? { raw: 0n, after: 0n, decimals: Number(row.uiTokenAmount?.decimals ?? 0) };
      const amount = BigInt(row.uiTokenAmount?.amount ?? "0");
      entry.raw += sign * amount;
      if (sign > 0n) entry.after += amount;
      deltas.set(row.mint, entry);
    }
  };
  tally(meta.preTokenBalances, -1n);
  tally(meta.postTokenBalances, 1n);
  const wrapped = deltas.get(SOLANA_WSOL);
  if (wrapped) { lamports += wrapped.raw; deltas.delete(SOLANA_WSOL); }

  let paid = lamports < -SOL_DUST;
  let received = lamports > SOL_DUST;
  const inn = [];
  const out = [];
  for (const [token, { raw, after, decimals }] of deltas) {
    if (raw === 0n) continue;
    if (STABLES.has(token)) { if (raw < 0n) paid = true; else received = true; continue; }
    if (raw > 0n) inn.push({ token, raw, after, decimals }); else out.push({ token, raw: -raw, after, decimals });
  }
  if (inn.length === 0 && out.length === 0) return null;
  let kind;
  if (inn.length && out.length) kind = "swap";
  else if (inn.length) kind = paid ? "buy" : "received";
  else kind = received ? "sell" : "sent";
  return {
    hash: signature, block: Number(tx.slot ?? 0), time: Number(tx.blockTime ?? 0) * 1000, kind,
    paidNative: kind === "buy" && lamports < -SOL_DUST ? -lamports : 0n, in: inn, out,
  };
}

/// The chain says what the wallet holds after each transaction; the ledger only knows
/// what it saw. Anything more is held without a basis, anything less left unseen.
export function reconcile(ledger, leg) {
  const position = ledger.positions[leg.token];
  if (!position) return;
  const scale = 10 ** leg.decimals;
  const actual = Number(leg.after / BigInt(scale)) + Number(leg.after % BigInt(scale)) / scale;
  const known = position.holding + position.unpriced;
  if (actual > known + 1e-9) {
    position.unpriced += actual - known;
  } else if (actual < known - 1e-9) {
    let gone = known - actual;
    const fromUnpriced = Math.min(position.unpriced, gone);
    position.unpriced -= fromUnpriced;
    gone -= fromUnpriced;
    if (gone > 0 && position.holding > 0) {
      position.basis -= position.basis * Math.min(1, gone / position.holding);
      position.holding = Math.max(0, position.holding - gone);
    }
  }
}

/// Symbol and decimals of a mint. Decimals come with every transaction, so the indexer
/// teaches them; the symbol is looked up through Desk's own search and kept a month.
export function solanaMetaReader({ store = null, fetchImpl = fetch, api = "" } = {}) {
  const memory = new Map([[NATIVE, { symbol: "SOL", decimals: 9 }]]);
  const learned = new Map();
  async function meta(token) {
    if (memory.has(token)) return memory.get(token);
    const key = `tk:${SOLANA}:${token}`;
    const cached = store ? await store.get(key).catch(() => null) : null;
    if (cached) {
      const value = JSON.parse(cached);
      memory.set(token, value);
      return value;
    }
    const decimals = learned.get(token);
    if (!Number.isInteger(decimals)) return null;
    let symbol = null;
    try {
      const response = await fetchImpl(`${api}/api/token-discovery?q=${encodeURIComponent(token)}`);
      const rows = response.ok ? (await response.json())?.tokens ?? [] : [];
      symbol = rows.find((row) => String(row.chainIndex) === SOLANA && row.contract === token)?.symbol ?? null;
    } catch { /* the address stands in for the name */ }
    const value = { symbol: symbol || `${token.slice(0, 4)}…${token.slice(-3)}`, decimals };
    memory.set(token, value);
    if (store && symbol) store.set(key, JSON.stringify(value), { ex: LEDGER_TTL_S }).catch(() => {});
    return value;
  }
  meta.learn = (token, decimals) => { if (!learned.has(token)) learned.set(token, decimals); };
  return meta;
}

/// Brings a wallet's ledger up to its newest signature. The cursor is the last
/// signature applied, so a round cut short by the deadline resumes where it stopped.
/// The first look takes only the newest page: a wallet's whole life is not the point.
export async function indexSolanaWallet(address, { store, rpc, price, meta, now = Date.now, deadline = Infinity, pageSize = 25, maxSignatures = 100 }) {
  if (!isSolanaAddress(address)) throw new Error("not a Solana address");
  const key = ledgerKey(address);
  const stored = await store.get(key);
  const ledger = stored ? JSON.parse(stored) : { ...emptyLedger(address), address, chainIndex: SOLANA, cursor: null };

  const signatures = [];
  let before = null;
  while (signatures.length < maxSignatures) {
    const page = await rpc("getSignaturesForAddress", [address, {
      limit: pageSize, ...(before ? { before } : {}), ...(ledger.cursor ? { until: ledger.cursor } : {}),
    }]);
    signatures.push(...(page ?? []));
    if (!ledger.cursor || !page || page.length < pageSize) break;
    before = page[page.length - 1].signature;
  }
  // Newest first from the RPC; the ledger wants them in the order they happened.
  const pending = signatures.filter((entry) => !entry.err).reverse();

  let done = 0;
  let complete = true;
  for (const entry of pending) {
    if (now() >= deadline) { complete = false; break; }
    const tx = await rpc("getTransaction", [entry.signature, { encoding: "jsonParsed", maxSupportedTransactionVersion: 0, commitment: "confirmed" }]);
    const movement = tx ? solanaMovement(address, entry.signature, tx) : null;
    if (movement) {
      for (const leg of [...movement.in, ...movement.out]) meta.learn?.(leg.token, leg.decimals);
      await applyMovement(ledger, movement, { price: (token, time) => price(token === NATIVE ? SOLANA_WSOL : token, time), meta });
      for (const leg of [...movement.in, ...movement.out]) reconcile(ledger, leg);
    }
    ledger.cursor = entry.signature;
    done += 1;
  }
  ledger.indexedAt = now();
  await store.set(key, JSON.stringify(ledger), { ex: LEDGER_TTL_S });
  return { ledger, complete, behind: pending.length - done, pages: 1 };
}
