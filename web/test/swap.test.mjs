import assert from "node:assert/strict";
import { test } from "node:test";

import { ALLOWANCE_HOLDER, AUSD, swapTransaction, summarizeSwap } from "../api/swap-quote.mjs";

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
