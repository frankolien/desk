// node --test web/test/swap.test.mjs
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
  // Another contract, including Relay's depository and the settler itself.
  assert.equal(swapTransaction(zeroX({}, { to: "0x4cd00e387622c35bddb9b4c962c136462338bc31" }), WEI), null);
  assert.equal(swapTransaction(zeroX({}, { to: "0x2e73afeb01595831a67e9e1a56e193b93331b8c7" }), WEI), null);
  // A value other than the typed amount, on either side of the answer.
  assert.equal(swapTransaction(zeroX({}, { value: "500000000000000000001" }), WEI), null);
  assert.equal(swapTransaction(zeroX({ sellAmount: "1" }), WEI), null);
  // A different token in or out.
  assert.equal(swapTransaction(zeroX({ buyToken: "0x1111111111111111111111111111111111111111" }), WEI), null);
  assert.equal(swapTransaction(zeroX({ sellToken: AUSD }), WEI), null);
  // No liquidity, nothing bought, or no floor to check against.
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
