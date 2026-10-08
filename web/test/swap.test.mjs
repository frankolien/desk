import assert from "node:assert/strict";
import { test } from "node:test";

import { ALLOWANCE_HOLDER, AUSD, sideFor, swapRefusal, swapTransaction, summarizeSwap } from "../api/swap-quote.mjs";

const WEI = "500000000000000000000";
const DATA = "0x2213bc0b" + "00".repeat(32 * 5) + "ab".repeat(40);

function zeroX(overrides = {}, transaction = {}) {
  return {
    liquidityAvailable: true,
    sellToken: "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", buyToken: AUSD,
    sellAmount: WEI, buyAmount: "12280168", minBuyAmount: "12157366",
    totalNetworkFee: "45114912500000000",
    route: { fills: [{ source: "PancakeSwap_V3" }, { source: "PancakeSwap_V3" }] },
    transaction: { to: "0x0000000000001fF3684f28c67538d4D072C22734", data: DATA, value: WEI, gas: "300000", ...transaction },
    ...overrides,
  };
}

test("a live 0x answer selling exactly the typed MON to the holder is accepted", () => {
  const tx = swapTransaction(zeroX(), WEI);
  assert.deepEqual(tx, { chainId: 143, to: "0x0000000000001fF3684f28c67538d4D072C22734", data: DATA, value: WEI });
});

test("anything that is not that one call is refused", () => {
  assert.equal(swapTransaction(zeroX({}, { to: "0x4cd00e387622c35bddb9b4c962c136462338bc31" }), WEI), null);
  assert.equal(swapTransaction(zeroX({}, { to: "0x2e73afeb01595831a67e9e1a56e193b93331b8c7" }), WEI), null);
  assert.equal(swapTransaction(zeroX({}, { value: "500000000000000000001" }), WEI), null);
  assert.equal(swapTransaction(zeroX({ sellAmount: "1" }), WEI), null);
  assert.equal(swapTransaction(zeroX({ buyToken: "0x1111111111111111111111111111111111111111" }), WEI), null);
  assert.equal(swapTransaction(zeroX({ sellToken: AUSD }), WEI), null);
  assert.equal(swapTransaction(zeroX({ liquidityAvailable: false }), WEI), null);
  assert.equal(swapTransaction(zeroX({ buyAmount: "0" }), WEI), null);
  assert.equal(swapTransaction(zeroX({ minBuyAmount: undefined }), WEI), null);
  assert.equal(swapTransaction(zeroX({}, { data: "0x" }), WEI), null);
  assert.equal(swapTransaction(undefined, WEI), null);
});

test("the summary carries readable figures, the floor, the fee and the route", () => {
  const quote = zeroX();
  const out = summarizeSwap(quote, swapTransaction(quote, WEI), WEI);
  assert.equal(out.pay.amount, "500");
  assert.equal(out.pay.wei, WEI);
  assert.equal(out.receive.amount, "12.280168");
  assert.equal(out.receive.minimum, "12.157366");
  assert.equal(out.receive.symbol, "AUSD");
  assert.equal(out.feeMON, "0.0451149125");
  assert.deepEqual(out.sources, ["PancakeSwap_V3"]);
  assert.equal(out.transaction.to.toLowerCase(), ALLOWANCE_HOLDER);
});

const RAW_AUSD = "12500000";
const NATIVE = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

function zeroXBack(overrides = {}, transaction = {}) {
  return {
    liquidityAvailable: true,
    sellToken: AUSD, buyToken: NATIVE,
    sellAmount: RAW_AUSD, buyAmount: "508000000000000000000", minBuyAmount: "502920000000000000000",
    totalNetworkFee: "45114912500000000",
    route: { fills: [{ source: "PancakeSwap_V3" }] },
    transaction: { to: "0x0000000000001fF3684f28c67538d4D072C22734", data: DATA, value: "0", gas: "300000", ...transaction },
    ...overrides,
  };
}

