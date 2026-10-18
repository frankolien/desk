
export const TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const ERC20_TRANSFER_SELECTOR = "0xa9059cbb";
export const CUSTODY = new Set([
  "0x34b6552d57a35a1d042ccae1951bd1c370112a6f",
  "0x1964c32f0be608e7d29302aff5e61268e72080cc",
  "0xd236c18d274e54faccc3dd9dda4b27965a73ee6c",
  "0x4cd00e387622c35bddb9b4c962c136462338bc31",
]);
/// Perpl's contracts: money sent there is a deposit, money back is a withdrawal.
export const PERPL = new Set(["0x34b6552d57a35a1d042ccae1951bd1c370112a6f", "0x1964c32f0be608e7d29302aff5e61268e72080cc"]);
export const NATIVE = "native";
export const LEDGER_VERSION = 2;
export const STABLE_SYMBOLS = new Set(["USDC", "USDT", "AUSD", "USDE", "SUSDE"]);
export const QUOTE_SYMBOLS = new Set([...STABLE_SYMBOLS, "MON", "WMON", "SOL", "WSOL"]);
const isStable = (symbol) => STABLE_SYMBOLS.has(String(symbol ?? "").toUpperCase());
const isQuote = (symbol) => QUOTE_SYMBOLS.has(String(symbol ?? "").toUpperCase());
// EVM is case-insensitive; Solana base58 is not. Never merge distinct Solana wallets.
export const ledgerKey = (address) => `wl:${address.startsWith("0x") ? address.toLowerCase() : address}`;
export const TRACKED_KEY = "wl:tracked";
export const URGENT_KEY = "wl:urgent";
export const WATCHED_KEY = "wl:watched";
export const HEARTBEAT_KEY = "wl:heartbeat";
const KEEP_TRADES = 300;
const KEEP_MOVES = 80;

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

export function groupMovements(wallet, { logs = [], transactions = [], blocks = [] }) {
  const me = lower(wallet);
  const timestamps = new Map(blocks.map((block) => [Number(block.number), Number(block.timestamp)]));
  const sent = new Map(transactions.filter((tx) => lower(tx.from) === me).map((tx) => [lower(tx.hash), tx]));
  const byHash = new Map();
  for (const log of logs) {
    const transfer = decodeTransfer(log);
    if (!transfer || (transfer.from !== me && transfer.to !== me) || transfer.raw === 0n) continue;
    const entry = byHash.get(transfer.hash) ?? { hash: transfer.hash, block: transfer.block, in: new Map(), out: new Map(), peers: new Set() };
    const side = transfer.to === me ? entry.in : entry.out;
    side.set(transfer.token, (side.get(transfer.token) ?? 0n) + transfer.raw);
    entry.peers.add(transfer.to === me ? transfer.from : transfer.to);
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
      to: tx ? lower(tx.to) : null,
      counterparty: entry.peers.size === 1 ? [...entry.peers][0] : null,
      paidNative: value,
      in: [...entry.in].map(([token, raw]) => ({ token, raw })),
      out: [...entry.out].map(([token, raw]) => ({ token, raw })),
    };
  }).sort((a, b) => a.block - b.block);
}

export function emptyLedger(address) {
  return {
    version: LEDGER_VERSION, address: lower(address), cursor: 0, indexedAt: 0,
    positions: {}, trades: [], moves: [], realized: 0, wins: 0, losses: 0,
  };
}

/// Whole and fractional parts separately, so 1e23 raw at 18 decimals is exactly 100000
/// rather than 99999.99999999999.
const units = (raw, decimals) => {
  const scale = 10n ** BigInt(decimals);
  return Number(raw / scale) + Number(raw % scale) / Number(scale);
};

