/// The copy planner, ported line for line from DeskKit/Sources/DeskFlow/CopyTrading.swift so the
/// server copies exactly as the app does. Integers are BigInt wherever Swift uses Int128, and every
/// rounding direction is kept: sizes floor, fees ceil, triggers never fire early. The tests in
/// web/test/copy-planner.test.mjs are CopyTradingTests.swift's, with the same numbers and the
/// same context fixture.

export const DEFAULT_RULES = Object.freeze({
  mode: "shadow", direction: "follow", sizing: "fixed",
  marginPerTrade: 10, maxLeverage: 5, stopLossPercent: 25, takeProfitPercent: null,
  closeWithTrader: true, maxChaseBps: 100,
});

export const DEFAULT_GUARDS = Object.freeze({ maxOpenCopies: 3, dailyLossLimit: 50, maxMarketExposure: 250 });

/// Rules saved before modes existed were live, followed and fixed.
export function decodeRules(json) {
  for (const key of ["marginPerTrade", "maxLeverage", "closeWithTrader", "maxChaseBps"]) {
    if (json?.[key] === undefined) throw new Error(`rules missing ${key}`);
  }
  return {
    mode: json.mode ?? "live", direction: json.direction ?? "follow", sizing: json.sizing ?? "fixed",
    marginPerTrade: json.marginPerTrade, maxLeverage: json.maxLeverage,
    stopLossPercent: json.stopLossPercent ?? null, takeProfitPercent: json.takeProfitPercent ?? null,
    closeWithTrader: json.closeWithTrader, maxChaseBps: json.maxChaseBps,
  };
}

export function decodeGuards(json) {
  if (json?.maxOpenCopies === undefined || json?.dailyLossLimit === undefined) throw new Error("guards incomplete");
  return { maxOpenCopies: json.maxOpenCopies, dailyLossLimit: json.dailyLossLimit, maxMarketExposure: json.maxMarketExposure ?? 250 };
}

// ---------- integer helpers, the DeskMoney rules ----------

export const MONEY_DECIMALS = 6;
const MAX_RAW = 1_000_000_000_000_000_000n; // Money.maxRaw and Scaled.maxRaw
const INT64_MAX = 9_223_372_036_854_775_807n;
const MAX_EXPONENT = 18;

const pow10 = (n) => (n < 0 || n > 38 ? null : 10n ** BigInt(n));
const abs = (n) => (n < 0n ? -n : n);

/// DeskMoney `divide`: truncation, then the remainder decides by rounding mode.
export function divide(dividend, divisor, rounding) {
  if (divisor <= 0n) throw new Error("divisor must be positive");
  const quotient = dividend / divisor;
  if (dividend % divisor === 0n) return quotient;
  switch (rounding) {
    case "towardZero": return quotient;
    case "awayFromZero": return dividend > 0n ? quotient + 1n : quotient - 1n;
    case "floor": return dividend > 0n ? quotient : quotient - 1n;
    case "ceiling": return dividend > 0n ? quotient + 1n : quotient;
    default: throw new Error(`rounding ${rounding}`);
  }
}

/// Price or Size: a raw integer at `decimals`, refused outside the venue's range.
export function scaled(raw, decimals) {
  const value = BigInt(raw);
  if (decimals > MAX_EXPONENT || abs(value) > MAX_RAW) return null;
  return { raw: value, decimals };
}

const money = (raw) => (abs(raw) > MAX_RAW ? null : raw);

export function notional(price, size, rounding) {
  const product = price.raw * size.raw;
  const exponent = price.decimals + size.decimals - MONEY_DECIMALS;
  let value = product;
  if (exponent > 0) value = divide(product, pow10(exponent), rounding);
  else if (exponent < 0) value = product * pow10(-exponent);
  return value > INT64_MAX || value < -INT64_MAX ? null : money(value);
}

export function fee(raw, rateMicros) {
  if (rateMicros < 0n || rateMicros > 1_000_000n) return null;
  return money(divide(abs(raw) * rateMicros, 1_000_000n, "awayFromZero"));
}

export function liquidationDistanceMicros(leverageHundredths, maintenanceMarginFraction) {
  if (leverageHundredths <= 0 || maintenanceMarginFraction <= 0) return null;
  const distance = Math.trunc(100_000_000 / leverageHundredths) - Math.trunc(100_000_000 / maintenanceMarginFraction);
  return distance > 0 ? distance : null;
}

export function initialMargin(notionalRaw, leverageHundredths) {
  if (leverageHundredths <= 0) return null;
  return money(divide(abs(notionalRaw) * 100n, BigInt(leverageHundredths), "awayFromZero"));
}

