/// Perpl's open markets as decimal numbers a page can print, and exchange candles for
/// each market's asset. Perpl publishes no candle history, so the chart is the asset's
/// own tape on OKX; the mark shown beside it is Perpl's.

const CONTEXT_URL = "https://app.perpl.xyz/api/v1/pub/context";
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

export function describeMarkets(context) {
  const rows = (context?.markets ?? []).filter((market) => market?.config?.is_open).map(describeMarket);
  const collateral = (context?.tokens ?? []).find((token) => token.symbol === "AUSD")?.symbol ?? "AUSD";
  return { collateral, markets: rows };
}

export function createMarkets({ fetchImpl = fetch, now = Date.now } = {}) {
  let contextCache = { at: 0, value: null };
  const candleCache = new Map();

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

  return { context, candles, hasInstrument: (name) => Boolean(INSTRUMENTS[String(name).toUpperCase()]) };
}
