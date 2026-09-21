import { createPublicClient, erc20Abi, http } from "viem";

import { rpcEndpoint } from "./_chains.mjs";
import { hypersyncClient } from "./_history.mjs";
import { TRANSFER_TOPIC, decodeTransfer } from "./_ledger.mjs";
import { nadfunToken } from "./_risk.mjs";
import { redisStore } from "./_store.mjs";
import { metaReader } from "./_wallet.mjs";

/// Who got into a Monad token first, from the token's own Transfer log: snipers in the
/// first seconds, bundles of wallets filled in one block by one sender, and the creator
/// with everyone the creator handed tokens to.
///
///   GET /api/token-details?view=early&chainIndex=143&address=0x…

const MONAD = "143";
const ZERO = "0x0000000000000000000000000000000000000000";
export const SNIPER_BLOCKS = 200;
export const BUNDLE_BLOCKS = 600;
export const SCAN_BLOCKS = 2000;
export const MAX_LOGS = 3000;
export const MAX_SNIPERS = 20;
export const MAX_BALANCES = 60;
const MAX_CODE_CHECKS = 120;
const BUNDLE_MIN_WALLETS = 3;
const MAX_PAGES = 12;
const CACHE_SECONDS = 3600;

export const earlyKey = (address) => `early:${MONAD}:${address.toLowerCase()}`;

const lower = (value) => String(value ?? "").toLowerCase();

const units = (raw, decimals) => {
  const scale = 10n ** BigInt(decimals);
  return Number(raw / scale) + Number(raw % scale) / Number(scale);
};

function empty(chainIndex, address, status) {
  return {
    chainIndex, address, status, createdAt: null, creator: null, launchBlock: null, blocksScanned: 0,
    snipers: [], bundles: [], insiders: [], totals: { snipers: 0, bundles: 0, insiders: 0 },
  };
}

/// Transfer logs of one token, in chain order, to the lists a page shows. Shares are
/// fractions of the supply minted in the window, or of the largest balance seen when
/// nothing was minted in it. Addresses in `contracts` (pools, curves, lockers) are never
/// listed as recipients; the creator is listed whatever it is.
export function classifyEarly({ logs = [], blocks = [], creator = null, decimals = 18, contracts = new Set(), limit = MAX_SNIPERS } = {}) {
  const timestamps = new Map(blocks.map((block) => [Number(block.number), Number(block.timestamp)]));
  const time = (block) => (timestamps.get(block) ?? 0) * 1000;
  const transfers = logs.map(decodeTransfer).filter((t) => t && t.raw > 0n)
    .sort((a, b) => a.block - b.block || a.index - b.index);
  const none = { launchBlock: null, creator: lower(creator) || null, supply: 0, snipers: [], bundles: [], insiders: [], totals: { snipers: 0, bundles: 0, insiders: 0 } };
  if (!transfers.length) return none;

  const launchBlock = transfers[0].block;
  const dev = lower(creator) || transfers[0].to;

  let minted = 0n;
  let peak = 0n;
  const balances = new Map();
  for (const t of transfers) {
    if (t.from === ZERO) minted += t.raw;
    else balances.set(t.from, (balances.get(t.from) ?? 0n) - t.raw);
    const next = (balances.get(t.to) ?? 0n) + t.raw;
    balances.set(t.to, next);
    if (next > peak) peak = next;
  }
  const supplyRaw = minted > 0n ? minted : peak;
  const supply = units(supplyRaw, decimals);
  const share = (raw) => (supply > 0 ? units(raw, decimals) / supply : 0);

  const snipers = new Map();
  for (const t of transfers) {
    if (t.block > launchBlock + SNIPER_BLOCKS) break;
    if (t.from === ZERO || t.from === dev || t.to === dev || t.to === ZERO || contracts.has(t.to)) continue;
    const seen = snipers.get(t.to);
    if (seen) { seen.raw += t.raw; continue; }
    if (snipers.size >= limit) continue;
    snipers.set(t.to, { address: t.to, block: t.block, time: time(t.block), raw: t.raw });
  }

  const bundles = new Map();
  for (const t of transfers) {
    if (t.block > launchBlock + BUNDLE_BLOCKS) break;
    if (t.from === ZERO || t.to === ZERO || t.to === t.from || contracts.has(t.to)) continue;
    const key = `${t.block}:${t.from}`;
    const group = bundles.get(key) ?? { block: t.block, wallets: new Map() };
    group.wallets.set(t.to, (group.wallets.get(t.to) ?? 0n) + t.raw);
    bundles.set(key, group);
  }
  const bundleRows = [];
  const byBlock = new Map();
  for (const group of bundles.values()) {
    if (group.wallets.size < BUNDLE_MIN_WALLETS) continue;
    const row = byBlock.get(group.block) ?? { block: group.block, time: time(group.block), wallets: new Map() };
    for (const [wallet, raw] of group.wallets) row.wallets.set(wallet, (row.wallets.get(wallet) ?? 0n) + raw);
    byBlock.set(group.block, row);
  }
  for (const row of [...byBlock.values()].sort((a, b) => a.block - b.block)) {
    const raw = [...row.wallets.values()].reduce((sum, value) => sum + value, 0n);
    bundleRows.push({ block: row.block, time: row.time, wallets: [...row.wallets.keys()], amount: units(raw, decimals), share: share(raw) });
  }

  let devRaw = 0n;
  const fromDev = new Map();
  for (const t of transfers) {
    if (t.to === dev) devRaw += t.raw;
    if (t.from === dev && t.to !== dev && t.to !== ZERO && !contracts.has(t.to)) fromDev.set(t.to, (fromDev.get(t.to) ?? 0n) + t.raw);
  }
  const insiders = [
    { address: dev, via: "creator", amount: units(devRaw, decimals), share: share(devRaw) },
    ...[...fromDev].sort((a, b) => (b[1] > a[1] ? 1 : b[1] < a[1] ? -1 : 0))
      .map(([address, raw]) => ({ address, via: "from-creator", amount: units(raw, decimals), share: share(raw) })),
  ];

  const sniperRows = [...snipers.values()].map(({ raw, ...row }) => ({ ...row, amount: units(raw, decimals), share: share(raw) }));
  const sum = (rows) => rows.reduce((total, row) => total + row.share, 0);
  return {
    launchBlock, creator: dev, supply,
    snipers: sniperRows, bundles: bundleRows, insiders,
    totals: { snipers: sum(sniperRows), bundles: sum(bundleRows), insiders: sum(insiders) },
  };
}

