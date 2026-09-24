// node --test web/test/news.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import { decodeEntities, filter, headlines, mentions, merge, NEWS_KEY, parseFeed } from "../api/_news.mjs";
import { memoryStore } from "../api/_store.mjs";

const FEED = `<?xml version="1.0"?><rss><channel>
<item><title><![CDATA[Bitcoin &amp; Ether Slip as Traders Await Fed]]></title><link>https://x.test/a</link>
<pubDate>Thu, 24 Sep 2026 15:48:20 +0000</pubDate>
<media:content url="https://img.test/a.jpg?w=1&amp;h=2" type="image/*"/><description>BTC fell 2%.</description></item>
<item><title>Monad ecosystem adds a perps venue</title><link>https://x.test/b</link>
<pubDate>Thu, 24 Sep 2026 16:00:00 +0000</pubDate><enclosure url="https://img.test/b.png" type="image/png"/>
<description><![CDATA[<p>Perpl on <b>Monad</b> passes $1M open interest.</p>]]></description></item>
<item><title>No date here</title><link>https://x.test/c</link></item>
<item><title>Monday market wrap</title><link>https://x.test/d</link><pubDate>Thu, 24 Sep 2026 12:00:00 +0000</pubDate></item>
</channel></rss>`;

test("entities and tags come out as plain text", () => {
  assert.equal(decodeEntities("<![CDATA[Bitcoin &amp; Ether &#8217;s <b>day</b>]]>"), "Bitcoin & Ether ’s day");
});

test("mentions are whole words, so Monday is not Monad and solid is not SOL", () => {
  assert.deepEqual(mentions("Bitcoin & Ether slip"), ["BTC", "ETH"]);
  assert.deepEqual(mentions("Monday market wrap: solid gains"), []);
  assert.deepEqual(mentions("Pump.fun token PUMP rallies on Solana"), ["SOL", "PUMP"]);
  assert.deepEqual(mentions("Monad passes a milestone"), ["MON"]);
});

test("a feed parses to tagged items, newest first, skipping items without a date", () => {
  const items = merge([parseFeed(FEED, "Test")], Date.parse("2026-09-24T18:00:00Z"));
  assert.deepEqual(items.map((item) => item.url), ["https://x.test/b", "https://x.test/a", "https://x.test/d"]);
  assert.equal(items[0].image, "https://img.test/b.png");
  assert.deepEqual(items[0].symbols, ["MON"]);
  assert.equal(items[1].title, "Bitcoin & Ether Slip as Traders Await Fed");
  assert.equal(items[1].image, "https://img.test/a.jpg?w=1&h=2");
  assert.deepEqual(items[1].symbols, ["BTC", "ETH"]);
  assert.equal(items[1].source, "Test");
  assert.deepEqual(items[2].symbols, []);
});

test("the same story from two feeds appears once, and the filter keeps only asked-for markets", () => {
  const a = parseFeed(FEED, "A");
  const b = parseFeed(FEED, "B");
  const items = merge([a, b], Date.parse("2026-09-24T18:00:00Z"));
  assert.equal(items.length, 3);
  assert.deepEqual(filter(items, "btc").map((item) => item.url), ["https://x.test/a"]);
  assert.deepEqual(filter(items, " mon , BTC").map((item) => item.url), ["https://x.test/b", "https://x.test/a"]);
  assert.equal(filter(items, "").length, 3);
});

test("headlines are fetched once and served from the store until they expire", async () => {
  const store = memoryStore();
  let fetches = 0;
  const fetchImpl = async () => { fetches += 1; return { ok: true, text: async () => FEED }; };
  const feeds = [{ source: "A", url: "https://a.test/rss" }, { source: "B", url: "https://b.test/rss" }];
  const first = await headlines({ store, fetchImpl, feeds, now: Date.parse("2026-09-24T18:00:00Z") });
  assert.equal(fetches, 2);
  assert.equal(first.length, 3);
  assert.ok(store.values.has(NEWS_KEY));
  const second = await headlines({ store, fetchImpl, feeds });
  assert.equal(fetches, 2);
  assert.deepEqual(second, first);
});

test("a feed that fails or times out contributes nothing rather than failing the page", async () => {
  const fetchImpl = async (url) => (url.includes("bad") ? { ok: false } : { ok: true, text: async () => FEED });
  const items = await headlines({ fetchImpl, feeds: [{ source: "Bad", url: "https://bad.test" }, { source: "Good", url: "https://good.test" }], now: Date.parse("2026-09-24T18:00:00Z") });
  assert.equal(items.length, 3);
  assert.ok(items.every((item) => item.source === "Good"));
});
