/// Desk as an MCP server: read-only market tools for ChatGPT, Claude and any MCP client. The
/// tools for one token, one wallet and each list return a card (MCP Apps) with the answer.
/// Served statelessly from /mcp inside the v1 function; every request builds a fresh server.

import { readFileSync } from "node:fs";
import { createMcpHandler, McpServer } from "@modelcontextprotocol/server";
import * as z from "zod/v4";
import {
  CHAIN_SLUGS, DeskDataError, IMAGE_HOSTS, INTERVALS, SITE, deskApi, links, loadCandles, loadMarkets, loadSmartMoney,
  loadToken, loadTopTraders, loadTraderStats, loadWallet, searchTokens, trendingTokens,
} from "./_mcp-data.mjs";
import { clientIp, rateLimit } from "./_ratelimit.mjs";

export const CARD_URI = "ui://desk/card-v2.html";
const CARD_HTML = readFileSync(new URL("../mcp/card.html", import.meta.url), "utf8");
const VERSION = "1.0.0";

export const INSTRUCTIONS = [
  "Desk reads public crypto market data, Monad first: token prices and risk, wallet portfolios and trading records, smart-money trades, and the traders and markets on Perpl, Monad's perpetuals exchange.",
  "Every tool is read-only. Desk cannot trade, transfer, sign or change anything.",
  "The tools for a token, a wallet, trending tokens, smart money, the Perpl leaderboard and Perpl markets also show the person a card with those figures, and a price chart for a token, so keep the reply short and don't repeat every number.",
  "Wallets can be a 0x or Solana address or a name such as vitalik.eth or name.nad.",
  "Figures are market data, not financial advice.",
].join(" ");

// MARK: Schemas — the exact shapes the loaders return.

const n = z.number().nullable();
const s = z.string();
const ns = z.string().nullable();
const chain = z.enum(CHAIN_SLUGS);
const walletArg = z.string().min(2).max(80).describe("A 0x address, a Solana address, or a name such as vitalik.eth or name.nad");
const contractArg = z.string().min(32).max(44).describe("The token's contract address: 0x… on EVM chains, base58 on Solana");

const Listed = z.object({ chain: s, contract: s, symbol: s, name: s, priceUsd: n, change24hPercent: n, marketCapUsd: n, liquidityUsd: n, volume24hUsd: n, holders: n, url: s });
const Position = z.object({ market: s, side: z.enum(["long", "short"]), sizeUsd: n, entryPrice: n, markPrice: n, pnlUsd: n, pnlPercent: n, leverage: n });
const Window = z.object({ realizedUsd: n, trades: z.number(), winRatePercent: n });

const Wallet = z.object({
  address: s, name: ns, nameSource: ns, x: ns, portfolioUsd: n,
  chains: z.array(z.object({ chain: s, valueUsd: n })),
  holdings: z.array(z.object({ chain: s, symbol: s, contract: ns, balance: n, valueUsd: n })),
  leftOut: z.array(z.object({ chain: s, symbol: s, contract: s, reason: s })),
  monadTrading: z.object({
    status: z.enum(["ready", "indexing", "unavailable"]), realizedUsd: n, unrealizedUsd: n, winRatePercent: n,
    last7d: Window.nullable(), last30d: Window.nullable(),
    recentTrades: z.array(z.object({ time: ns, side: z.enum(["buy", "sell"]), symbol: s, token: s, valueUsd: n, gainUsd: n })),
  }),
  perps: z.object({ account: s, unrealizedPnlUsd: n, collateralUsd: n, positions: z.array(Position) }).nullable(),
  labels: z.array(s), asOf: ns, url: s,
});

const Token = z.object({
  token: z.object({
    chain: s, chainName: s, contract: s, symbol: s, name: s, priceUsd: n,
    changePercent: z.object({ "5m": n, "1h": n, "4h": n, "24h": n }),
    marketCapUsd: n, liquidityUsd: n, volume24hUsd: n, trades24h: n, holders: n, topTenHoldersPercent: n,
  }),
  risk: z.object({ level: s, reasons: z.array(s), facts: z.array(s), creatorHoldsPercent: n }).nullable(),
  asOf: ns, url: s,
});