/// Every Transfer of the token from its first block through the scan window, page by
/// page. HyperSync indexes by address, so starting at block 0 costs nothing extra.
export async function fetchEarlyLogs(hypersync, token) {
  const address = lower(token);
  const tip = await hypersync.height();
  const logs = [];
  const blocks = [];
  let from = 0;
  let to = null;
  let launchBlock = null;
  for (let pages = 0; pages < MAX_PAGES && from < tip; pages += 1) {
    const page = await hypersync.raw({
      from_block: from,
      ...(to == null ? {} : { to_block: to }),
      logs: [{ address: [address], topics: [[TRANSFER_TOPIC]] }],
      field_selection: {
        log: ["block_number", "transaction_hash", "log_index", "address", "topic1", "topic2", "topic3", "data"],
        block: ["number", "timestamp"],
      },
      max_num_logs: MAX_LOGS,
    });
    logs.push(...page.logs);
    blocks.push(...page.blocks);
    if (launchBlock == null && page.logs.length) {
      launchBlock = Math.min(...page.logs.map((log) => Number(log.block_number)));
      to = launchBlock + SCAN_BLOCKS + 1;
    }
    if (!(page.nextBlock > from)) break;
    from = page.nextBlock;
    if (to != null && from >= to) break;
    if (logs.length >= MAX_LOGS) { from = Math.max(...logs.map((log) => Number(log.block_number))) + 1; break; }
  }
  const covered = launchBlock == null ? 0 : Math.min(from, launchBlock + SCAN_BLOCKS + 1) - launchBlock - 1;
  return { logs, blocks, launchBlock, blocksScanned: Math.max(0, covered) };
}

