import { CHAINS, EVM_NATIVE_ADDRESS, SOLANA_WSOL, rpcEndpoint } from "./_chains.mjs";
import { NATIVE } from "./_ledger.mjs";
import { getAddress } from "viem";

import { okxConfigured, okxGet, okxPost } from "./_okx.mjs";

const MAX_ROWS = 12;
const MONAD = "143";
export const MONAD_AUSD = "0x00000000efe302beaa2b3e6e1b18d08d69a9012a";
const COLLATERAL_DECIMALS = 6;
const SYMBOL_SELECTOR = "0x95d89b41";
const DECIMALS_SELECTOR = "0x313ce567";

const number = (value) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
};

export function describeWallet(rows, contract) {
  const wanted = String(contract ?? "").toLowerCase();
  const assets = [];
  for (const row of Array.isArray(rows) ? rows : []) {
    for (const asset of row?.tokenAssets ?? []) {
      if (String(asset?.isRiskToken) === "true" || asset?.isRiskToken === true) continue;
      const balance = number(asset?.balance);
      if (balance == null || balance <= 0) continue;
      const price = number(asset?.tokenPrice);
      assets.push({
        chainIndex: String(asset?.chainIndex ?? ""),
        chain: CHAINS[String(asset?.chainIndex ?? "")]?.name ?? null,
        contract: String(asset?.chainIndex) === "501"
          ? String(asset?.tokenContractAddress ?? asset?.tokenAddress ?? "")
          : String(asset?.tokenContractAddress ?? asset?.tokenAddress ?? "").toLowerCase(),
        symbol: String(asset?.symbol ?? "").trim() || "?",
        balance,
        value: price == null ? null : balance * price,
      });
    }
  }
  assets.sort((a, b) => (b.value ?? -1) - (a.value ?? -1));
  const held = assets.find((asset) => asset.contract.toLowerCase() === wanted) ?? null;
  const priced = assets.filter((asset) => asset.value != null);
  const byChain = new Map();
  for (const asset of priced) byChain.set(asset.chainIndex, (byChain.get(asset.chainIndex) ?? 0) + asset.value);
  return {
    portfolio: priced.length ? priced.reduce((sum, asset) => sum + asset.value, 0) : null,
    chains: [...byChain].map(([chainIndex, value]) => ({ chainIndex, chain: CHAINS[chainIndex]?.name ?? null, value }))
      .sort((a, b) => b.value - a.value),
    held: held ? { balance: held.balance, value: held.value } : null,
    holdings: assets.slice(0, MAX_ROWS),
  };
}

/// Perpl keeps a trader's collateral at the exchange contract under the wallet's account, so
/// the wallet's own AUSD balance is rarely where the dollars are. Both figures, in AUSD.
export function describeDesk(account, walletRaw) {
  const scaled = (raw) => Number(BigInt(raw)) / 10 ** COLLATERAL_DECIMALS;
  const open = account != null && BigInt(account.accountId ?? 0) !== 0n;
  return {
    account: open ? String(account.accountId) : null,
    collateral: open ? scaled(account.balanceCNS) : null,
    locked: open ? scaled(account.lockedBalanceCNS ?? 0) : null,
    walletAusd: walletRaw == null ? null : scaled(walletRaw),
  };
}

/// The chain settles Monad AUSD: the balance index's row gives way to the wallet's actual
/// balance, and what the desk holds joins the holdings as its own AUSD row. Totals move by
/// the difference, since the holdings list is capped and the totals cover every asset.
export function withDesk(wallet, desk) {
  if (!desk) return { ...wallet, desk: null };
  const isAusd = (asset) => asset.chainIndex === MONAD && asset.contract === MONAD_AUSD;
  const prior = wallet.holdings.find(isAusd) ?? null;
  const price = prior?.value != null && prior.balance > 0 ? prior.value / prior.balance : 1;
  const row = (balance, extra = {}) => ({ chainIndex: MONAD, chain: CHAINS[MONAD].name, contract: MONAD_AUSD, symbol: "AUSD", balance, value: balance * price, ...extra });
  let holdings = wallet.holdings;
  let delta = 0;
  if (desk.walletAusd != null) {
    holdings = holdings.filter((asset) => !isAusd(asset));
    delta -= prior?.value ?? 0;
    if (desk.walletAusd > 0) { holdings = [...holdings, row(desk.walletAusd)]; delta += desk.walletAusd * price; }
  }
  if (desk.collateral > 0) { holdings = [...holdings, row(desk.collateral, { desk: true })]; delta += desk.collateral * price; }
  holdings = [...holdings].sort((a, b) => (b.value ?? -1) - (a.value ?? -1)).slice(0, MAX_ROWS);
  const chains = wallet.chains.map((chain) => ({ ...chain }));
  const monad = chains.find((chain) => chain.chainIndex === MONAD);
  if (monad) monad.value += delta;
  else if (delta !== 0) chains.push({ chainIndex: MONAD, chain: CHAINS[MONAD].name, value: delta });
  chains.sort((a, b) => b.value - a.value);
  const portfolio = wallet.portfolio == null && delta === 0 ? null : (wallet.portfolio ?? 0) + delta;
  return { ...wallet, portfolio, chains, holdings, desk };
}