const Candles = z.object({
  chain: s, contract: s, interval: z.enum(["1H", "4H", "1D"]),
  candles: z.array(z.object({ time: ns, open: z.number(), high: z.number(), low: z.number(), close: z.number() })),
});

const SmartMoney = z.object({
  scope: z.enum(["all", "monad", "other"]),
  trades: z.array(z.object({
    wallet: s, otherWallets: z.number(), chain: s, token: s, symbol: s, name: s, side: z.enum(["buy", "sell"]), valueUsd: n,
    time: ns, marketCapUsd: n, liquidityUsd: n, change24hPercent: n, walletWinRatePercent: n, walletRealizedUsd: n, url: s,
  })),
  asOf: ns,
});

const Traders = z.object({
  exchange: s,
  traders: z.array(z.object({ rank: z.number(), address: s, name: ns, unrealizedPnlUsd: n, positions: z.array(Position), url: s })),
  asOf: ns,
});

const TraderStats = z.object({
  address: s, summary: ns,
  stats: z.object({
    closedTrades: z.number(), winRatePercent: n, realizedPnlUsd: n, profitFactor: n, maxDrawdownUsd: n, averageLeverage: n,
    averageHoldMinutes: n, liquidations: z.number(), volumeUsd: n, bestMarket: ns, worstMarket: ns, style: z.array(s),
    firstTrade: ns, lastActive: ns,
  }),
  recentTrades: z.array(z.object({ time: ns, market: s, side: z.enum(["long", "short"]), entryPrice: n, exitPrice: n, pnlUsd: n, leverage: n, liquidated: z.boolean() })),
  url: s,
});

const Markets = z.object({
  exchange: s, collateral: s,
  markets: z.array(z.object({
    market: s, markPrice: n, change24hPercent: n, volume24hUsd: n, openInterestUsd: n, fundingRatePercent: n,
    fundingIntervalMinutes: n, maxLeverage: n, url: s,
  })),
  asOf: ns,
});

const SearchResult = z.object({ query: s, tokens: z.array(Listed) });
const Trending = z.object({ chain: s, tokens: z.array(Listed), asOf: ns });

// MARK: Words for the model. Short: the structured result carries the detail.

const fmt = (value) => {
  if (value === null || value === undefined) return "unknown";
  const abs = Math.abs(value);
  const sign = value < 0 ? "-" : "";
  if (abs >= 1e9) return `${sign}$${(abs / 1e9).toFixed(2)}B`;
  if (abs >= 1e6) return `${sign}$${(abs / 1e6).toFixed(2)}M`;
  if (abs >= 1e3) return `${sign}$${(abs / 1e3).toFixed(1)}K`;
  if (abs >= 1) return `${sign}$${abs.toFixed(2)}`;
  return `${sign}$${Number(abs.toPrecision(4))}`;
};
const who = (w) => (w.name ? `${w.name} (${w.address})` : w.address);
/// A price reads in full: $81,415.60 or $0.001366, never $81.4K.
const cost = (value) => {
  if (value === null || value === undefined) return "unknown";
  if (Math.abs(value) >= 1) return `$${value.toLocaleString("en-US", { maximumFractionDigits: Math.abs(value) >= 1000 ? 2 : 4 })}`;
  return `$${Number(value.toPrecision(4))}`;
};

