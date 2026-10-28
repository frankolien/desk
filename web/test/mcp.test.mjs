import assert from "node:assert/strict";
import test from "node:test";
import { CARD_URI, INSTRUCTIONS, mcpHandler, serveMcp } from "../api/_mcp.mjs";
import { DeskDataError, IMAGE_HOSTS, SITE, deskApi, image, unsellable } from "../api/_mcp-data.mjs";
import { memoryStore } from "../api/_store.mjs";
import { createHandler as v1Handler } from "../api/v1.mjs";

const WALLET = "0x1111111111111111111111111111111111111111";
const SPAM = "0x2222222222222222222222222222222222222222";
const REAL = "0x3333333333333333333333333333333333333333";
const TOKEN = "0x350035555e10d9afaf1566aaebfced5ba6c27777";

/// Desk's public API as fixtures: the shapes the real endpoints answer with.
function fixtureApi() {
  const calls = [];
  async function get(path, query = {}, { missing = null } = {}) {
    calls.push({ path, ...query });
    const view = query.view ?? "";
    if (path === "/api/traders" && view === "lookup") {
      if (query.q === "frank.nad") return { address: WALLET, via: "nad" };
      if (query.q === "@desky" || query.q === "desky") return { address: WALLET, via: "desk", identity: { name: "@desky" } };
      throw new DeskDataError(missing ?? "missing");
    }
    if (path === "/api/activity" && view === "wallet") {
      return {
        address: WALLET, observedAt: 1_800_000_000_000,
        identity: { name: "frank.nad", source: "nad", avatar: "https://evil.example/a.png", x: "frank" },
        portfolio: 100_000_150, chains: [{ chainIndex: "1", value: 100_000_050 }, { chainIndex: "143", value: 100 }],
        holdings: [
          { chainIndex: "1", chain: "Ethereum", contract: SPAM, symbol: "Eagle", balance: 1e7, value: 100_000_000 },
          { chainIndex: "143", chain: "Monad", contract: REAL, symbol: "CHOG", balance: 50, value: 100 },
          { chainIndex: "1", chain: "Ethereum", contract: "", symbol: "ETH", balance: 0.02, value: 50 },
        ],
        desk: { account: "42", collateral: 500, locked: 0, walletAusd: 0 },
        ledger: { status: "ready", realized: 12.5, unrealized: -3, winRate: 0.5, last7d: { realized: 1, trades: 2, winRate: 0.5 }, last30d: { realized: 12.5, trades: 4, winRate: 0.5 },
          tokens: [], trades: [{ time: 1_799_999_000_000, hash: "0xhash", token: REAL, symbol: "CHOG", side: "sell", amount: 10, price: 2, value: 20, gain: 5 }] },
        labels: [{ code: "perpl", text: "Trades perps here · Perpl #42" }],
        logos: { [`143:${REAL}`]: "https://static.oklink.com/chog.png", [`1:${SPAM}`]: "https://evil.example/spam.png", "1:": "https://assets.coingecko.com/eth.png" },
        balanceErrors: ["1,10: Chain not support"],
      };
    }
    if (path === "/api/token-details" && view === "prices") {
      return { prices: [
        { chainIndex: "1", contract: SPAM, price: 10, liquidity: 0, volume24H: 0 },
        { chainIndex: "143", contract: REAL, price: 2, liquidity: 50_000, volume24H: 900 },
      ] };
    }
    if (path === "/api/traders" && view === "trader") {
      return { traders: [{ accountId: "42", address: WALLET, pnl: "250.5", positions: [{ market: "BTC", side: "long", entry: "80000", mark: "81000", value: "8100", pnl: "100", pnlPercent: 12.5, leverage: 5 }] }] };
    }
    if (path === "/api/token-discovery") {
      const rows = [
        { chainIndex: "143", contract: TOKEN, symbol: "CHOG", name: "Chog", price: 0.0013, change: -1, marketCap: 1_300_000, liquidity: 6_500, volume24H: 300, holders: "0", logoURL: "https://static.oklink.com/chog.png" },
        { chainIndex: "143", contract: SPAM, symbol: "SIDE", name: "SIDE", price: 0.000004, change: -6, marketCap: 4_000, liquidity: 0, volume24H: 10, holders: "12", logoURL: "" },
      ];
      return { observedAt: 1_800_000_000_000, tokens: query.q === "nothing" ? [] : rows };
    }
    if (path === "/api/token-details" && view === "risk") {
      return { level: "high", reasons: [{ text: "Liquidity is thin" }], facts: [{ text: "Launched 300 days ago" }], metrics: { topTen: 38.3, creator: 0 } };
    }
    if (path === "/api/token-details" && view === "smart-money") {
      return { observedAt: 1_800_000_000_000, monad: [], trades: [{ wallet: WALLET, walletCount: 3, chainIndex: "56", token: TOKEN, symbol: "AGORA", name: "Agora", side: "buy", usd: 1340.5, time: 1_800_000_000_000, marketCap: 47_000, liquidity: 21_000, change24h: 1224.1, winRate: 37.7, realized: 4200, logoURL: "https://static.oklink.com/agora.png" }] };
    }
    if (path === "/api/token-details") {
      if (query.address === "0x0000000000000000000000000000000000000001") return { priceInfo: null };
      return { observedAt: 1_800_000_000_000, priceInfo: { price: "0.0013661", priceChange5M: "0", priceChange1H: "0.1", priceChange4H: "-0.3", priceChange24H: "-0.85", marketCap: "1366090", liquidity: "6554", volume24H: "330", txs24H: "45", holders: "33933", time: "1800000000000" }, holders: [] };
    }
    if (path === "/api/market-snapshot") {
      return { candles: Array.from({ length: 60 }, (_, i) => [String(1_800_000_000_000 - i * 3_600_000), "1", "2", "0.5", "1.5", "10", "10", "1"]) };
    }
    if (path === "/api/traders" && view === "top") {
      return { observedAt: 1_800_000_000_000, traders: [{ address: WALLET, pnl: "12855.37", positions: [{ market: "ETH", side: "short", entry: "2722", mark: "2368", value: "128888", pnl: "19350", pnlPercent: 150.1, leverage: 11.4 }] }] };
    }
    if (path === "/api/traders" && view === "identity") return { identities: { [WALLET]: { name: "frank.nad", avatar: "https://euc.li/frank.png" } } };
    if (path === "/api/traders" && view === "history") {
      return { address: WALLET, summary: "Scalper.", stats: { trades: 10, winRate: 0.6, realised: 120, profitFactor: 1.8, maxDrawdown: 40, averageLeverage: 5, averageHoldSeconds: 600, liquidations: 0, volume: 50_000, since: 1_790_000_000, lastActive: 1_799_000_000, tags: ["Scalper"], bestMarket: { symbol: "BTC" }, worstMarket: null },
        trades: [{ time: 1_799_000_000, market: "BTC", side: "long", entry: 80000, exit: 81000, pnl: 12, leverage: 5, liquidated: false }] };
    }
    if (path === "/api/v1/markets") {
      return { data: { collateral: "AUSD", head: { time: 1_800_000_000_000 }, markets: [{ name: "BTC", mark: 81000, change: 0.0225, volume24h: 8e6, openInterest: 7e5, fundingRate: 4e-5, fundingIntervalSec: 2580, maxLeverage: 15, isOpen: true }] } };
    }
    throw new Error(`no fixture for ${path} ${JSON.stringify(query)}`);
  }
  return { get, calls };
}