/// Balances and bytecode from the RPC, one batched request per call.
export function chainReader({ url = rpcEndpoint(MONAD) } = {}) {
  const client = createPublicClient({ transport: http(url, { batch: true }) });
  return {
    async balances(token, addresses) {
      const rows = await Promise.all(addresses.map((address) =>
        client.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [address] }).catch(() => null)));
      return new Map(addresses.map((address, index) => [address, rows[index]]));
    },
    async contracts(addresses) {
      const codes = await Promise.all(addresses.map((address) => client.getCode({ address }).catch(() => null)));
      return new Set(addresses.filter((_, index) => codes[index] && codes[index] !== "0x"));
    },
  };
}

const candidates = (found) => [...new Set([
  ...found.snipers.map((row) => row.address),
  ...found.insiders.filter((row) => row.via !== "creator").map((row) => row.address),
  ...found.bundles.flatMap((row) => row.wallets),
])];

export async function handleEarly(req, res, {
  hypersync = hypersyncClient(), store = redisStore(), fetchImpl = fetch, chain = null, meta = null,
} = {}) {
  const chainIndex = String(req.query.chainIndex ?? "");
  const address = String(req.query.address ?? "");
  if (!/^0x[a-fA-F0-9]{40}$/.test(address)) return res.status(400).json({ error: "A token address is required." });
  const token = address.toLowerCase();
  if (chainIndex !== MONAD) {
    res.setHeader("Cache-Control", "no-store");
    return res.status(200).json(empty(chainIndex, token, "unsupported"));
  }
  const key = earlyKey(token);
  const cached = store ? await store.get(key).catch(() => null) : null;
  if (cached) {
    res.setHeader("Cache-Control", "public, s-maxage=300, stale-while-revalidate=3600");
    return res.status(200).json(JSON.parse(cached));
  }
  if (!hypersync) {
    res.setHeader("Cache-Control", "no-store");
    return res.status(200).json(empty(chainIndex, token, "unavailable"));
  }

  let page;
  let launch;
  let decimals = 18;
  try {
    const readMeta = meta ?? metaReader({ store, chainIndex, fetchImpl });
    const [scan, known, info] = await Promise.all([
      fetchEarlyLogs(hypersync, token),
      nadfunToken(token, fetchImpl),
      readMeta(token).catch(() => null),
    ]);
    page = scan;
    launch = known;
    if (Number.isInteger(info?.decimals)) decimals = info.decimals;
  } catch (error) {
    res.setHeader("Cache-Control", "no-store");
    return res.status(200).json(empty(chainIndex, token, /429/.test(error.message) ? "indexing" : "unavailable"));
  }

  const rpc = chain ?? chainReader();
  const input = { logs: page.logs, blocks: page.blocks, creator: launch?.creator ?? null, decimals };
  // A first pass over-collects so that whatever the code check removes has replacements.
  const draft = classifyEarly({ ...input, limit: MAX_SNIPERS * 2 });
  const contracts = await rpc.contracts(candidates(draft).slice(0, MAX_CODE_CHECKS)).catch(() => new Set());
  const found = classifyEarly({ ...input, contracts });
  const timestamps = new Map(page.blocks.map((block) => [Number(block.number), Number(block.timestamp)]));
  const wallets = [...new Set([found.creator, ...found.snipers.map((row) => row.address), ...found.insiders.map((row) => row.address)])]
    .filter(Boolean).slice(0, MAX_BALANCES);
  let held = new Map();
  if (wallets.length && found.supply > 0) held = await rpc.balances(token, wallets).catch(() => new Map());
  const holdsNow = (wallet) => {
    const raw = held.get(wallet);
    return typeof raw === "bigint" && found.supply > 0 ? units(raw, decimals) / found.supply : null;
  };

  const answer = {
    chainIndex, address: token, status: "ready",
    createdAt: launch?.createdAt ?? (found.launchBlock == null ? null : timestamps.get(found.launchBlock) ?? null),
    creator: found.creator,
    launchBlock: found.launchBlock,
    blocksScanned: page.blocksScanned,
    snipers: found.snipers.map((row) => ({ ...row, holdsNow: holdsNow(row.address) })),
    bundles: found.bundles,
    insiders: found.insiders.map((row) => ({ ...row, holdsNow: holdsNow(row.address) })),
    totals: found.totals,
  };
  if (store && found.launchBlock != null) await store.set(key, JSON.stringify(answer), { ex: CACHE_SECONDS }).catch(() => {});
  res.setHeader("Cache-Control", "public, s-maxage=300, stale-while-revalidate=3600");
  return res.status(200).json(answer);
}