/// `P_liq = E(1 + mm) - C/S` for a long, `E(1 - mm) + C/S` for a short, rounded against the trader.
export function liquidationPrice(entry, size, collateralRaw, maintenanceMarginFraction, side) {
  if (maintenanceMarginFraction <= 0 || size.raw <= 0n) return null;
  const marginTerm = divide(entry.raw * 100n, BigInt(maintenanceMarginFraction), "ceiling");
  const exponent = size.decimals + entry.decimals - MONEY_DECIMALS;
  let numerator = collateralRaw;
  if (exponent > 0) numerator *= pow10(exponent);
  else if (exponent < 0) numerator = divide(numerator, pow10(-exponent), "towardZero");
  const collateralTerm = divide(numerator, size.raw, "towardZero");
  const raw = side === "long" ? entry.raw + marginTerm - collateralTerm : entry.raw - marginTerm + collateralTerm;
  return raw > 0n && raw <= INT64_MAX ? scaled(raw, entry.decimals) : null;
}

/// OrderQuote.quote: throws where the Swift throws, so the planner can turn it into tooSmall.
export function quote({ side, size, price, leverageHundredths, feeMicros, initialMarginFraction, maintenanceMarginFraction }) {
  if (size.raw <= 0n) throw new Error("sizeMustBePositive");
  if (price.raw <= 0n) throw new Error("priceMustBePositive");
  if (leverageHundredths < 100 || leverageHundredths > initialMarginFraction) throw new Error("leverageOutOfRange");
  if (liquidationDistanceMicros(leverageHundredths, maintenanceMarginFraction) == null) throw new Error("leverageLeavesNoBuffer");
  const value = notional(price, size, "awayFromZero");
  const margin = value == null ? null : initialMargin(value, leverageHundredths);
  const charge = value == null ? null : fee(value, BigInt(feeMicros));
  if (value == null || margin == null || charge == null) throw new Error("arithmeticFailed");
  const total = money(margin + charge);
  if (total == null) throw new Error("arithmeticFailed");
  const backing = money(margin - charge) ?? 0n;
  const liquidation = liquidationPrice(price, size, backing, maintenanceMarginFraction, side);
  if (liquidation == null) throw new Error("arithmeticFailed");
  return { notional: value, margin, fee: charge, total, liquidationPrice: liquidation };
}

// ---------- market, as the app decodes it from /pub/context ----------

/// Mainnet leaves `symbol` empty for its oldest markets and carries the ticker in `name`.
export function marketFromContext(m) {
  const symbol = m.symbol || String(m.name ?? "").split(" ")[0];
  const c = m.config;
  return {
    id: m.id, symbol: symbol.toUpperCase(), instanceId: m.instance_id,
    maxMarketSlippageBps: m.order_max_market_slippage_bps,
    orderTTLBlocks: m.order_ttl_blocks, orderRetryBlocks: m.order_retry_blocks ?? m.order_ttl_blocks,
    config: {
      isOpen: c.is_open, priceDecimals: c.price_decimals, sizeDecimals: c.size_decimals,
      initialMarginFraction: c.initial_margin, maintenanceMarginFraction: c.maintenance_margin,
      takerFeeMicros: Number(c.taker_fee), maxLeverage: Math.trunc(c.initial_margin / 100),
    },
  };
}

// ---------- the planner ----------

/// Swift's `Double.rounded()`: to nearest, halves away from zero. JS Math.round sends -0.5 up.
const roundHalfAway = (x) => Math.sign(x) * Math.round(Math.abs(x));
const INT_MAX = 2 ** 63; // Swift Int's bounds, as numbers: chase is only compared, never stored
export const INT_LIMIT = INT_MAX;

export function clampedInt(value) {
  if (Number.isNaN(value)) return 0;
  const rounded = roundHalfAway(value);
  if (rounded >= INT_MAX) return INT_MAX;
  if (rounded < -INT_MAX) return -INT_MAX;
  return rounded;
}

/// Basis points moved against `side` since `entry`, negative when in the copy's favour.
export function chaseBps(entry, mark, side) {
  if (!(entry > 0) || !Number.isFinite(entry) || !Number.isFinite(mark)) return 0;
  const run = (mark - entry) / entry * 10_000;
  return clampedInt(roundHalfAway(side === "long" ? run : -run));
}

/// Opens and flips from the books after, then closes from the books before, each sorted by symbol.
/// Resizing is not a move.
export function moves(before, after) {
  const out = [];
  for (const symbol of Object.keys(after).sort()) {
    const now = after[symbol];
    const was = before[symbol];
    if (was) { if (was.side !== now.side) out.push({ kind: "flipped", position: now }); }
    else out.push({ kind: "opened", position: now });
  }
  for (const symbol of Object.keys(before).sort()) {
    if (!(symbol in after)) out.push({ kind: "closed", position: before[symbol] });
  }
  return out;
}