function client({ store = null, api = fixtureApi(), now = () => 1_800_000_100_000 } = {}) {
  const handler = mcpHandler({ store, get: api.get, now });
  let id = 0;
  async function rpc(method, params = {}, meta = undefined) {
    const response = await handler.fetch(new Request(`${SITE}/mcp`, {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json, text/event-stream", "mcp-protocol-version": "2025-06-18" },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params: meta ? { ...params, _meta: meta } : params }),
    }));
    const text = await response.text();
    const line = text.split("\n").find((l) => l.startsWith("data: ")) ?? text;
    return JSON.parse(line.replace(/^data: /, ""));
  }
  const call = async (name, args, meta) => (await rpc("tools/call", { name, arguments: args }, meta)).result;
  return { rpc, call, api };
}

test("initialize names the server and says up front that it is read-only", async () => {
  const { rpc } = client();
  const { result } = await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } });
  assert.equal(result.serverInfo.name, "desk");
  assert.equal(result.protocolVersion, "2025-06-18");
  assert.match(result.instructions.slice(0, 512), /read-only/);
  assert.equal(result.instructions, INSTRUCTIONS);
});

const CARDED = ["get_trending_tokens", "get_token", "get_wallet", "get_smart_money", "get_top_perp_traders", "get_perp_markets"];