/// A movement into the ledger. Trades are priced by a candle at that hour, or, when no candle
/// covers the token, from what was paid or received on the other side of the swap. Money
/// moving without a trade (deposits, withdrawals, sends, receipts) goes to `moves`, and never
/// into cost basis.
export async function applyMovement(ledger, movement, { price, meta }) {
  ledger.moves ??= [];
  const trading = movement.kind !== "received" && movement.kind !== "sent";
  const legs = [];
  const add = async (token, raw, side, payment = false) => {
    const info = await meta(token);
    if (!info) return;
    const amount = units(raw, info.decimals);
    if (amount > 0) legs.push({ token, side, payment, amount, symbol: info.symbol, decimals: info.decimals, unit: undefined });
  };
  for (const { token, raw } of movement.in) await add(token, raw, "in");
  for (const { token, raw } of movement.out) await add(token, raw, "out");
  if (movement.paidNative > 0n && movement.kind === "buy") await add(NATIVE, movement.paidNative, "out", true);

  if (!trading) {
    await recordMove(ledger, movement, legs, price);
    return ledger;
  }

  const assets = { in: legs.filter((leg) => leg.side === "in" && !isQuote(leg.symbol)), out: legs.filter((leg) => leg.side === "out" && !isQuote(leg.symbol)) };
  const quoteOnly = assets.in.length === 0 && assets.out.length === 0;
  const quote = { in: 0, out: 0 };
  const stable = { in: 0, out: 0 };
  for (const leg of legs) {
    if (!isQuote(leg.symbol)) continue;
    leg.unit = isStable(leg.symbol) ? 1 : await price(leg.token, movement.time);
    if (leg.unit != null) quote[leg.side] += leg.amount * leg.unit;
    if (isStable(leg.symbol)) stable[leg.side] += leg.amount;
  }
  for (const leg of legs) {
    const other = leg.side === "in" ? "out" : "in";
    if (leg.unit === undefined) {
      leg.unit = await price(leg.token, movement.time);
      // No candle for this token at that hour: what was paid or received for it says what it was worth.
      if (leg.unit == null && assets[leg.side].length === 1 && assets[other].length === 0 && quote[other] > 0) leg.unit = quote[other] / leg.amount;
    } else if (leg.unit == null && quoteOnly && stable[other] > 0 && legs.filter((l) => l.side === leg.side).length === 1) {
      // MON bought with AUSD when no MON candle came back: the AUSD paid says what it cost.
      leg.unit = stable[other] / leg.amount;
      quote[leg.side] += leg.amount * leg.unit;
    }
  }

  for (const leg of legs) {
    const { unit, amount } = leg;
    const position = ledger.positions[leg.token] ?? { symbol: leg.symbol, decimals: leg.decimals, holding: 0, basis: 0, unpriced: 0, bought: 0, sold: 0, realized: 0 };
    position.symbol = leg.symbol;
    // Stables are money; MON and SOL are money too, unless money was all that changed hands.
    const asset = !leg.payment && (!isQuote(leg.symbol) || (quoteOnly && !isStable(leg.symbol)));
    let gain = null;
    if (leg.side === "in") {
      if (unit == null) {
        position.unpriced += amount;
      } else {
        position.basis += amount * unit;
        position.holding += amount;
        position.bought += amount * unit;
      }
    } else {
      const fromUnpriced = Math.min(position.unpriced, amount);
      position.unpriced -= fromUnpriced;
      const priced = Math.min(position.holding, amount - fromUnpriced);
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
    }
    if (asset && unit != null) {
      ledger.trades.push({ time: movement.time, hash: movement.hash, token: leg.token, symbol: leg.symbol, side: leg.side === "in" ? "buy" : "sell",
        amount, price: unit, value: amount * unit, gain });
    }
    ledger.positions[leg.token] = position;
  }
  ledger.trades = ledger.trades.slice(-KEEP_TRADES);
  return ledger;
}

/// Money that moved without a trade. Deposits to and withdrawals from Perpl always count.
/// Other transfers count when they can be valued: stables at par, money tokens and tokens
/// the wallet already trades by candle. Airdrop spam from strangers is unpriced and skipped.
async function recordMove(ledger, movement, legs, price) {
  const perpl = PERPL.has(movement.to) || PERPL.has(movement.counterparty);
  for (const leg of legs) {
    const position = ledger.positions[leg.token];
    const known = isQuote(leg.symbol) || (position && position.holding > 0);
    if (leg.side === "in") {
      ledger.positions[leg.token] = position ?? { symbol: leg.symbol, decimals: leg.decimals, holding: 0, basis: 0, unpriced: 0, bought: 0, sold: 0, realized: 0 };
      ledger.positions[leg.token].unpriced += leg.amount;
    } else if (position) {
      const fromUnpriced = Math.min(position.unpriced, leg.amount);
      position.unpriced -= fromUnpriced;
      const priced = Math.min(position.holding, leg.amount - fromUnpriced);
      if (priced > 0) {
        position.basis -= (position.basis / position.holding) * priced;
        position.holding -= priced;
      }
    }
    let unit = null;
    if (isStable(leg.symbol)) unit = 1;
    else if (known) unit = await price(leg.token, movement.time);
    const value = unit == null ? null : leg.amount * unit;
    if (!perpl && (value == null || value < 1)) continue;
    const kind = perpl ? (leg.side === "out" ? "deposit" : "withdraw") : (leg.side === "out" ? "sent" : "received");
    ledger.moves.push({ time: movement.time, hash: movement.hash, kind, token: leg.token, symbol: leg.symbol, amount: leg.amount, value,
      counterparty: movement.counterparty ?? movement.to ?? null });
  }
  ledger.moves = ledger.moves.slice(-KEEP_MOVES);
}

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

export async function indexWallet(address, { store, hypersync, price, meta, backfillBlocks, finalityLag = 20, now = Date.now, deadline = Infinity, quietMs = 0 }) {
  const key = ledgerKey(address);
  const stored = await store.get(key);
  let ledger = stored ? JSON.parse(stored) : null;
  if (!ledger || ledger.version !== LEDGER_VERSION) ledger = emptyLedger(address);
  const writtenAt = stored ? ledger.indexedAt : 0;
  const tip = (await hypersync.height()) - finalityLag;
  let cursor = ledger.cursor || Math.max(0, tip - backfillBlocks);
  const start = cursor;
  let pages = 0;
  let applied = 0;
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
      applied += 1;
    }
    pages += 1;
    if (stopped) break;
    if (!(page.nextBlock > cursor)) break;
    cursor = page.nextBlock;
  }
  const quiet = applied === 0 && !stopped && writtenAt > 0 && now() - writtenAt < quietMs;
  ledger.cursor = cursor;
  ledger.indexedAt = now();
  if (!quiet) await store.set(key, JSON.stringify(ledger), { ex: 30 * 24 * 3600 });
  return { ledger, complete: cursor >= tip, from: start, to: cursor, behind: Math.max(0, tip - cursor), pages, written: !quiet };
}