test("selling AUSD for MON is the same call to the holder with nothing sent along, for exactly the typed AUSD", () => {
  const tx = swapTransaction(zeroXBack(), RAW_AUSD, "AUSD");
  assert.deepEqual({ ...tx, to: tx.to.toLowerCase() }, { chainId: 143, to: ALLOWANCE_HOLDER, data: DATA, value: "0" });
  assert.equal(swapTransaction(zeroXBack({}, { value: undefined }), RAW_AUSD, "AUSD").value, "0");
  assert.equal(swapTransaction(zeroXBack({}, { value: "1" }), RAW_AUSD, "AUSD"), null);
  assert.equal(swapTransaction(zeroXBack({ sellAmount: "1" }), RAW_AUSD, "AUSD"), null);
  assert.equal(swapTransaction(zeroXBack({ sellToken: NATIVE }), RAW_AUSD, "AUSD"), null);
  assert.equal(swapTransaction(zeroXBack({ buyToken: AUSD }), RAW_AUSD, "AUSD"), null);
  assert.equal(swapTransaction(zeroXBack({}, { to: "0x4cd00e387622c35bddb9b4c962c136462338bc31" }), RAW_AUSD, "AUSD"), null);
  // Each direction's rule refuses the other direction's quote, and an unknown side refuses everything.
  assert.equal(swapTransaction(zeroXBack(), RAW_AUSD, "MON"), null);
  assert.equal(swapTransaction(zeroX(), WEI, "AUSD"), null);
  assert.equal(swapTransaction(zeroXBack(), RAW_AUSD, "USDC"), null);
});

test("the reverse summary pays AUSD, receives MON, and names the approval the app makes first", () => {
  const quote = zeroXBack();
  const out = summarizeSwap(quote, swapTransaction(quote, RAW_AUSD, "AUSD"), RAW_AUSD, "AUSD");
  assert.deepEqual(out.pay, { amount: "12.5", raw: RAW_AUSD, symbol: "AUSD" });
  assert.deepEqual(out.receive, { amount: "508", minimum: "502.92", symbol: "MON" });
  assert.equal(out.feeMON, "0.0451149125");
  assert.deepEqual(out.approval, { token: AUSD, spender: ALLOWANCE_HOLDER, amount: RAW_AUSD });
  assert.equal(out.transaction.value, "0");
  assert.equal(summarizeSwap(zeroX(), swapTransaction(zeroX(), WEI), WEI).approval, undefined);
});

const CHOG = "0xE0590015A873bF326bd645c3E1266d4db41C4E6B";

test("any Monad token has a side against MON, once its decimals are known", () => {
  const buy = sideFor("MON", CHOG, 18, "CHOG");
  assert.deepEqual(buy, { sellToken: NATIVE, buyToken: CHOG.toLowerCase(), sellDecimals: 18, buyDecimals: 18, sells: "MON", buys: "CHOG" });
  const sell = sideFor("TOKEN", CHOG, 18, "CHOG");
  assert.equal(sell.sellToken, CHOG.toLowerCase());
  assert.equal(sell.buys, "MON");
  assert.equal(sideFor("MON", CHOG, null), null);
  assert.equal(sideFor("MON", NATIVE, 18), null);
  assert.equal(sideFor("AUSD", CHOG, 18), null);
  assert.equal(sideFor("MON", "nope", 18), null);
});

test("buying a token with MON is checked and summarized like AUSD", () => {
  const side = sideFor("MON", CHOG, 18, "CHOG");
  const quote = zeroX({ buyToken: CHOG, buyAmount: "4200000000000000000000", minBuyAmount: "4158000000000000000000" });
  const tx = swapTransaction(quote, WEI, side);
  assert.equal(tx?.value, WEI);
  assert.equal(swapTransaction(zeroX({ buyToken: AUSD }), WEI, side), null);
  const out = summarizeSwap(quote, tx, WEI, side);
  assert.equal(out.pay.symbol, "MON");
  assert.equal(out.pay.wei, WEI);
  assert.equal(out.receive.amount, "4200");
  assert.equal(out.receive.symbol, "CHOG");
  assert.equal(out.approval, undefined);
});