test("every tool is annotated read-only with an output schema, and the main tools carry the card", async () => {
  const { rpc } = client();
  const { result } = await rpc("tools/list");
  assert.deepEqual(result.tools.map((t) => t.name).sort(), [...CARDED, "search_tokens", "get_token_candles", "get_perp_trader_stats"].sort());
  for (const tool of result.tools) {
    assert.deepEqual([tool.annotations.readOnlyHint, tool.annotations.destructiveHint, typeof tool.annotations.openWorldHint], [true, false, "boolean"], tool.name);
    assert.ok(tool.outputSchema, `${tool.name} has an output schema`);
    assert.ok(tool.description.length > 40, `${tool.name} explains itself`);
    const shows = CARDED.includes(tool.name);
    assert.equal(tool._meta?.ui?.resourceUri === CARD_URI, shows, tool.name);
    assert.equal(tool._meta?.["openai/outputTemplate"] === CARD_URI, shows, tool.name);
  }
});

test("each carded tool names its card kind and repeats the card's URI on the result", async () => {
  const { call } = client();
  const kinds = {
    get_trending_tokens: [{}, "tokens"], get_token: [{ chain: "monad", contract: TOKEN }, "token"], get_wallet: [{ wallet: WALLET }, "wallet"],
    get_smart_money: [{}, "smart_money"], get_top_perp_traders: [{}, "traders"], get_perp_markets: [{}, "markets"],
  };
  for (const [name, [args, kind]] of Object.entries(kinds)) {
    const result = await call(name, args);
    assert.equal(result.structuredContent.kind, kind, name);
    assert.equal(result._meta.ui.resourceUri, CARD_URI, name);
  }
  const plain = await call("search_tokens", { query: "chog" });
  assert.equal(plain.structuredContent.kind, undefined);
  assert.equal(plain._meta, undefined);
});

test("the card resource declares exactly the image hosts it loads and leaves Claude's sandbox domain alone", async () => {
  const { rpc } = client();
  const { result } = await rpc("resources/read", { uri: CARD_URI });
  const [content] = result.contents;
  assert.equal(content.mimeType, "text/html;profile=mcp-app");
  assert.match(content.text, /ui\/initialize/);
  assert.doesNotMatch(content.text, /innerHTML/, "the card never parses data as HTML");
  assert.deepEqual(content._meta.ui.csp.resourceDomains, IMAGE_HOSTS);
  assert.deepEqual(content._meta.ui.csp.connectDomains, []);
  assert.equal(content._meta.ui.domain, undefined);
  assert.equal(content._meta["openai/widgetDomain"], SITE);
  assert.deepEqual(content._meta["openai/widgetCSP"].redirect_domains, [SITE]);
});

test("get_wallet resolves a name, leaves spam with no market out of the totals and strips diagnostics", async () => {
  const { call } = client();
  const result = await call("get_wallet", { wallet: "frank.nad" });
  assert.equal(result.isError, undefined);
  const w = result.structuredContent;
  assert.equal(w.address, WALLET);
  assert.equal(w.name, "frank.nad");
  assert.equal(w.portfolioUsd, 150);
  assert.deepEqual(w.leftOut, [{ chain: "ethereum", symbol: "Eagle", contract: SPAM, reason: "no market" }]);
  assert.ok(!w.holdings.some((h) => h.symbol === "Eagle"));
  assert.deepEqual(w.chains.map((c) => c.chain), ["monad", "ethereum"]);
  assert.equal(w.perps.positions[0].market, "BTC");
  assert.equal(w.monadTrading.recentTrades[0].gainUsd, 5);
  assert.equal(w.url, `${SITE}/app/wallet/${WALLET}`);
  assert.ok(!("balanceErrors" in w));
  assert.match(result.content[0].text, /Left out 1 token/);
});