const TRUST_WALLET_CHAINS = {
  "1": "ethereum", "10": "optimism", "56": "smartchain", "137": "polygon", "8453": "base", "42161": "arbitrum",
  "43114": "avalanchec", "59144": "linea", "534352": "scroll", "5000": "mantle", "146": "sonic", "501": "solana",
};
const NATIVE_LOGOS = {
  "1": "https://assets.coingecko.com/coins/images/279/large/ethereum.png",
  "10": "https://assets.coingecko.com/coins/images/279/large/ethereum.png",
  "8453": "https://assets.coingecko.com/coins/images/279/large/ethereum.png",
  "42161": "https://assets.coingecko.com/coins/images/279/large/ethereum.png",
  "56": "https://assets.coingecko.com/coins/images/825/large/bnb-icon2_2x.png",
  "137": "https://assets.coingecko.com/coins/images/32440/large/polygon.png",
  "43114": "https://assets.coingecko.com/coins/images/12559/large/Avalanche_Circle_RedWhite_Trans.png",
  "143": "https://coin-images.coingecko.com/coins/images/38909/large/monad.png",
};

async function exists(url) {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 2_500);
    const response = await fetch(url, { method: "HEAD", signal: controller.signal });
    clearTimeout(timer);
    return response.ok;
  } catch {
    return false;
  }
}

export async function logosFor(items, { store = null, search = okxGet } = {}) {
  const logos = {};
  for (const item of items) {
    if (item.contract === "" && NATIVE_LOGOS[item.chainIndex]) logos[`${item.chainIndex}:`] = NATIVE_LOGOS[item.chainIndex];
  }
  const wanted = [...new Map(items
    .filter((item) => (/^0x[0-9a-f]{40}$/.test(item.contract) || (item.chainIndex === "501" && /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(item.contract))) && /^\d+$/.test(item.chainIndex))
    .map((item) => [`${item.chainIndex}:${item.contract}`, item])).values()].slice(0, 24);
  if (!wanted.length || !okxConfigured()) return logos;
  const keys = wanted.map((item) => `logo4:${item.chainIndex}:${item.contract}`);
  const cached = store ? await store.mget(keys).catch(() => keys.map(() => null)) : keys.map(() => null);
  await Promise.all(wanted.map(async (item, index) => {
    const id = `${item.chainIndex}:${item.contract}`;
    if (cached[index] != null) { if (cached[index]) logos[id] = cached[index]; return; }
    let url = "";
    const same = (candidate) => item.chainIndex === "501"
      ? String(candidate.tokenContractAddress ?? "") === item.contract
      : String(candidate.tokenContractAddress ?? "").toLowerCase() === item.contract.toLowerCase();
    try {
      const rows = await search("/api/v6/dex/market/token/search", { chains: item.chainIndex, search: item.contract, limit: "3" });
      // Search may rank an unrelated token first; a wrong logo is worse than a fallback.
      const row = (Array.isArray(rows) ? rows : []).find(same);
      url = String(row?.tokenLogoUrl ?? "");
    } catch {}
    if (!url && item.symbol) {
      try {
        const rows = await search("/api/v6/dex/market/token/search", { chains: item.chainIndex, search: item.symbol, limit: "10" });
        const row = (Array.isArray(rows) ? rows : []).find(same);
        url = String(row?.tokenLogoUrl ?? "");
      } catch {}
    }
    if (!url && TRUST_WALLET_CHAINS[item.chainIndex]) {
      try {
        const assetAddress = item.chainIndex === "501" ? item.contract : getAddress(item.contract);
        const candidate = `https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/${TRUST_WALLET_CHAINS[item.chainIndex]}/assets/${assetAddress}/logo.png`;
        if (await exists(candidate)) url = candidate;
      } catch {}
    }
    if (!url && item.chainIndex === "143") {
      try {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 3_000);
        const response = await fetch(`https://api.nad.fun/token/${item.contract}`, { signal: controller.signal });
        clearTimeout(timer);
        if (response.ok) url = String((await response.json())?.token_info?.image_uri ?? "");
      } catch {}
    }
    if (url) logos[id] = url;
    // Missing art is often a transient index/CDN failure, not a permanent fact.
    if (store) store.set(keys[index], url, { ex: url ? 30 * 24 * 3600 : 3600 }).catch(() => {});
  }));
  return logos;
}

