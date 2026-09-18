// node --test web/test/relay.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import { isBuyable } from "../api/_chains.mjs";
import { createHandler, depositTransaction, matchesRoute } from "../api/relay-quote.mjs";
import { createHandler as createStatus, phase } from "../api/relay-status.mjs";

const USER = "0x03508bb71268bba25ecacc8f620e01866650532c";
const TOKEN = "0x532f27101965dd16442e59d40670faf5ebb142e4";
const WEI = "20000000000000000000";
const DATA = `0x49290c1c${USER.slice(2).padStart(64, "0")}${"ab".repeat(32)}`;

function recorder() {
  const out = { status: null, body: null };
  return {
    status(code) { out.status = code; return this; },
    json(value) { out.body = value; return out; },
    setHeader() {},
  };
}

function relayQuote(overrides = {}) {
  return {
    steps: [{
      id: "deposit", kind: "transaction", requestId: `0x${"12".repeat(32)}`,
      items: [{ data: { chainId: 143, to: "0x4cD00E387622C35bDDB9b4c962C136462338BC31", data: DATA, value: WEI, ...overrides } }],
    }],
    fees: { gas: { amountUsd: "0.0001" }, relayer: { amountUsd: "0.0974" } },
    details: {
      currencyIn: { amountFormatted: "20.0", amountUsd: "0.45",
        currency: { chainId: 143, address: "0x0000000000000000000000000000000000000000", symbol: "MON", decimals: 18 } },
      currencyOut: { amountFormatted: "77.2", amountUsd: "0.37", minimumAmount: "73678516499071562493",
        currency: { chainId: 8453, address: TOKEN, symbol: "BRETT", decimals: 18 } },
      totalImpact: { percent: "-18.97" }, timeEstimate: 2,
    },
  };
}

const respond = (status, body) => async () => ({ ok: status < 300, status, json: async () => body });
const quote = (fetchImpl, query = {}) => createHandler(fetchImpl)(
  { method: "GET", query: { user: USER, chainIndex: "8453", tokenAddress: TOKEN, amount: "20", ...query } }, recorder());

test("a quote that pays out a different token or chain is refused", () => {
  const routed = (currencyOut, currencyIn) => ({ details: { currencyOut: { currency: currencyOut }, currencyIn: { currency: currencyIn } } });
  const native = { chainId: 143, address: "0x0000000000000000000000000000000000000000" };
  const want = { chainId: 8453, address: "0xAbCdef0000000000000000000000000000000001" };

  assert.equal(matchesRoute(routed(want, native), "8453", want.address), true);
  // Case is not identity: the same token in a different spelling still matches.
  assert.equal(matchesRoute(routed(want, native), "8453", want.address.toLowerCase()), true);
  // A different token on the right chain, and the right token on a different chain.
  assert.equal(matchesRoute(routed({ ...want, address: "0x9999999999999999999999999999999999999999" }, native), "8453", want.address), false);
  assert.equal(matchesRoute(routed({ ...want, chainId: 1 }, native), "8453", want.address), false);
  // Paying with something other than MON on Monad.
  assert.equal(matchesRoute(routed(want, { chainId: 1, address: native.address }), "8453", want.address), false);
  assert.equal(matchesRoute({ details: {} }, "8453", want.address), false);
});

test("a single native deposit crediting the user is summarised", async () => {
  const result = await quote(respond(200, relayQuote()));
  assert.equal(result.status, 200);
  assert.equal(result.body.receive.minimum, "73.678516499071562493");
  assert.equal(result.body.feeUsd, "0.1");
  assert.deepEqual(result.body.transaction, { chainId: 143, to: "0x4cD00E387622C35bDDB9b4c962C136462338BC31", data: DATA, value: WEI });
});

test("a quote whose payout is not the token that was asked for is refused end to end", async () => {
  const wrongToken = relayQuote();
  wrongToken.details.currencyOut.currency.address = "0x9999999999999999999999999999999999999999";
  const result = await quote(respond(200, wrongToken));
  assert.equal(result.status, 422);
  assert.equal(result.body.reason, "unsupported-route");
});

test("any other transaction shape is refused before it reaches the app", () => {
  const refused = [
    { chainId: 1 },
    { to: "0xb92fe925dc43a0ecde6c8b1a2709c170ec4fff4f" },
    { value: "20000000000000000001" },
    { data: DATA.replace(USER.slice(2), "1".repeat(40)) },
    { data: DATA.replace("49290c1c", "a9059cbb") },
    { data: `${DATA}00` },
  ];
  for (const overrides of refused) {
    assert.equal(depositTransaction(relayQuote(overrides), USER, WEI), null, JSON.stringify(overrides));
  }
  const twoSteps = relayQuote();
  twoSteps.steps.push(twoSteps.steps[0]);
  assert.equal(depositTransaction(twoSteps, USER, WEI), null);
});

test("Monad, Solana and unknown chains are not buyable", async () => {
  assert.equal(isBuyable("8453"), true);
  for (const chain of ["143", "501", "10143", "123456"]) assert.equal(isBuyable(chain), false, chain);
  const result = await quote(respond(200, relayQuote()), { chainIndex: "501" });
  assert.equal(result.status, 422);
  assert.equal(result.body.reason, "unsupported-chain");
});

test("malformed input never calls Relay", async () => {
  const never = async () => { throw new Error("called"); };
  for (const query of [{ user: "0x12" }, { tokenAddress: "So11111111111111111111111111111111111111112" }, { amount: "0" }, { amount: "1e3" }]) {
    assert.equal((await quote(never, query)).status, 400, JSON.stringify(query));
  }
});

test("Relay's error codes become reasons, and outages a 502", async () => {
  const noRoute = await quote(respond(400, { errorCode: "NO_SWAP_ROUTES_FOUND", message: "no routes found" }));
  assert.equal(noRoute.body.reason, "no-route");
  const unknown = await quote(respond(500, { errorCode: "SOMETHING_NEW" }));
  assert.equal(unknown.body.reason, "unavailable");
  const down = await quote(async () => { throw new Error("socket"); });
  assert.equal(down.status, 502);
});

test("status folds Relay's words into four phases", async () => {
  assert.equal(phase("success"), "filled");
  assert.equal(phase("refunded"), "refunded");
  assert.equal(phase("failure"), "failed");
  for (const status of ["waiting", "pending", "submitted", "delayed", undefined]) assert.equal(phase(status), "pending");
  const handler = createStatus(respond(200, { status: "success", txHashes: ["0xaa", "0xbb"] }));
  const result = await handler({ method: "GET", query: { requestId: `0x${"12".repeat(32)}` } }, recorder());
  assert.deepEqual(result.body, { phase: "filled", destinationTx: "0xbb" });
  const bad = await handler({ method: "GET", query: { requestId: "0x12" } }, recorder());
  assert.equal(bad.status, 400);
});