test("get_wallet passes only allowed images to the card", async () => {
  const { call } = client();
  const result = await call("get_wallet", { wallet: WALLET });
  assert.equal(result.structuredContent.kind, "wallet");
  assert.equal(result._meta.images.avatar, null, "an avatar on an undeclared host is dropped");
  assert.equal(result._meta.images.tokens[`monad:${REAL}`], "https://static.oklink.com/chog.png");
  assert.equal(result._meta.images.tokens[`ethereum:${SPAM}`], undefined);
});

test("get_token returns the token, its risk and an hour chart for the card", async () => {
  const { call } = client();
  const result = await call("get_token", { chain: "monad", contract: TOKEN });
  const c = result.structuredContent;
  assert.equal(c.kind, "token");
  assert.equal(c.token.symbol, "CHOG");
  assert.equal(c.token.holders, 33933);
  assert.equal(c.risk.level, "high");
  assert.equal(result._meta.candles.length, 48);
  assert.equal(result._meta.interval, "1H");
  assert.ok(result._meta.candles[0].time < result._meta.candles.at(-1).time);
  assert.match(result.content[0].text, /high risk/);
});

test("get_token_candles serves each interval's bar count", async () => {
  const { call } = client();
  const day = await call("get_token_candles", { chain: "monad", contract: TOKEN, interval: "1D" });
  assert.equal(day.structuredContent.candles.length, 30);
  const four = await call("get_token_candles", { chain: "monad", contract: TOKEN, interval: "4H" });
  assert.equal(four.structuredContent.candles.length, 42);
});

test("the leaderboard, smart money, trader record and markets come back shaped", async () => {
  const { call } = client();
  const top = await call("get_top_perp_traders", { limit: 5 });
  assert.equal(top.structuredContent.traders[0].name, "frank.nad");
  assert.equal(top.structuredContent.traders[0].unrealizedPnlUsd, 12855.37);
  const smart = await call("get_smart_money", { scope: "other", limit: 5 });
  assert.equal(smart.structuredContent.trades[0].otherWallets, 2);
  const stats = await call("get_perp_trader_stats", { address: WALLET });
  assert.equal(stats.structuredContent.stats.winRatePercent, 60);
  assert.equal(stats.structuredContent.stats.averageHoldMinutes, 10);
  const markets = await call("get_perp_markets", { market: "btc-perp" });
  assert.equal(markets.structuredContent.markets[0].change24hPercent, 2.25);
  assert.match(markets.content[0].text, /BTC \$81,000/);
  const search = await call("search_tokens", { query: "chog" });
  assert.equal(search.structuredContent.tokens[0].holders, null, "a search's zero holder count means unknown");
});

test("failures read as sentences, and bad input never reaches a loader", async () => {
  const { call, api } = client();
  const unknown = await call("get_wallet", { wallet: "nobody.eth" });
  assert.equal(unknown.isError, true);
  assert.match(unknown.content[0].text, /No wallet answers to "nobody\.eth"/);
  const empty = await call("get_token", { chain: "monad", contract: "0x0000000000000000000000000000000000000001" });
  assert.match(empty.content[0].text, /no market data/);
  const before = api.calls.length;
  const bad = await call("get_token", { chain: "dogechain", contract: TOKEN });
  assert.equal(bad.isError, true);
  assert.match(bad.content[0].text, /Input validation error/);
  assert.equal(api.calls.length, before);
  const market = await call("get_perp_markets", { market: "DOGE" });
  assert.match(market.content[0].text, /Perpl has no DOGE market/);
});

test("wallet reads are limited per ChatGPT user, not per shared address", async () => {
  const store = memoryStore();
  const { call } = client({ store });
  const meta = { "openai/subject": "user-a" };
  for (let i = 0; i < 20; i++) assert.equal((await call("get_wallet", { wallet: WALLET }, meta)).isError, undefined);
  const limited = await call("get_wallet", { wallet: WALLET }, meta);
  assert.equal(limited.isError, true);
  assert.match(limited.content[0].text, /Try again in \d+ seconds/);
  assert.equal((await call("get_wallet", { wallet: WALLET }, { "openai/subject": "user-b" })).isError, undefined);
});

