/// Perpl's open markets as decimal numbers a page can print, and exchange candles for
/// each market's asset. Perpl publishes no candle history, so the chart is the asset's
/// own tape on OKX; the mark shown beside it is Perpl's.

import { createPublicClient, http } from "viem";

import { EXCHANGE_VIEWS } from "./_perpl-abi.mjs";

const CONTEXT_URL = "https://app.perpl.xyz/api/v1/pub/context";
const EXCHANGE = "0x34B6552d57a35a1D042CcAe1951BD1C370112a6F";
const CANDLE_URL = "https://www.okx.com/api/v5/market/candles";
const INSTRUMENTS = {
  BTC: "BTC-USDT", ETH: "ETH-USDT", SOL: "SOL-USDT", PUMP: "PUMP-USDT",
  HYPE: "HYPE-USDT", ZEC: "ZEC-USDT", MON: "MON-USDT", LIT: "LIT-USDT",
};
export const BARS = new Set(["1m", "5m", "15m", "1H", "4H", "1D"]);
const COLLATERAL_DECIMALS = 6;

const scaled = (raw, decimals) => Number(raw ?? 0) / 10 ** decimals;

export function describeMarket(market) {
  const { config, state, funding } = market;
  const pd = config.price_decimals;
  const mark = scaled(state?.mrk, pd);
  const prev = scaled(state?.prv, pd);
  const openInterestUnits = scaled(state?.oi, config.size_decimals);
  return {
    id: market.id,
    name: market.name || market.symbol || market.size_units,
    mark,
    prev,
    change: prev > 0 ? (mark - prev) / prev : null,
    volume24h: scaled(state?.dva, COLLATERAL_DECIMALS),
    openInterest: openInterestUnits * mark,
    tvl: scaled(state?.tvl, COLLATERAL_DECIMALS),
    // The contract calls the rate `fundingRatePct100k`; a fraction per interval here.
    fundingRate: funding ? Number(funding.rate ?? 0) / 1e6 : null,
    fundingIntervalSec: market.funding_interval_sec ?? null,
    maxLeverage: Math.floor(Number(config.initial_margin ?? 100) / 100),
    priceDecimals: pd,
    sizeDecimals: config.size_decimals,
    makerFee: Number(config.maker_fee ?? 0),
    takerFee: Number(config.taker_fee ?? 0),
    maintenanceMargin: Number(config.maintenance_margin ?? 0),
    isOpen: Boolean(config.is_open),
  };
}

/// Where the chain is and how fast it moves, from the two block stamps every market
/// carries; entry blocks become times with these.
export function describeHead(context) {
  const gas = context?.chain?.gas?.at;
  const stamps = (context?.markets ?? []).flatMap((m) => [m.config?.at, m.state?.at]).filter((at) => at?.b != null && at?.t != null);
  const earliest = stamps.reduce((min, at) => (min == null || at.b < min.b ? at : min), null);
  const latest = stamps.reduce((max, at) => (max == null || at.b > max.b ? at : max), null);
  const blockMs = earliest && latest && latest.b > earliest.b ? (latest.t - earliest.t) / (latest.b - earliest.b) : 400;
  const head = gas ?? latest;
  return head ? { block: Number(head.b), time: Number(head.t), blockMs: Math.round(blockMs) } : null;
}

export function describeMarkets(context) {
  const rows = (context?.markets ?? []).filter((market) => market?.config?.is_open).map(describeMarket);
  const collateral = (context?.tokens ?? []).find((token) => token.symbol === "AUSD")?.symbol ?? "AUSD";
  return { collateral, head: describeHead(context), markets: rows };
}

export function createMarkets({ fetchImpl = fetch, now = Date.now, readMark = null } = {}) {
  let contextCache = { at: 0, value: null };
  const candleCache = new Map();
  let client = null;
  // One page of one position is the cheapest view that carries the mark.
  const markOf = readMark ?? (async (id) => {
    client ??= createPublicClient({ transport: http(process.env.MONAD_MAINNET_RPC || "https://rpc.monad.xyz", { timeout: 8_000, batch: true }) });
    const [, , mark, valid] = await client.readContract({ address: EXCHANGE, abi: EXCHANGE_VIEWS, functionName: "getPositionsV2", args: [BigInt(id), 0n, 1n] });
    return valid ? Number(mark) : null;
  });

  async function context() {
    if (contextCache.value && now() - contextCache.at < 10_000) return contextCache.value;
    const response = await fetchImpl(CONTEXT_URL);
    if (!response.ok) throw new Error(`Perpl HTTP ${response.status}`);
    const value = describeMarkets(await response.json());
    contextCache = { at: now(), value };
    return value;
  }

  async function candles(name, bar) {
    const instrument = INSTRUMENTS[String(name).toUpperCase()];
    if (!instrument || !BARS.has(bar)) return null;
    const key = `${instrument}:${bar}`;
    const cached = candleCache.get(key);
    if (cached && now() - cached.at < 60_000) return cached.value;
    const query = new URLSearchParams({ instId: instrument, bar, limit: "300" });
    const response = await fetchImpl(`${CANDLE_URL}?${query}`);
    if (!response.ok) throw new Error(`OKX HTTP ${response.status}`);
    const body = await response.json();
    if (body.code !== "0" || !Array.isArray(body.data)) throw new Error(body.msg || `OKX code ${body.code}`);
    const value = body.data
      .map(([time, open, high, low, close, volume]) => ({
        time: Math.floor(Number(time) / 1000), open: Number(open), high: Number(high), low: Number(low), close: Number(close), volume: Number(volume),
      }))
      .sort((a, b) => a.time - b.time);
    candleCache.set(key, { at: now(), value });
    return value;
  }

  /// Every market's mark as the contract holds it this instant, decimal.
  async function marks() {
    const { markets: rows } = await context();
    const read = await Promise.all(rows.map((m) => markOf(m.id).catch(() => null)));
    const out = {};
    rows.forEach((m, i) => { if (read[i] != null) out[m.name] = read[i] / 10 ** m.priceDecimals; });
    return { at: now(), marks: out };
  }

  return { context, candles, marks, hasInstrument: (name) => Boolean(INSTRUMENTS[String(name).toUpperCase()]) };
}