export function side(position, rules) {
  return rules.direction === "fade" ? (position.side === "long" ? "short" : "long") : position.side;
}

export function leverage(position, rules, market) {
  const theirs = roundHalfAway(position.leverage ?? 1);
  return Math.max(1, Math.min(theirs, rules.maxLeverage, market.config.maxLeverage));
}

export function conviction(collateral, portfolio) {
  if (portfolio == null || !(portfolio > 0) || !(collateral > 0)) return 1;
  return Math.min(2, Math.max(0.5, (collateral / portfolio) / 0.10));
}

export function trigger(mark, side, percent, leverage) {
  if (leverage <= 0 || percent === 0) return null;
  const denominator = BigInt(100 * leverage);
  const direction = side === "long" ? BigInt(percent) : -BigInt(percent);
  const numerator = mark.raw * (denominator + direction);
  if (numerator <= 0n) return null;
  // A long's stop and a short's take-profit sit below the mark: rounded down, they never trigger
  // earlier than asked. The other two round up for the same reason.
  const below = direction < 0n;
  const quotient = numerator / denominator;
  const raw = below || numerator % denominator === 0n ? quotient : quotient + 1n;
  return raw <= INT64_MAX ? scaled(raw, mark.decimals) : null;
}

const skip = (kind, extra = {}) => ({ ok: false, skip: { kind, ...extra } });

/// `position` {symbol, side, size, entry, mark, collateral, leverage} in plain numbers as read off
/// the contract; `mark` a scaled price; `free` and `realisedToday` raw AUSD BigInts.
export function plan({ position, traderPortfolio = null, rules, guards, market, mark, free, openCopies, realisedToday }) {
  if (!market.config.isOpen) return skip("marketClosed");
  if (openCopies.length >= guards.maxOpenCopies) return skip("openCopiesLimit", { limit: guards.maxOpenCopies });
  if (realisedToday < 0n && -realisedToday >= BigInt(guards.dailyLossLimit) * 1_000_000n) {
    return skip("dailyLossLimit", { limit: guards.dailyLossLimit });
  }

  const copySide = side(position, rules);
  const symbol = position.symbol.toUpperCase();
  const sameMarket = openCopies.filter((c) => c.symbol.toUpperCase() === symbol);
  if (sameMarket.some((c) => c.side !== copySide)) return skip("offsetsOpenCopy");

  // Against the trader's own venue: on testnet `mark` is a different market from the one they
  // entered on, so comparing the two would measure the gap between venues.
  const chase = chaseBps(position.entry, position.mark, copySide);
  if (chase > rules.maxChaseBps) return skip("chased", { bps: chase });

  const lev = leverage(position, rules, market);
  let margin = rules.marginPerTrade;
  if (rules.sizing === "conviction") margin *= conviction(position.collateral, traderPortfolio);
  const room = guards.maxMarketExposure - sameMarket.reduce((sum, c) => sum + c.notional, 0);
  if (margin * lev > room) {
    margin = room / lev;
    if (margin < 1) return skip("exposureLimit", { limit: guards.maxMarketExposure });
  }
  margin = Math.floor(margin * 100) / 100;
  const marginRaw = BigInt(Math.floor(margin * 1_000_000));
  if (marginRaw <= 0n) return skip("tooSmall");
  // What leaves the balance is margin plus the venue's fee on the notional.
  const notionalRaw = marginRaw * BigInt(lev);
  let feeRaw = (notionalRaw * BigInt(market.config.takerFeeMicros) + 999_999n) / 1_000_000n;
  if (feeRaw > INT64_MAX) feeRaw = INT64_MAX;
  if (free == null || free < marginRaw + feeRaw) return skip("insufficientBalance");

  // size = margin × leverage ÷ price, at the market's size scale, never rounded up.
  const sizeScale = 10n ** BigInt(market.config.sizeDecimals + mark.decimals);
  const raw = marginRaw * BigInt(lev) * sizeScale / (mark.raw * 1_000_000n);
  const size = raw > 0n && raw <= INT64_MAX ? scaled(raw, market.config.sizeDecimals) : null;
  if (!size) return skip("tooSmall");

  let quoted;
  try {
    quoted = quote({
      side: copySide, size, price: mark, leverageHundredths: lev * 100, feeMicros: market.config.takerFeeMicros,
      initialMarginFraction: market.config.initialMarginFraction, maintenanceMarginFraction: market.config.maintenanceMarginFraction,
    });
  } catch { return skip("tooSmall"); }
  if (free < quoted.total) return skip("insufficientBalance");

  const slippageBps = Math.max(5, Math.min(rules.maxChaseBps - Math.max(0, chase), 50, market.maxMarketSlippageBps));
  const stopLoss = rules.stopLossPercent == null ? null : trigger(mark, copySide, -rules.stopLossPercent, lev);
  const takeProfit = rules.takeProfitPercent == null ? null : trigger(mark, copySide, rules.takeProfitPercent, lev);
  return {
    ok: true,
    plan: {
      side: copySide, leverage: lev, margin, notional: margin * lev,
      draft: {
        side: copySide, size, leverageHundredths: lev * 100, slippageBps,
        protection: stopLoss == null && takeProfit == null ? null : { stopLoss, takeProfit },
      },
      liquidationPrice: quoted.liquidationPrice,
    },
  };
}