test("image() keeps declared hosts, moves Desk's old host to the site, and drops the rest", () => {
  assert.equal(image("https://static.oklink.com/x.png"), "https://static.oklink.com/x.png");
  assert.equal(image("https://web-lovat-nine-49.vercel.app/api/traders?view=avatar&address=0x1"), `${SITE}/api/traders?view=avatar&address=0x1`);
  assert.equal(image("https://evil.example/x.png"), null);
  assert.equal(image("http://static.oklink.com/x.png"), null);
  assert.equal(image(null), null);
});

test("unsellable() flags no market at all and holdings worth twenty times their pool", async () => {
  const get = async () => ({ prices: [
    { chainIndex: "1", contract: "0xaa", liquidity: 0, volume24H: 0 },
    { chainIndex: "1", contract: "0xbb", liquidity: 4_800, volume24H: 3 },
    { chainIndex: "1", contract: "0xcc", liquidity: 1e9, volume24H: 1e8 },
  ] });
  const out = await unsellable(get, [
    { chainIndex: "1", contract: "0xaa", symbol: "A", value: 1e8 },
    { chainIndex: "1", contract: "0xbb", symbol: "B", value: 286_000 },
    { chainIndex: "1", contract: "0xcc", symbol: "C", value: 5e6 },
    { chainIndex: "1", contract: "", symbol: "ETH", value: 1e6 },
  ]);
  assert.deepEqual(out.map((row) => [row.symbol, row.reason]), [["A", "no market"], ["B", "worth far more than its pool"]]);
  assert.deepEqual(await unsellable(async () => { throw new Error("down"); }, [{ chainIndex: "1", contract: "0xaa", value: 1e8 }]), []);
});

/// Vercel's Node request and response, reduced to what the handlers use.
function nodePair({ method = "POST", url = "/api/v1?path=mcp", headers = {}, body } = {}) {
  const out = { status: 0, headers: {}, body: "" };
  const req = { method, url, query: Object.fromEntries(new URL(url, "http://x").searchParams), headers: { host: "trydesk.trade", ...headers }, body };
  const res = {
    status(code) { out.status = code; return this; },
    setHeader(key, value) { out.headers[key.toLowerCase()] = value; },
    end(value) { if (value !== undefined) out.body = String(value); return this; },
    json(value) { out.body = JSON.stringify(value); return this; },
  };
  return { req, res, out };
}

test("serveMcp answers CORS preflights with the MCP headers and refuses a broken body", async () => {
  const handler = mcpHandler({ get: fixtureApi().get });
  const pre = nodePair({ method: "OPTIONS" });
  await serveMcp(pre.req, pre.res, { handler });
  assert.equal(pre.out.status, 204);
  assert.match(pre.out.headers["access-control-allow-headers"], /Mcp-Protocol-Version/);
  const broken = nodePair({ headers: { "content-type": "application/json" }, body: "{not json" });
  await serveMcp(broken.req, broken.res, { handler });
  assert.equal(broken.out.status, 400);
  assert.equal(JSON.parse(broken.out.body).error.code, -32700);
  const ok = nodePair({ headers: { "content-type": "application/json", accept: "application/json, text/event-stream" },
    body: { jsonrpc: "2.0", id: 1, method: "ping" } });
  await serveMcp(ok.req, ok.res, { handler });
  assert.equal(ok.out.status, 200);
  assert.equal(ok.out.headers["cache-control"], "no-store");
});

