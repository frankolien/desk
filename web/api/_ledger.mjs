/// A wallet's trade ledger on Monad, built from the chain and kept in Redis.
///
/// Every ERC-20 Transfer that touches the wallet is read through HyperSync and grouped
/// by transaction. A transaction the wallet sent in which tokens both left and arrived
/// is a swap; one it sent in which tokens only arrived is a buy paid in MON; one it sent
/// in which tokens only left, to something other than the token contract itself, is a
/// sell for MON. Tokens that arrived in someone else's transaction were transferred in,
/// and carry no cost basis — they are held but excluded from PnL, as Codex and Zerion do.
///
/// Each leg is priced at the minute it happened. Cost basis is the weighted average of
/// what was paid; a sell realises the difference against it. The ledger keeps a block
/// cursor so the next read only appends.

export const TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const ERC20_TRANSFER_SELECTOR = "0xa9059cbb";
/// Contracts a wallet moves money to and from without trading: Perpl's exchange and its
/// deposit router, Agora's faucet, Relay's depository. A deposit is not a sell.
export const CUSTODY = new Set([
  "0x34b6552d57a35a1d042ccae1951bd1c370112a6f",
  "0x1964c32f0be608e7d29302aff5e61268e72080cc",
  "0xd236c18d274e54faccc3dd9dda4b27965a73ee6c",
  "0x4cd00e387622c35bddb9b4c962c136462338bc31",
]);
export const NATIVE = "native";
export const LEDGER_VERSION = 1;
/// Money, not positions: paying with one of these is not selling it.
const QUOTE_SYMBOLS = new Set(["MON", "WMON", "USDC", "USDT", "AUSD", "USDE", "SUSDE", "SOL", "WSOL"]);
// EVM is case-insensitive; Solana base58 is not. Never merge distinct Solana wallets.
export const ledgerKey = (address) => `wl:${address.startsWith("0x") ? address.toLowerCase() : address}`;
export const TRACKED_KEY = "wl:tracked";
export const URGENT_KEY = "wl:urgent";
export const HEARTBEAT_KEY = "wl:heartbeat";
const KEEP_TRADES = 300;

const lower = (value) => String(value ?? "").toLowerCase();
const padTopic = (address) => `0x${lower(address).slice(2).padStart(64, "0")}`;
const topicAddress = (topic) => `0x${lower(topic).slice(-40)}`;

/// One transfer log to a plain record. ERC-721 shares the Transfer topic but carries the
/// token id as a fourth topic and no data, and is not a balance.
export function decodeTransfer(log) {
  const data = lower(log.data);
  if (!/^0x[0-9a-f]{64}$/.test(data) || log.topic3) return null;
  return {
    hash: lower(log.transaction_hash),
    block: Number(log.block_number),
    index: Number(log.log_index),
    token: lower(log.address),
    from: topicAddress(log.topic1),
    to: topicAddress(log.topic2),
    raw: BigInt(data),
  };
}

/// Transfers and transactions from one HyperSync page, grouped into the wallet's
/// movements per transaction: what came in, what went out, and who sent the transaction.
export function groupMovements(wallet, { logs = [], transactions = [], blocks = [] }) {
  const me = lower(wallet);
  const timestamps = new Map(blocks.map((block) => [Number(block.number), Number(block.timestamp)]));
  const sent = new Map(transactions.filter((tx) => lower(tx.from) === me).map((tx) => [lower(tx.hash), tx]));
  const byHash = new Map();
  for (const log of logs) {
    const transfer = decodeTransfer(log);
    if (!transfer || (transfer.from !== me && transfer.to !== me) || transfer.raw === 0n) continue;
    const entry = byHash.get(transfer.hash) ?? { hash: transfer.hash, block: transfer.block, in: new Map(), out: new Map() };
    const side = transfer.to === me ? entry.in : entry.out;
    side.set(transfer.token, (side.get(transfer.token) ?? 0n) + transfer.raw);
    if (transfer.from === me && transfer.to === me) entry.in.delete(transfer.token);
    byHash.set(transfer.hash, entry);
  }
  return [...byHash.values()].map((entry) => {
    const tx = sent.get(entry.hash);
    const input = lower(tx?.input);
    const value = tx?.value ? BigInt(tx.value) : 0n;
    let kind;
    if (!tx) kind = "received";
    else if (CUSTODY.has(lower(tx.to))) kind = entry.in.size ? "received" : "sent";
    else if (entry.in.size && entry.out.size) kind = "swap";
    else if (entry.in.size) kind = "buy";
    else if (entry.out.size === 1 && lower(tx.to) === [...entry.out.keys()][0] && input.startsWith(ERC20_TRANSFER_SELECTOR)) kind = "sent";
    else kind = "sell";
    return {
      hash: entry.hash,
      block: entry.block,
      time: (timestamps.get(entry.block) ?? 0) * 1000,
      kind,
      paidNative: value,
      in: [...entry.in].map(([token, raw]) => ({ token, raw })),
      out: [...entry.out].map(([token, raw]) => ({ token, raw })),
    };
  }).sort((a, b) => a.block - b.block);
}

