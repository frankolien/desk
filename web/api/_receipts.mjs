import { privateKeyToAccount } from "viem/accounts";

import { CUSTODY, TRANSFER_TOPIC, decodeTransfer } from "./_ledger.mjs";
import { shortAddress } from "./_watch.mjs";

export const RX_KEY = "alerts:rx";
export const NETWORKS = ["mainnet", "testnet"];
export const HYPERSYNC_URLS = { mainnet: "https://143.hypersync.xyz", testnet: "https://10143.hypersync.xyz" };
export const AUSD = {
  mainnet: "0x00000000efe302beaa2b3e6e1b18d08d69a9012a",
  testnet: "0xa9012a055bd4e0edff8ce09f960291c09d5322dc",
};
const MIN_MON = 10n ** 16n;
const MIN_AUSD = 10_000n;
const CHUNK = 1_000;
const CURSOR_STALE_MS = 3_600_000;
const CURSOR_WRITE_MS = 10 * 60_000;
export const CURSOR_TTL_S = 2 * 3600;
const MAX_SINGLES = 2;
export const RECEIPT_TIMEOUT_MS = 8_000;

const lower = (value) => String(value ?? "").toLowerCase();
const padTopic = (address) => `0x${lower(address).slice(2).padStart(64, "0")}`;

export function faucetSender(key = process.env.FAUCET_PRIVATE_KEY) {
  if (!/^0x[a-fA-F0-9]{64}$/.test(key ?? "")) return null;
  try { return privateKeyToAccount(key).address.toLowerCase(); } catch { return null; }
}

export const skipList = (extra = []) => new Set([...CUSTODY, ...extra.filter(Boolean).map(lower)]);

export function parseMe(me) {
  if (me == null) return { me: null };
  if (typeof me !== "object" || typeof me.address !== "string" || !/^0x[a-fA-F0-9]{40}$/.test(me.address)
      || !Array.isArray(me.networks) || !me.networks.every((network) => NETWORKS.includes(network))) {
    return { error: "me must be a wallet address and its networks." };
  }
  const networks = NETWORKS.filter((network) => me.networks.includes(network));
  return { me: networks.length ? { address: me.address.toLowerCase(), networks } : null };
}

export function receiptQuery(owners, network, from) {
  const chunks = [];
  for (let index = 0; index < owners.length; index += CHUNK) chunks.push(owners.slice(index, index + CHUNK));
  return {
    from_block: from,
    logs: chunks.map((chunk) => ({ address: [AUSD[network]], topics: [[TRANSFER_TOPIC], [], chunk.map(padTopic)] })),
    transactions: chunks.map((chunk) => ({ to: chunk })),
    field_selection: {
      log: ["block_number", "transaction_hash", "log_index", "address", "topic1", "topic2", "topic3", "data"],
      transaction: ["block_number", "hash", "from", "to", "value", "status"],
    },
  };
}

function units(raw, decimals, places) {
  const step = 10n ** BigInt(decimals - places);
  const kept = raw / step;
  const scale = 10n ** BigInt(places);
  return { whole: kept / scale, fraction: String(kept % scale).padStart(places, "0") };
}

export function ausdAmount(raw) {
  const { whole, fraction } = units(raw, 6, 2);
  return `${whole}.${fraction}`;
}

export function monAmount(raw) {
  const { whole, fraction } = units(raw, 18, 4);
  const trimmed = fraction.replace(/0+$/, "");
  return trimmed ? `${whole}.${trimmed}` : `${whole}`;
}

const grouped = (amount) => amount.replace(/^\d+/, (whole) => whole.replace(/\B(?=(\d{3})+(?!\d))/g, ","));

export function extractReceipts({ network, page, owners, skip }) {
  const mine = owners instanceof Set ? owners : new Set(owners);
  const transactions = page.transactions ?? [];
  const byHash = new Map(transactions.map((tx) => [lower(tx.hash), tx]));
  const out = [];
  const seen = new Set();
  for (const tx of transactions) {
    const hash = lower(tx.hash);
    const to = lower(tx.to);
    const from = lower(tx.from);
    if (seen.has(hash) || !mine.has(to) || from === to || skip.has(from)) continue;
    if (tx.status != null && Number(tx.status) !== 1) continue;
    let value;
    try { value = BigInt(tx.value ?? 0); } catch { continue; }
    if (value < MIN_MON) continue;
    seen.add(hash);
    out.push({ network, token: "MON", owner: to, raw: value, amount: monAmount(value), from, hash, index: null, block: Number(tx.block_number) || 0 });
  }
  const sums = new Map();
  for (const log of page.logs ?? []) {
    if (lower(log.address) !== AUSD[network]) continue;
    const transfer = decodeTransfer(log);
    if (!transfer || !mine.has(transfer.to)) continue;
    const sender = lower(byHash.get(transfer.hash)?.from);
    if (!sender || sender === transfer.to || transfer.from === transfer.to || skip.has(sender) || skip.has(transfer.from)) continue;
    const key = `${transfer.hash}:${transfer.to}`;
    const entry = sums.get(key);
    if (entry) entry.raw += transfer.raw;
    else sums.set(key, { network, token: "AUSD", owner: transfer.to, raw: transfer.raw, from: transfer.from, hash: transfer.hash, index: transfer.index, block: transfer.block || 0 });
  }
  for (const entry of sums.values()) if (entry.raw >= MIN_AUSD) out.push({ ...entry, amount: ausdAmount(entry.raw) });
  return out.sort((a, b) => a.block - b.block || (a.index ?? -1) - (b.index ?? -1));
}

