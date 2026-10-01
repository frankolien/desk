/// Perpl's open markets as decimal numbers a page can print, and Perpl's own candles for
/// each of them. The venue serves candle history for every listed market, so a market it
/// adds (VVV, NEAR) has a chart the day it lists, with no second exchange to map it to.

import { createPublicClient, http } from "viem";

import { EXCHANGE_VIEWS } from "./_perpl-abi.mjs";

const CONTEXT_URL = "https://app.perpl.xyz/api/v1/pub/context";
const EXCHANGE = "0x34B6552d57a35a1D042CcAe1951BD1C370112a6F";
const CANDLE_URL = "https://app.perpl.xyz/api/v1/market-data";
/// The bars the public API offers, as the resolutions Perpl serves.
export const BAR_SECONDS = { "1m": 60, "5m": 300, "15m": 900, "1H": 3_600, "4H": 14_400, "1D": 86_400 };
export const BARS = new Set(Object.keys(BAR_SECONDS));
const CANDLE_COUNT = 300;
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

  async function find(name) {
    const { markets } = await context();
    return markets.find((m) => String(m.name).toUpperCase() === String(name).toUpperCase()) ?? null;
  }

  /// Ascending candles in decimal prices and AUSD volume, or null for an unknown market or bar.
  async function candles(name, bar) {
    if (!BARS.has(bar)) return null;
    const market = await find(name);
    if (!market) return null;
    const key = `${market.id}:${bar}`;
    const cached = candleCache.get(key);
    if (cached && now() - cached.at < 60_000) return cached.value;
    const seconds = BAR_SECONDS[bar];
    const to = now();
    const from = to - seconds * CANDLE_COUNT * 1000;
    const response = await fetchImpl(`${CANDLE_URL}/${market.id}/candles/${seconds}/${from}-${to}`);
    if (!response.ok) throw new Error(`Perpl HTTP ${response.status}`);
    const body = await response.json();
    if (!Array.isArray(body?.d)) throw new Error("Perpl answered without candles");
    const price = (raw) => Number(raw) / 10 ** market.priceDecimals;
    const value = body.d
      .map((c) => ({
        time: Math.floor(Number(c.t) / 1000), open: price(c.o), high: price(c.h), low: price(c.l), close: price(c.c),
        volume: Number(c.v) / 10 ** COLLATERAL_DECIMALS,
      }))
      .sort((a, b) => a.time - b.time)
      // The range is inclusive at both ends, so Perpl can answer one more than asked.
      .slice(-CANDLE_COUNT);
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

  return { context, candles, marks, hasInstrument: async (name) => Boolean(await find(name).catch(() => null)) };
}