export function emptyLedger(address) {
  return {
    version: LEDGER_VERSION, address: lower(address), cursor: 0, indexedAt: 0,
    positions: {}, trades: [], realized: 0, wins: 0, losses: 0,
  };
}

/// Whole and fractional parts separately, so 1e23 raw at 18 decimals is exactly 100000
/// rather than 99999.99999999999.
const units = (raw, decimals) => {
  const scale = 10n ** BigInt(decimals);
  return Number(raw / scale) + Number(raw % scale) / Number(scale);
};

/// Applies one movement to the ledger. `price(token, time)` answers in USD per whole
/// token, or null when unknown; `meta(token)` answers `{ symbol, decimals }`.
export async function applyMovement(ledger, movement, { price, meta }) {
  const legs = [];
  for (const { token, raw } of movement.in) legs.push({ token, raw, side: "in" });
  for (const { token, raw } of movement.out) legs.push({ token, raw, side: "out" });
  if (movement.paidNative > 0n && movement.kind === "buy") legs.push({ token: NATIVE, raw: movement.paidNative, side: "out", payment: true });

  for (const leg of legs) {
    const info = await meta(leg.token);
    if (!info) continue;
    const amount = units(leg.raw, info.decimals);
    if (!(amount > 0)) continue;
    const unit = movement.kind === "received" || movement.kind === "sent" ? null : await price(leg.token, movement.time);
    const position = ledger.positions[leg.token] ?? { symbol: info.symbol, decimals: info.decimals, holding: 0, basis: 0, unpriced: 0, bought: 0, sold: 0, realized: 0 };
    position.symbol = info.symbol;

    if (leg.side === "in") {
      if (unit == null) {
        position.unpriced += amount;
      } else {
        position.basis += amount * unit;
        position.holding += amount;
        position.bought += amount * unit;
      }
    } else {
      // Tokens without a cost basis leave first; they never touch PnL. The sale is
      // still a sale: it is recorded with its value and no gain.
      const fromUnpriced = Math.min(position.unpriced, amount);
      position.unpriced -= fromUnpriced;
      const priced = Math.min(position.holding, amount - fromUnpriced);
      let gain = null;
      if (priced > 0) {
        const averageCost = position.holding > 0 ? position.basis / position.holding : 0;
        position.basis -= averageCost * priced;
        position.holding -= priced;
        if (unit != null) {
          gain = priced * (unit - averageCost);
          position.realized += gain;
          position.sold += priced * unit;
          ledger.realized += gain;
          if (gain >= 0) ledger.wins += 1; else ledger.losses += 1;
        }
      }
      const payment = leg.payment || QUOTE_SYMBOLS.has(String(info.symbol).toUpperCase());
      if (unit != null && movement.kind !== "sent" && (priced > 0 || !payment)) {
        ledger.trades.push({ time: movement.time, hash: movement.hash, token: leg.token, symbol: info.symbol, side: "sell", amount, price: unit, value: amount * unit, gain });
      }
    }
    if (leg.side === "in" && unit != null && movement.kind !== "received") {
      ledger.trades.push({ time: movement.time, hash: movement.hash, token: leg.token, symbol: info.symbol, side: "buy", amount, price: unit, value: amount * unit, gain: null });
    }
    ledger.positions[leg.token] = position;
  }
  ledger.trades = ledger.trades.slice(-KEEP_TRADES);
  return ledger;
}