const receiptAps = (title, body) => ({ alert: { title, body }, sound: "default", "thread-id": "receipt", category: "desk.receipt" });

export function receiptPayload(receipt) {
  const { network, token, amount, from, hash } = receipt;
  return {
    aps: receiptAps(`You received ${grouped(amount)} ${token}`, `From ${shortAddress(from)} on Monad ${network}.`),
    desk: { type: "receipt", network, token, amount, from, hash },
  };
}

export function summaryPayload(network, receipts) {
  const tokens = ["MON", "AUSD"].filter((token) => receipts.some((receipt) => receipt.token === token));
  return {
    aps: receiptAps(`You received ${receipts.length} deposits`, `${tokens.join(" and ")} on Monad ${network}.`),
    desk: { type: "receipt", network, summary: true },
  };
}

const single = (holder, receipt) => ({
  ...holder, payload: receiptPayload(receipt), collapseId: `rx-${receipt.hash.slice(2, 18)}-${receipt.index ?? "n"}`,
});

export function receiptDeliveries(receipts, holders) {
  const bySubscription = new Map();
  for (const receipt of receipts) {
    for (const holder of holders.get(receipt.owner) ?? []) {
      if (!holder.record.me?.networks?.includes(receipt.network)) continue;
      const entry = bySubscription.get(holder.id) ?? { holder, receipts: [] };
      entry.receipts.push(receipt);
      bySubscription.set(holder.id, entry);
    }
  }
  const deliveries = [];
  for (const { holder, receipts: found } of bySubscription.values()) {
    if (found.length <= MAX_SINGLES) {
      for (const receipt of found) deliveries.push(single(holder, receipt));
      continue;
    }
    for (const network of NETWORKS) {
      const here = found.filter((receipt) => receipt.network === network);
      if (here.length === 1) deliveries.push(single(holder, here[0]));
      else if (here.length > 1) {
        deliveries.push({ ...holder, payload: summaryPayload(network, here), collapseId: `rx-${here[0].hash.slice(2, 18)}-s` });
      }
    }
  }
  return deliveries;
}

function bounded(work, signal) {
  return Promise.race([work, new Promise((_, reject) => {
    signal.addEventListener("abort", () => reject(new Error("timed out")), { once: true });
  })]);
}

function readCursor(raw) {
  try { return JSON.parse(raw ?? "null") ?? {}; } catch { return {}; }
}

/// One HyperSync query per network with subscribers; a missing or stale cursor restarts at the tip and sends nothing.
/// The caller saves `next` when `due` (a quiet cursor every ten minutes), together with the scan's other writes.
export async function receiptScan({ sources = {}, skip, subscribers, stored, now = Date.now(), timeoutMs = RECEIPT_TIMEOUT_MS }) {
  const holders = new Map();
  const wanted = Object.fromEntries(NETWORKS.map((network) => [network, new Set()]));
  for (const { id, record } of subscribers) {
    if (!record.me?.address) continue;
    holders.set(record.me.address, [...(holders.get(record.me.address) ?? []), { id, record }]);
    for (const network of record.me.networks ?? []) wanted[network]?.add(record.me.address);
  }
  const cursor = readCursor(stored);
  const next = { ...cursor };
  const found = [];
  const errors = [];
  let due = false;
  await Promise.all(NETWORKS.map(async (network) => {
    const source = sources[network];
    if (!wanted[network].size || !source) return;
    const signal = AbortSignal.timeout(timeoutMs);
    try {
      const last = cursor[network];
      if (!Number.isFinite(last?.block) || !(now - last.at < CURSOR_STALE_MS)) {
        const height = await bounded(source.height({ signal }), signal);
        if (!Number.isFinite(height)) throw new Error("no height");
        next[network] = { block: height, at: now };
        due = true;
        return;
      }
      const page = await bounded(source.raw(receiptQuery([...wanted[network]], network, last.block), { signal }), signal);
      if (!(page.nextBlock >= last.block)) throw new Error("no next_block");
      const here = extractReceipts({ network, page, owners: wanted[network], skip });
      found.push(...here);
      next[network] = { block: page.nextBlock, at: now };
      if (here.length || now - last.at >= CURSOR_WRITE_MS) due = true;
    } catch (error) {
      errors.push(`receipts ${network}: ${signal.aborted ? "timed out" : error?.message ?? error}`);
    }
  }));
  return { deliveries: receiptDeliveries(found, holders), events: found.length, errors, next, due };
}