export const say = {
  wallet(w) {
    const lines = [`${who(w)} holds about ${fmt(w.portfolioUsd)} across ${w.chains.length} chain${w.chains.length === 1 ? "" : "s"}.`];
    if (w.holdings.length) lines.push(`Largest holdings: ${w.holdings.slice(0, 3).map((h) => `${h.symbol} ${fmt(h.valueUsd)} on ${h.chain}`).join(", ")}.`);
    if (w.leftOut.length) lines.push(`Left out ${w.leftOut.length} token${w.leftOut.length === 1 ? "" : "s"} with no real market (likely airdropped spam): ${w.leftOut.slice(0, 4).map((x) => x.symbol).join(", ")}.`);
    if (w.perps?.positions.length) lines.push(`Open Perpl positions: ${w.perps.positions.map((p) => `${p.market} ${p.side} ${p.leverage}x, PnL ${fmt(p.pnlUsd)}`).join("; ")}.`);
    const m = w.monadTrading;
    if (m.status === "ready" && (m.last30d?.trades ?? 0) > 0) lines.push(`On Monad over 30 days: ${m.last30d.trades} trades, realized ${fmt(m.last30d.realizedUsd)}${m.last30d.winRatePercent == null ? "" : `, win rate ${m.last30d.winRatePercent}%`}.`);
    if (m.status === "indexing") lines.push("Its Monad trade history is still being read; ask again in a minute for the full record.");
    return lines.join(" ");
  },
  token(t) {
    const x = t.token;
    const lines = [`${x.name || x.symbol} (${x.symbol}) on ${x.chainName}: ${cost(x.priceUsd)}, ${x.changePercent["24h"] ?? "unknown"}% over 24h, market cap ${fmt(x.marketCapUsd)}, liquidity ${fmt(x.liquidityUsd)}.`];
    if (t.risk) lines.push(`Desk rates it ${t.risk.level} risk${t.risk.reasons.length ? `: ${t.risk.reasons.join("; ")}` : ""}.`);
    return lines.join(" ");
  },
  list(label, tokens) {
    return tokens.length ? `${label}: ${tokens.slice(0, 8).map((t) => `${t.symbol} on ${t.chain} (${cost(t.priceUsd)}, ${t.change24hPercent ?? "?"}% 24h)`).join(", ")}.` : `${label}: nothing found.`;
  },
  smart(m) {
    return m.trades.length
      ? `${m.trades.length} recent smart-money trades. Latest: ${m.trades.slice(0, 5).map((t) => `${t.side === "sell" ? "sold" : "bought"} ${fmt(t.valueUsd)} of ${t.symbol} on ${t.chain}`).join("; ")}.`
      : "No recent smart-money trades.";
  },
  traders(b) {
    return b.traders.length
      ? `Top Perpl traders by open profit: ${b.traders.slice(0, 5).map((t) => `#${t.rank} ${t.name ?? t.address} ${fmt(t.unrealizedPnlUsd)}`).join(", ")}.`
      : "No open positions on Perpl right now.";
  },
  stats(t) {
    const x = t.stats;
    return `${t.address} on Perpl: ${x.closedTrades} closed trades, win rate ${x.winRatePercent ?? "unknown"}%, realized ${fmt(x.realizedPnlUsd)}, average leverage ${x.averageLeverage ?? "unknown"}x.${t.summary ? ` ${t.summary}` : ""}`;
  },
  markets(m) {
    return `Perpl markets (collateral ${m.collateral}): ${m.markets.map((x) => `${x.market} ${cost(x.markPrice)} (${x.change24hPercent ?? "?"}% 24h, funding ${x.fundingRatePercent ?? "?"}% per ${x.fundingIntervalMinutes ?? "?"} min, up to ${x.maxLeverage}x)`).join("; ")}.`;
  },
  candles(c) {
    const first = c.candles[0], last = c.candles.at(-1);
    const high = Math.max(...c.candles.map((b) => b.high)), low = Math.min(...c.candles.map((b) => b.low));
    return `${c.candles.length} ${c.interval} candles from ${first.time} to ${last.time}: opened ${cost(first.open)}, now ${cost(last.close)}, high ${cost(high)}, low ${cost(low)}.`;
  },
};

// MARK: Server

const READ_ONLY = { readOnlyHint: true, destructiveHint: false, openWorldHint: true, idempotentHint: true };
const status = (invoking, invoked) => ({ "openai/toolInvocation/invoking": invoking, "openai/toolInvocation/invoked": invoked });
const card = (invoking, invoked) => ({ ui: { resourceUri: CARD_URI }, "openai/outputTemplate": CARD_URI, ...status(invoking, invoked) });

function failure(error, tool) {
  if (error instanceof DeskDataError) return { isError: true, content: [{ type: "text", text: error.message }] };
  console.error(`mcp ${tool} failed:`, error?.message ?? error);
  return { isError: true, content: [{ type: "text", text: "Desk couldn't read that right now. Try again in a moment." }] };
}

