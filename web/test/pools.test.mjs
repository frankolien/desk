import assert from "node:assert/strict";
import test from "node:test";
import { deeper, poolsFor, poolsOf, withPoolDepth } from "../api/_pools.mjs";
import { assessToken, handleRisk } from "../api/_risk.mjs";
import { memoryStore } from "../api/_store.mjs";

const CHOG = "0x350035555e10d9afaf1566aaebfced5ba6c27777";
const WMON = "0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A";
const NADFUN_POOL = "0x116e7D070f1888B81E1E0324F56d6746B2D7d8f1";
const FAKE_USDC = "0x9999999999999999999999999999999999999999";

const pair = (pairAddress, base, quote, usd, quoteSymbol = "MON") => ({
  pairAddress, baseToken: { address: base, symbol: "CHOG" }, quoteToken: { address: quote, symbol: quoteSymbol }, liquidity: { usd },
});

test("only pools against the chain's own coin or a major stablecoin count toward depth", () => {
  const found = poolsOf("143", CHOG, [
    pair(NADFUN_POOL, "0x350035555E10d9AfAF1566AaebfCeD5BA6C27777", WMON, 88_433.03),
    pair("0xfake00000000000000000000000000000000fake", CHOG, FAKE_USDC, 5_000_000, "USDC"),
    pair("0xother0000000000000000000000000000000other", "0x1234567890123456789012345678901234567890", WMON, 1_000),
  ]);
  assert.deepEqual(found, {
    usd: 88_433.03,
    pools: 1,
    addresses: [NADFUN_POOL.toLowerCase(), "0xfake00000000000000000000000000000000fake"],
  });
});

test("a token on the quote side of a pool counts the same way", () => {
  const found = poolsOf("143", CHOG, [{ pairAddress: "0xaa", baseToken: { address: WMON }, quoteToken: { address: CHOG }, liquidity: { usd: 12_000 } }]);
  assert.equal(found.usd, 12_000);
});

test("poolsFor batches thirty tokens a call, caches each, and skips chains it can't check", async () => {
  const store = memoryStore();
  const urls = [];
  const fetchImpl = async (url) => {
    urls.push(url);
    const tokens = url.split("/").pop().split(",");
    return new Response(JSON.stringify(tokens.map((token, i) => pair(`0xpool${i}`, token, WMON, 20_000))));
  };
  const tokens = Array.from({ length: 31 }, (_, i) => `0x${String(i).padStart(40, "0")}`);
  const first = await poolsFor("143", tokens, { fetchImpl, store });
  assert.equal(urls.length, 2);
  assert.equal(first.size, 31);
  assert.equal(first.get(tokens[0]).usd, 20_000);
  const again = await poolsFor("143", tokens.slice(0, 3), { fetchImpl, store });
  assert.equal(urls.length, 2, "cached answers aren't fetched again");
  assert.equal(again.get(tokens[2]).usd, 20_000);
  assert.equal((await poolsFor("4663", tokens.slice(0, 1), { fetchImpl })).size, 0, "no reserve list for this chain");
  const down = await poolsFor("143", ["0xabc"], { fetchImpl: async () => { throw new Error("down"); } });
  assert.equal(down.size, 0);
});

test("deeper() takes the larger figure and falls back to whichever exists", () => {
  assert.equal(deeper(6_554, { usd: 88_433 }), 88_433);
  assert.equal(deeper(741_672, { usd: 300_000 }), 741_672);
  assert.equal(deeper(null, { usd: 5_000 }), 5_000);
  assert.equal(deeper(6_554, null), 6_554);
  assert.equal(deeper(null, { usd: 0 }), null);
});

test("withPoolDepth deepens a list's liquidity and leaves the rest alone", async () => {
  const fetchImpl = async () => new Response(JSON.stringify([pair(NADFUN_POOL, CHOG, WMON, 88_433)]));
  const out = await withPoolDepth([
    { chainIndex: "143", contract: CHOG, liquidity: 6_554 },
    { chainIndex: "4663", contract: "0xabc", liquidity: 10 },
  ], { fetchImpl });
  assert.deepEqual(out.map((t) => t.liquidity), [88_433, 10]);
});

test("a pool address among the top holders isn't counted as a wallet", () => {
  const holders = [
    { address: "0xwhale1", amount: 1e8, percent: 10 },
    { address: NADFUN_POOL, amount: 3.35e7, percent: 3.3 },
    { address: "0xwhale2", amount: 6e7, percent: 6 },
  ];
  const counted = assessToken({ holders, now: 1 });
  const fixed = assessToken({ holders, poolAddresses: [NADFUN_POOL.toLowerCase()], now: 1 });
  assert.equal(Math.round(counted.metrics.topTen * 10) / 10, 19.3);
  assert.equal(fixed.metrics.topTen, 16);
  assert.equal(assessToken({ liquidity: 8_000, pools: 3, now: 1 }).reasons[0].text, "Liquidity is thin: $8.0K across 3 pools");
});

test("the risk check reads CHOG's real depth and leaves its pool out of the top ten", async () => {
  const okx = {
    post: async () => [{ liquidity: "6554.42", marketCap: "1366090", price: "0.001366" }],
    get: async (path) => path.endsWith("/holder")
      ? [
          { holderWalletAddress: "0x9b9423941e69dfc82e9a165db13cd4992c65b360", holdAmount: "100000000", holdPercent: "10" },
          { holderWalletAddress: NADFUN_POOL.toLowerCase(), holdAmount: "33533581", holdPercent: "3.3073" },
          { holderWalletAddress: "0x98ea8015355ec98f4b4b2e3abb514fdaa1a32c23", holdAmount: "60505800", holdPercent: "6.0505" },
        ]
      : [],
  };
  const pools = async () => new Map([[CHOG, { usd: 88_433.03, pools: 1, addresses: [NADFUN_POOL.toLowerCase()] }]]);
  let body;
  const res = { setHeader() {}, status() { return this; }, json(value) { body = value; return this; } };
  await handleRisk({ query: { chainIndex: "143", address: CHOG } }, res, { okx, pools, store: null, fetchImpl: async () => new Response("{}", { status: 404 }) });
  assert.equal(body.metrics.liquidity, 88_433.03);
  assert.equal(body.metrics.pools, 1);
  assert.ok(!body.reasons.some((r) => /thin|light/.test(r.code)), "$88K is neither thin nor light");
  assert.equal(Math.round(body.metrics.topTen * 100) / 100, 16.05);
});