/// The figures a page shows, with unrealised PnL marked against today's prices.
export function summarize(ledger, currentPrice, { now = Date.now() } = {}) {
  const tokens = [];
  let unrealized = 0;
  let value = 0;
  for (const [token, position] of Object.entries(ledger.positions)) {
    const price = currentPrice(token);
    const held = position.holding + position.unpriced;
    const marked = price == null ? null : position.holding * price;
    const gain = marked == null ? null : marked - position.basis;
    if (gain != null) unrealized += gain;
    if (price != null) value += held * price;
    if (held <= 1e-12 && position.realized === 0) continue;
    tokens.push({
      token, symbol: position.symbol, holding: held, unpriced: position.unpriced,
      averageCost: position.holding > 0 ? position.basis / position.holding : null,
      price, value: price == null ? null : held * price,
      realized: position.realized, unrealized: gain,
    });
  }
  tokens.sort((a, b) => (b.value ?? 0) - (a.value ?? 0));
  const window = (days) => {
    const since = now - days * 86_400_000;
    const sells = ledger.trades.filter((trade) => trade.side === "sell" && trade.time >= since);
    const wins = sells.filter((trade) => trade.gain >= 0).length;
    return {
      realized: sells.reduce((sum, trade) => sum + trade.gain, 0),
      trades: ledger.trades.filter((trade) => trade.time >= since).length,
      winRate: sells.length ? wins / sells.length : null,
    };
  };
  const decided = ledger.wins + ledger.losses;
  return {
    realized: ledger.realized,
    unrealized,
    value,
    winRate: decided ? ledger.wins / decided : null,
    last7d: window(7),
    last30d: window(30),
    tokens,
    trades: [...ledger.trades].reverse().slice(0, 60),
  };
}

export async function fetchPage(hypersync, { wallet, from, to }) {
  const padded = padTopic(wallet);
  return hypersync.raw({
    from_block: from,
    to_block: to,
    logs: [{ topics: [[TRANSFER_TOPIC], [padded], []] }, { topics: [[TRANSFER_TOPIC], [], [padded]] }],
    transactions: [{ from: [lower(wallet)] }],
    field_selection: {
      log: ["block_number", "transaction_hash", "log_index", "address", "topic1", "topic2", "topic3", "data"],
      transaction: ["hash", "from", "to", "value", "input", "block_number"],
      block: ["number", "timestamp"],
    },
    max_num_logs: 5_000,
  });
}

/// Brings one wallet's ledger up to the chain tip, within a deadline. Returns the
/// ledger and whether it reached the tip.
export async function indexWallet(address, { store, hypersync, price, meta, backfillBlocks, finalityLag = 20, now = Date.now, deadline = Infinity }) {
  const key = ledgerKey(address);
  const stored = await store.get(key);
  let ledger = stored ? JSON.parse(stored) : null;
  if (!ledger || ledger.version !== LEDGER_VERSION) ledger = emptyLedger(address);
  const tip = (await hypersync.height()) - finalityLag;
  let cursor = ledger.cursor || Math.max(0, tip - backfillBlocks);
  const start = cursor;
  let pages = 0;
  let stopped = false;
  while (cursor < tip && !stopped) {
    const page = await fetchPage(hypersync, { wallet: address, from: cursor, to: tip });
    let block = -1;
    for (const movement of groupMovements(address, page)) {
      // Pricing is the slow part, so the deadline is checked between blocks; a block
      // is never left half-applied, and the cursor rests on the first block not done.
      if (movement.block !== block && now() >= deadline) { cursor = movement.block; stopped = true; break; }
      block = movement.block;
      await applyMovement(ledger, movement, { price, meta });
    }
    pages += 1;
    if (stopped) break;
    if (!(page.nextBlock > cursor)) break;
    cursor = page.nextBlock;
  }
  ledger.cursor = cursor;
  ledger.indexedAt = now();
  await store.set(key, JSON.stringify(ledger), { ex: 30 * 24 * 3600 });
  return { ledger, complete: cursor >= tip, from: start, to: cursor, behind: Math.max(0, tip - cursor), pages };
}