/// The caller to rate-limit: ChatGPT's anonymous user id when it sends one, else the address
/// the request came from (Claude's calls arrive from Anthropic's ranges).
function caller(ctx) {
  const subject = ctx?.mcpReq?._meta?.["openai/subject"];
  if (typeof subject === "string" && subject) return `s:${subject.slice(0, 80)}`;
  const forwarded = ctx?.http?.req?.headers?.get?.("x-forwarded-for") ?? "";
  return `ip:${clientIp({ "x-forwarded-for": forwarded })}`;
}

export function serverFor({ get, store = null, now = Date.now } = {}) {
  const server = new McpServer({ name: "desk", title: "Desk", version: VERSION, websiteUrl: SITE }, { instructions: INSTRUCTIONS });

  // One line per call: which tool, how it went and how long it took. Never the arguments.
  const tool = (name, config, run, { heavy = false } = {}) => server.registerTool(name, config, async (args, ctx) => {
    const started = Date.now();
    let outcome = "ok";
    try {
      if (heavy && store) {
        const limit = await rateLimit({ store, tier: "mcp-heavy", ip: caller(ctx), now: now() });
        if (!limit.allowed) {
          outcome = "limited";
          return { isError: true, content: [{ type: "text", text: `Desk is reading a lot of wallets for you right now. Try again in ${limit.retryAfter} seconds.` }] };
        }
      }
      try { return await run(args); } catch (error) { outcome = error instanceof DeskDataError ? "refused" : "failed"; return failure(error, name); }
    } finally {
      console.log(`mcp ${name} ${outcome} ${Date.now() - started}ms`);
    }
  });
  /// A result the card renders: the data with its kind for the card, and the card's URI
  /// repeated on the result, since some hosts look for it there rather than on the tool.
  const shown = (kind, data, text, extra = {}) => ({
    structuredContent: { kind, ...data },
    content: [{ type: "text", text }],
    _meta: { ui: { resourceUri: CARD_URI }, ...extra },
  });

  server.registerResource("desk-card", CARD_URI, {
    title: "Desk card",
    description: "Shows a Desk token with its chart, a wallet, trending tokens, smart-money trades, the Perpl leaderboard or Perpl's markets as a card.",
    mimeType: "text/html;profile=mcp-app",
  }, async (uri) => ({
    contents: [{
      uri: uri.href,
      mimeType: "text/html;profile=mcp-app",
      text: CARD_HTML,
      _meta: {
        ui: { prefersBorder: true, csp: { connectDomains: [], resourceDomains: IMAGE_HOSTS } },
        "openai/widgetDomain": SITE,
        "openai/widgetCSP": { redirect_domains: [SITE] },
        "openai/widgetDescription": "A Desk card that already shows these figures, with a chart for a token. Keep the reply short and don't repeat every number.",
      },
    }],
  }));

  tool("search_tokens", {
    title: "Search tokens",
    description: "Find tokens by name, symbol or contract address across Monad, Ethereum, Base, BNB Chain, Solana and other chains. Returns each match's chain and contract, price, 24h change, market cap and liquidity. Use it to find a token's contract before get_token; it shows no card.",
    inputSchema: z.object({ query: z.string().min(1).max(80).describe("A name, symbol or contract address"), chain: chain.optional().describe("Only this chain") }),
    outputSchema: SearchResult, annotations: READ_ONLY, _meta: status("Searching tokens…", "Tokens found"),
  }, async ({ query, chain: on }) => {
    const { data } = await searchTokens(get, { query, chain: on ?? null });
    return { structuredContent: data, content: [{ type: "text", text: say.list(`Matches for "${data.query}"`, data.tokens) }] };
  });

  tool("get_trending_tokens", {
    title: "Get trending tokens",
    description: "The tokens trading most actively right now on one chain (Monad by default) or across all chains, with price, 24h change, market cap and liquidity, shown to the person as a card they can tap through. Use for questions like \"what's moving on Monad\".",
    inputSchema: z.object({ chain: z.enum(["all", ...CHAIN_SLUGS]).optional().describe("A chain, or all. Defaults to monad.") }),
    outputSchema: Trending.extend({ kind: z.literal("tokens"), url: s }), annotations: READ_ONLY, _meta: card("Reading what's trending…", "Trending tokens"),
  }, async ({ chain: on }) => {
    const { data, images } = await trendingTokens(get, { chain: on ?? "monad", now });
    return shown("tokens", { ...data, url: links.markets() }, say.list(`Trending on ${data.chain}`, data.tokens), { images });
  });

  tool("get_token", {
    title: "Get token",
    description: "One token's price, short-term changes, market cap, liquidity, volume, holders and Desk's risk check (pool depth, holder concentration, age, sell pressure), shown to the person as a card with a price chart they can switch between hourly, four-hour and daily bars. Use for any question about a single token. Needs the chain and contract; call search_tokens first if you only have a name.",
    inputSchema: z.object({ chain, contract: contractArg }),
    outputSchema: Token.extend({ kind: z.literal("token") }), annotations: READ_ONLY, _meta: card("Reading the token…", "Token"),
  }, async ({ chain: on, contract }) => {
    const { data, images, candles } = await loadToken(get, { chain: on, contract, candles: "1H", now });
    return shown("token", data, say.token(data), { images, candles, interval: "1H" });
  });

  tool("get_token_candles", {
    title: "Get token price history",
    description: "Price candles for one token: 48 hourly bars (1H), 42 four-hour bars (4H) or 30 daily bars (1D). Use to describe price action over days or weeks. The token card also calls it when the person switches its chart.",
    inputSchema: z.object({ chain, contract: contractArg, interval: z.enum(Object.keys(INTERVALS)).optional().describe("1H, 4H or 1D. Defaults to 1H.") }),
    outputSchema: Candles, annotations: READ_ONLY,
    _meta: { ...status("Reading price history…", "Price history read"), "openai/widgetAccessible": true },
  }, async ({ chain: on, contract, interval }) => {
    const { data } = await loadCandles(get, { chain: on, contract, interval: interval ?? "1H" });
    return { structuredContent: data, content: [{ type: "text", text: say.candles(data) }] };
  });

  tool("get_wallet", {
    title: "Get wallet",
    description: "What a wallet holds across chains, its trading record on Monad (realized and unrealized PnL, win rate, recent trades), any open perpetuals positions on Perpl, and who it belongs to (ENS, .nad, Farcaster), shown to the person as a card. Spam tokens with no market are left out of the totals and listed separately. Accepts an address or a name.",
    inputSchema: z.object({ wallet: walletArg }),
    outputSchema: Wallet.extend({ kind: z.literal("wallet") }), annotations: READ_ONLY, _meta: card("Reading the wallet…", "Wallet"),
  }, async ({ wallet }) => {
    const { data, images } = await loadWallet(get, wallet, { now });
    return shown("wallet", data, say.wallet(data), { images });
  }, { heavy: true });

  tool("get_smart_money", {
    title: "Get smart-money trades",
    description: "Recent buys and sells by wallets with a winning 30-day record: on Monad (scored by Desk) and on Base, BNB Chain and Ethereum, shown to the person as a card. Each trade has the token, size, wallet and how many other tracked wallets traded it.",
    inputSchema: z.object({
      scope: z.enum(["all", "monad", "other"]).optional().describe("monad, other (Base, BNB Chain, Ethereum) or all. Defaults to all."),
      limit: z.number().int().min(1).max(20).optional().describe("How many trades. Defaults to 10."),
    }),
    outputSchema: SmartMoney.extend({ kind: z.literal("smart_money"), url: s }), annotations: READ_ONLY, _meta: card("Reading smart money…", "Smart money"),
  }, async ({ scope, limit }) => {
    const { data, images } = await loadSmartMoney(get, { scope: scope ?? "all", limit: limit ?? 10, now });
    return shown("smart_money", { ...data, url: links.markets() }, say.smart(data), { images });
  });

  tool("get_top_perp_traders", {
    title: "Get top Perpl traders",
    description: "The traders with the most open profit on Perpl, Monad's perpetuals exchange, with every open position (market, side, size, entry, mark, PnL and leverage), shown to the person as a leaderboard card. Read live from the exchange contract.",
    inputSchema: z.object({ limit: z.number().int().min(1).max(25).optional().describe("How many traders. Defaults to 10.") }),
    outputSchema: Traders.extend({ kind: z.literal("traders"), url: s }), annotations: READ_ONLY, _meta: card("Reading the Perpl leaderboard…", "Perpl leaderboard"),
  }, async ({ limit }) => {
    const { data, images } = await loadTopTraders(get, { limit: limit ?? 10, now });
    return shown("traders", { ...data, url: links.traders() }, say.traders(data), { images });
  });

  tool("get_perp_trader_stats", {
    title: "Get a Perpl trader's record",
    description: "A trader's closed-trade record on Perpl: number of trades, win rate, realized PnL, profit factor, drawdown, average leverage and hold time, trading style, and recent closed trades. Use before calling someone a good trader: the leaderboard only shows open profit.",
    inputSchema: z.object({ address: z.string().regex(/^0x[0-9a-fA-F]{40}$/).describe("The trader's 0x address") }),
    outputSchema: TraderStats, annotations: READ_ONLY, _meta: status("Reading the trader's record…", "Record read"),
  }, async ({ address }) => {
    const { data } = await loadTraderStats(get, { address });
    return { structuredContent: data, content: [{ type: "text", text: say.stats(data) }] };
  });

  tool("get_perp_markets", {
    title: "Get Perpl markets",
    description: "Perpl's perpetuals markets on Monad: mark price, 24h change, volume, open interest, funding rate and maximum leverage, shown to the person as a card. Optionally one market, such as BTC or MON.",
    inputSchema: z.object({ market: z.string().min(2).max(12).optional().describe("A market such as BTC, ETH or MON") }),
    outputSchema: Markets.extend({ kind: z.literal("markets"), url: s }), annotations: READ_ONLY, _meta: card("Reading Perpl markets…", "Perpl markets"),
  }, async ({ market }) => {
    const { data } = await loadMarkets(get, { market: market ?? null, now });
    return shown("markets", { ...data, url: links.markets() }, say.markets(data));
  });

  return server;
}