test("selling a token approves exactly the typed amount to the holder", () => {
  const side = sideFor("TOKEN", CHOG, 18, "CHOG");
  const raw = "4200000000000000000000";
  const quote = zeroX({ sellToken: CHOG, buyToken: NATIVE, sellAmount: raw, buyAmount: "490000000000000000000", minBuyAmount: "485100000000000000000" }, { value: "0" });
  const tx = swapTransaction(quote, raw, side);
  assert.equal(tx?.value, "0");
  assert.equal(swapTransaction(zeroX({ sellToken: CHOG, buyToken: NATIVE, sellAmount: raw }, { value: raw }), raw, side), null);
  const out = summarizeSwap(quote, tx, raw, side);
  assert.equal(out.pay.symbol, "CHOG");
  assert.equal(out.pay.raw, raw);
  assert.equal(out.receive.symbol, "MON");
  assert.deepEqual(out.approval, { token: CHOG.toLowerCase(), spender: ALLOWANCE_HOLDER, amount: raw });
});

test("a refusal says which rule the answer broke", () => {
  assert.equal(swapRefusal(zeroX(), WEI), null);
  assert.equal(swapRefusal(zeroX({}, { to: "0x4cd00e387622c35bddb9b4c962c136462338bc31" }), WEI), "routes through 0x4cd00e387622c35bddb9b4c962c136462338bc31 instead of the allowance holder");
  assert.equal(swapRefusal(zeroX({}, { value: "1" }), WEI), `carries 1 instead of ${WEI}`);
  assert.equal(swapRefusal(zeroX({ buyToken: "0x1111111111111111111111111111111111111111" }), WEI), `buys 0x1111111111111111111111111111111111111111 instead of ${AUSD}`);
  assert.equal(swapRefusal(zeroX({ liquidityAvailable: false }), WEI), "no liquidity");
});

const WMON = "0x3bd359c1119da7da1d913d1c4d2b7c461115433a";

test("wrapped MON is the one route that may skip the holder: deposit in, withdraw out", () => {
  const buy = sideFor("MON", WMON, 18, "WMON");
  const wrap = zeroX({ buyToken: WMON, buyAmount: WEI, minBuyAmount: WEI }, { to: WMON, data: "0xd0e30db0" + "ab".repeat(16) });
  assert.equal(swapTransaction(wrap, WEI, buy)?.to, WMON);
  assert.equal(summarizeSwap(wrap, swapTransaction(wrap, WEI, buy), WEI, buy).approval, undefined);
  assert.equal(swapTransaction(zeroX({ buyToken: WMON, buyAmount: WEI, minBuyAmount: WEI }, { to: WMON, data: "0xa9059cbb" + "00".repeat(64) }), WEI, buy), null);
  assert.equal(swapTransaction(zeroX({ buyToken: WMON, buyAmount: WEI, minBuyAmount: WEI }, { to: "0x1111111111111111111111111111111111111111", data: "0xd0e30db0" }), WEI, buy), null);
  const sell = sideFor("TOKEN", WMON, 18, "WMON");
  const unwrap = zeroX({ sellToken: WMON, buyToken: NATIVE, sellAmount: WEI, buyAmount: WEI, minBuyAmount: WEI }, { to: WMON, data: "0x2e1a7d4d" + BigInt(WEI).toString(16).padStart(64, "0"), value: "0" });
  const tx = swapTransaction(unwrap, WEI, sell);
  assert.equal(tx?.to, WMON);
  assert.equal(summarizeSwap(unwrap, tx, WEI, sell).approval, undefined);
  assert.equal(swapRefusal(zeroX({ buyToken: WMON }, { to: WMON, data: "0xa9059cbb" + "00".repeat(64) }), WEI, buy), `routes through ${WMON} instead of the allowance holder`);
});