test("the v1 function routes /mcp to the server and serves OpenAI's domain challenge", async () => {
  const handler = v1Handler({ store: null });
  const init = nodePair({ headers: { "content-type": "application/json", accept: "application/json, text/event-stream" },
    body: { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "1" } } } });
  await handler(init.req, init.res);
  assert.equal(init.out.status, 200);
  assert.match(init.out.body, /"name":"desk"/);
  const pre = nodePair({ method: "OPTIONS" });
  await handler(pre.req, pre.res);
  assert.match(pre.out.headers["access-control-allow-headers"], /Mcp-Session-Id/);

  const saved = process.env.OPENAI_APPS_CHALLENGE;
  try {
    delete process.env.OPENAI_APPS_CHALLENGE;
    const none = nodePair({ method: "GET", url: "/api/v1?path=openai-apps-challenge" });
    await handler(none.req, none.res);
    assert.equal(none.out.status, 404);
    process.env.OPENAI_APPS_CHALLENGE = "token-123";
    const set = nodePair({ method: "GET", url: "/api/v1?path=openai-apps-challenge" });
    await handler(set.req, set.res);
    assert.deepEqual([set.out.status, set.out.body, set.out.headers["content-type"]], [200, "token-123", "text/plain; charset=utf-8"]);
  } finally {
    if (saved === undefined) delete process.env.OPENAI_APPS_CHALLENGE; else process.env.OPENAI_APPS_CHALLENGE = saved;
  }
});

test("trending leaves out tokens whose pool holds next to nothing", async () => {
  const { call } = client();
  const result = await call("get_trending_tokens", { chain: "monad" });
  assert.deepEqual(result.structuredContent.tokens.map((t) => t.symbol), ["CHOG"]);
});

test("a failed risk read is tried once more before the token goes out without it", async () => {
  const api = fixtureApi();
  let failures = 1;
  const flaky = { ...api, get: async (path, query = {}, options) => {
    if (query.view === "risk" && failures-- > 0) throw new DeskDataError("down");
    return api.get(path, query, options);
  } };
  const { call } = client({ api: flaky });
  const result = await call("get_token", { chain: "monad", contract: TOKEN });
  assert.equal(result.structuredContent.risk.level, "high");
});

test("deskApi asks again once when the answer is a held copy over two minutes old", async () => {
  const answers = [
    { refreshing: true, observedAt: 1_000_000, value: "old" },
    { observedAt: 1_300_000, value: "new" },
  ];
  const seen = [];
  const fetchImpl = async (url) => { seen.push(url); return new Response(JSON.stringify(answers.shift())); };
  const get = deskApi({ base: "https://desk.test", fetchImpl, pause: async () => {}, now: () => 1_300_000 });
  assert.equal((await get("/api/x", { a: "1" })).value, "new");
  assert.equal(seen.length, 2);

  const recent = [{ refreshing: true, observedAt: 1_290_000, value: "recent" }];
  const once = deskApi({ base: "https://desk.test", fetchImpl: async () => new Response(JSON.stringify(recent.shift())), pause: async () => {}, now: () => 1_300_000 });
  assert.equal((await once("/api/x")).value, "recent", "a copy under two minutes old is used as it is");
});

test("a wallet found by name leads with that name and keeps its other name", async () => {
  const { call } = client();
  const asked = await call("get_wallet", { wallet: "@desky" });
  assert.equal(asked.structuredContent.askedAs, "@desky");
  assert.equal(asked.structuredContent.name, "frank.nad");
  assert.match(asked.content[0].text, /^@desky \(0x1{40}, also known as frank\.nad\)/);
  const bare = await call("get_wallet", { wallet: "desky" });
  assert.equal(bare.structuredContent.askedAs, "@desky", "a bare Desk username reads as @name");
  const same = await call("get_wallet", { wallet: "frank.nad" });
  assert.equal(same.structuredContent.askedAs, null, "no second name when the asked name is the wallet's own");
  const direct = await call("get_wallet", { wallet: WALLET });
  assert.equal(direct.structuredContent.askedAs, null);
});

test("the wallet tool tells the model that Desk usernames work", async () => {
  const { rpc } = client();
  const { result } = await rpc("tools/list");
  const wallet = result.tools.find((t) => t.name === "get_wallet");
  assert.match(wallet.inputSchema.properties.wallet.description, /Desk username such as @frank/);
  assert.match(wallet.inputSchema.properties.wallet.description, /Don't add \.eth or \.nad/);
  assert.match(INSTRUCTIONS, /Desk username/);
});
