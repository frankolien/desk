/// Headlines from a few crypto newsrooms' RSS feeds, tagged with the Perpl markets they
/// mention. No keys, no third-party news API: the feeds are public and the parsing is
/// a page of regular expressions, because RSS items are flat.
export const FEEDS = [
  { source: "CoinDesk", url: "https://www.coindesk.com/arc/outboundfeeds/rss/" },
  { source: "Cointelegraph", url: "https://cointelegraph.com/rss" },
  { source: "Decrypt", url: "https://decrypt.co/feed" },
  { source: "The Block", url: "https://www.theblock.co/rss.xml" },
];

/// What a headline has to say to be about a market. Whole words, case-insensitive.
export const MENTIONS = {
  BTC: ["bitcoin", "btc"],
  ETH: ["ethereum", "ether", "eth"],
  SOL: ["solana", "sol"],
  MON: ["monad", "mon"],
  HYPE: ["hyperliquid", "hype"],
  ZEC: ["zcash", "zec"],
  LIT: ["lighter"],
  PUMP: ["pump.fun", "pumpfun", "pump"],
  VVV: ["venice", "vvv"],
};

export const NEWS_CAP = 40;
export const NEWS_KEY = "news:items";
export const NEWS_TTL_SECONDS = 300;

const tag = (name, xml) => xml.match(new RegExp(`<${name}(?:\\s[^>]*)?>([\\s\\S]*?)</${name}>`, "i"))?.[1] ?? "";
const attribute = (name, xml) => xml.match(new RegExp(`<${name}\\s[^>]*?url="([^"]+)"`, "i"))?.[1] ?? null;

export function decodeEntities(text) {
  return String(text ?? "")
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")
    .replace(/<[^>]+>/g, "")
    .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'").replace(/&nbsp;/g, " ")
    .replace(/&#(\d+);/g, (_, code) => String.fromCodePoint(Number(code)))
    .replace(/\s+/g, " ").trim();
}

export function mentions(text) {
  const lower = ` ${String(text ?? "").toLowerCase()} `;
  return Object.entries(MENTIONS)
    .filter(([, words]) => words.some((word) => new RegExp(`[^a-z0-9]${word.replace(".", "\\.")}[^a-z0-9]`).test(lower)))
    .map(([symbol]) => symbol);
}

/// The items in one feed, newest first; anything without a title, link and date is skipped.
export function parseFeed(xml, source) {
  const items = [];
  for (const match of String(xml ?? "").matchAll(/<item>([\s\S]*?)<\/item>/gi)) {
    const item = match[1];
    const title = decodeEntities(tag("title", item));
    const url = decodeEntities(tag("link", item)) || null;
    const publishedAt = Date.parse(decodeEntities(tag("pubDate", item)));
    if (!title || !url || !Number.isFinite(publishedAt)) continue;
    const image = attribute("media:content", item) ?? attribute("enclosure", item);
    const summary = decodeEntities(tag("description", item)).slice(0, 280);
    items.push({
      title, url, source, publishedAt,
      image: image ? decodeEntities(image) : null,
      symbols: mentions(`${title} ${summary}`),
    });
  }
  return items;
}

export function merge(lists, now = Date.now()) {
  const seen = new Set();
  return lists.flat()
    .filter((item) => item.publishedAt <= now + 60_000)
    .sort((a, b) => b.publishedAt - a.publishedAt)
    .filter((item) => { const key = item.url.toLowerCase(); if (seen.has(key)) return false; seen.add(key); return true; })
    .slice(0, NEWS_CAP);
}

async function fetchFeed(feed, fetchImpl) {
  try {
    const response = await fetchImpl(feed.url, {
      headers: { "user-agent": "Desk/1.0 (+https://trydesk.trade)", accept: "application/rss+xml, application/xml, text/xml" },
      signal: AbortSignal.timeout(6_000),
    });
    if (!response.ok) return [];
    return parseFeed(await response.text(), feed.source);
  } catch {
    return [];
  }
}

/// The merged headlines, from the store when they are fresh and from the feeds when not.
export async function headlines({ store, fetchImpl = fetch, feeds = FEEDS, now = Date.now() } = {}) {
  if (store) {
    const cached = await store.get(NEWS_KEY).catch(() => null);
    if (cached) { try { return JSON.parse(cached); } catch {} }
  }
  const items = merge(await Promise.all(feeds.map((feed) => fetchFeed(feed, fetchImpl))), now);
  if (store && items.length) await store.set(NEWS_KEY, JSON.stringify(items), { ex: NEWS_TTL_SECONDS }).catch(() => {});
  return items;
}

/// Only the headlines that mention one of the asked-for markets, or all of them.
export function filter(items, symbols) {
  const wanted = String(symbols ?? "").split(",").map((s) => s.trim().toUpperCase()).filter(Boolean);
  if (!wanted.length) return items;
  return items.filter((item) => item.symbols.some((symbol) => wanted.includes(symbol)));
}