// MARK: HTTP

let shared = null;
export function mcpHandler({ store = null, get = deskApi(), now = Date.now } = {}) {
  return createMcpHandler(() => serverFor({ get, store, now }), {
    responseMode: "json",
    onerror: (error) => console.error("mcp:", error?.message ?? error),
  });
}

const SKIPPED = new Set(["host", "connection", "content-length", "transfer-encoding", "keep-alive", "upgrade"]);

/// Bridges Vercel's Node request to the SDK's fetch-shaped handler and back.
export async function serveMcp(req, res, { store = null, handler = null } = {}) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Accept, Authorization, Mcp-Protocol-Version, Mcp-Session-Id, Last-Event-ID");
  res.setHeader("Access-Control-Expose-Headers", "Mcp-Session-Id, Mcp-Protocol-Version, WWW-Authenticate");
  const method = String(req.method ?? "GET").toUpperCase();
  if (method === "OPTIONS") return res.status(204).end();

  const headers = new Headers();
  for (const [key, value] of Object.entries(req.headers ?? {})) {
    if (value == null || SKIPPED.has(key.toLowerCase())) continue;
    headers.set(key, Array.isArray(value) ? value.join(", ") : String(value));
  }
  let body;
  let parsedBody;
  if (method === "POST") {
    try {
      const raw = req.body;
      if (raw == null || raw === "") parsedBody = undefined;
      else if (typeof raw === "string") parsedBody = JSON.parse(raw);
      else if (Buffer.isBuffer(raw)) parsedBody = JSON.parse(raw.toString("utf8"));
      else parsedBody = raw;
    } catch {
      res.setHeader("Content-Type", "application/json");
      return res.status(400).end(JSON.stringify({ jsonrpc: "2.0", error: { code: -32700, message: "Parse error" }, id: null }));
    }
    body = parsedBody === undefined ? "" : JSON.stringify(parsedBody);
  }
  const request = new Request(`${SITE}/mcp`, { method, headers, body });
  const serve = handler ?? (shared ??= mcpHandler({ store }));
  const response = await serve.fetch(request, parsedBody === undefined ? undefined : { parsedBody });
  res.status(response.status);
  response.headers.forEach((value, key) => { if (key !== "content-length") res.setHeader(key, value); });
  res.setHeader("Cache-Control", "no-store");
  return res.end(await response.text());
}