export async function walletBalances(address, chains) {
  if (!okxConfigured()) return null;
  return okxGet("/api/v6/dex/balance/all-token-balances-by-address", {
    address, chains: chains.join(","), excludeRiskToken: "0",
  });
}

export async function currentPrices(chainIndex, contracts) {
  const map = new Map();
  if (!okxConfigured() || contracts.length === 0) return map;
  try {
    const native = chainIndex === "501" ? SOLANA_WSOL : EVM_NATIVE_ADDRESS;
    const keyed = (value) => (String(value).startsWith("0x") ? String(value).toLowerCase() : String(value));
    const rows = await okxPost("/api/v6/dex/market/price-info",
      contracts.map((contract) => ({ chainIndex, tokenContractAddress: contract === NATIVE ? native : contract })));
    for (const row of Array.isArray(rows) ? rows : []) {
      const contract = keyed(row.tokenContractAddress ?? "");
      const price = number(row.price);
      if (price != null) map.set(contract === native ? NATIVE : contract, price);
    }
  } catch {}
  return map;
}

export function priceReader({ store = null, chainIndex = MONAD, fetchCandles = okxGet } = {}) {
  const memory = new Map();
  return async function priceAt(token, time) {
    if (!(time > 0) || (!okxConfigured() && fetchCandles === okxGet)) return null;
    const contract = token === NATIVE ? EVM_NATIVE_ADDRESS : token;
    const hour = Math.floor(time / 3_600_000);
    const key = `px:${chainIndex}:${contract}:${hour}`;
    if (memory.has(key)) return memory.get(key);
    const cached = store ? await store.get(key).catch(() => null) : null;
    if (cached != null) {
      const value = cached === "" ? null : Number(cached);
      memory.set(key, value);
      return value;
    }
    let price = null;
    for (const bar of ["1m", "1H", "1D"]) {
      try {
        const rows = await fetchCandles("/api/v6/dex/market/historical-candles", {
          chainIndex, tokenContractAddress: contract, bar, limit: "1", after: String(time + span(bar)),
        });
        const row = Array.isArray(rows) ? rows[0] : null;
        const close = row ? number(row[4]) : null;
        if (close != null && close > 0) { price = close; break; }
      } catch {}
    }
    memory.set(key, price);
    if (store) store.set(key, price == null ? "" : String(price), { ex: 30 * 24 * 3600 }).catch(() => {});
    return price;
  };
}

function span(bar) {
  return bar === "1m" ? 60_000 : bar === "1H" ? 3_600_000 : 86_400_000;
}

function decodeString(hex) {
  const body = String(hex ?? "").slice(2);
  if (body.length < 128) {
    // Some old tokens return a bytes32 symbol rather than a string.
    return Buffer.from(body.slice(0, 64), "hex").toString("utf8").replace(/\0+$/, "");
  }
  const length = Number(BigInt(`0x${body.slice(64, 128)}`));
  return Buffer.from(body.slice(128, 128 + length * 2), "hex").toString("utf8");
}

export function metaReader({ store = null, chainIndex = MONAD, fetchImpl = fetch } = {}) {
  const memory = new Map([[NATIVE, { symbol: CHAINS[chainIndex]?.symbol ?? "MON", decimals: 18 }]]);
  const endpoint = rpcEndpoint(chainIndex);
  return async function meta(token) {
    if (memory.has(token)) return memory.get(token);
    const key = `tk:${chainIndex}:${token}`;
    const cached = store ? await store.get(key).catch(() => null) : null;
    if (cached) {
      const value = JSON.parse(cached);
      memory.set(token, value);
      return value;
    }
    let value = null;
    try {
      const response = await fetchImpl(endpoint, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify([
          { jsonrpc: "2.0", id: 0, method: "eth_call", params: [{ to: token, data: SYMBOL_SELECTOR }, "latest"] },
          { jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to: token, data: DECIMALS_SELECTOR }, "latest"] },
        ]),
      });
      const rows = (await response.json()).sort((a, b) => a.id - b.id);
      const decimals = rows[1]?.result ? Number(BigInt(rows[1].result)) : null;
      if (Number.isInteger(decimals) && decimals >= 0 && decimals <= 36) {
        const symbol = rows[0]?.result ? decodeString(rows[0].result).trim() : "";
        value = { symbol: symbol || `${token.slice(0, 6)}…`, decimals };
      }
    } catch {}
    memory.set(token, value);
    if (store && value) store.set(key, JSON.stringify(value), { ex: 30 * 24 * 3600 }).catch(() => {});
    return value;
  };
}