/// The app's sentences for each skip (CopyTrader.sentence), so a notification reads the same.
export function sentence(result, rules, network = "mainnet") {
  const s = result.skip;
  switch (s.kind) {
    case "marketNotListed": return `This market isn't listed on Perpl ${network}.`;
    case "marketClosed": return "The market is closed for trading.";
    case "openCopiesLimit": return `${s.limit} copies are already open, your limit.`;
    case "dailyLossLimit": return rules.mode === "shadow"
      ? `Today's shadow losses reached your ${s.limit} AUSD limit; no more paper copies today.`
      : `Today's copy losses reached your ${s.limit} AUSD limit, so auto-copy paused.`;
    case "insufficientBalance": return `Not enough free AUSD for a ${rules.marginPerTrade} AUSD copy.`;
    case "chased": return `Price had already moved ${(s.bps / 100).toFixed(2)}% against the copy since their entry.`;
    case "tooSmall": return `${rules.marginPerTrade} AUSD is too small to size on this market.`;
    case "offsetsOpenCopy": return "It would offset a copy you already hold on the other side of this market.";
    case "exposureLimit": return `This market already holds your ${s.limit} AUSD exposure limit.`;
    default: return "The copy was skipped.";
  }
}

// ---------- shadow fills ----------

export const SHADOW_SLIPPAGE_BPS = 3;

export function shadowFill({ mark, plan, takerFeeMicros, maintenanceMarginFraction, rules }) {
  const isLong = plan.side === "long";
  const entry = mark * (1 + (isLong ? 1 : -1) * SHADOW_SLIPPAGE_BPS / 10_000);
  const notionalValue = plan.margin * plan.leverage;
  const move = (percent) => percent / 100 / plan.leverage;
  const distance = liquidationDistanceMicros(plan.leverage * 100, maintenanceMarginFraction);
  return {
    entry, units: notionalValue / entry, margin: plan.margin, leverage: plan.leverage, isLong,
    stop: rules.stopLossPercent == null ? null : entry * (1 + (isLong ? -1 : 1) * move(rules.stopLossPercent)),
    take: rules.takeProfitPercent == null ? null : entry * (1 + (isLong ? 1 : -1) * move(rules.takeProfitPercent)),
    fees: notionalValue * Number(takerFeeMicros) / 1_000_000,
    liquidation: distance == null ? null : entry * (1 + (isLong ? -1 : 1) * distance / 1_000_000),
  };
}

const liquidated = (fill, mark) => fill.liquidation != null && (fill.isLong ? mark <= fill.liquidation : mark >= fill.liquidation);

/// Both fees are charged: since contract 1.7.5 Perpl takes the taker rate on closes too.
export function shadowPnL(fill, mark, takerFeeMicros) {
  if (liquidated(fill, mark)) return -fill.margin;
  const exit = mark * (1 + (fill.isLong ? -1 : 1) * SHADOW_SLIPPAGE_BPS / 10_000);
  const gross = (exit - fill.entry) * fill.units * (fill.isLong ? 1 : -1);
  const exitFee = exit * fill.units * Number(takerFeeMicros) / 1_000_000;
  return Math.max(gross - fill.fees - exitFee, -fill.margin);
}

/// Liquidation first; a stop fills at the mark that broke it, a take-profit keeps its own price.
export function shadowTriggered(fill, mark) {
  if (liquidated(fill, mark)) return { exit: "liquidation", price: fill.liquidation };
  if (fill.stop != null && (fill.isLong ? mark <= fill.stop : mark >= fill.stop)) {
    return { exit: "stop", price: fill.isLong ? Math.min(mark, fill.stop) : Math.max(mark, fill.stop) };
  }
  if (fill.take != null && (fill.isLong ? mark >= fill.take : mark <= fill.take)) return { exit: "take", price: fill.take };
  return null;
}
