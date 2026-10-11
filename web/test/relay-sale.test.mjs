import assert from "node:assert/strict";
import { test } from "node:test";
import { keccak256 } from "viem";

import { CALIBUR, RELAY_ROUTER, createHandler, executeCalldata, saleCalls, summarizeSale } from "../api/relay-quote.mjs";

const USER = "0xb63b7c1c8b5f3b1e4f0a1a2b3c4d5e6f7a8b4c97";
const TOKEN = "0x01e6bd233f7021e4f5698a3ae44242b76a246c0a";
const RAW = "3000000000000000000000";
const AUSD = "0x00000000efe302beaa2b3e6e1b18d08d69a9012a";
const REQUEST = "0x" + "ab".repeat(32);
const APPROVE = "0x095ea7b3" + "0".repeat(24) + RELAY_ROUTER.slice(2) + "0".repeat(46) + "a2a15d09519be00000";
const DEPOSIT = "0xf9e4bab4" + "ab".repeat(96);

function relayQuote(overrides = {}) {
  return {
    steps: [
      { id: "approve", kind: "transaction", requestId: REQUEST, items: [{ status: "incomplete", data: { chainId: 8453, to: TOKEN, data: APPROVE, value: "0" } }] },
      { id: "deposit", kind: "transaction", requestId: REQUEST, items: [{ status: "incomplete", data: { chainId: 8453, to: RELAY_ROUTER, data: DEPOSIT, value: "0" } }] },
    ],
    fees: { gas: { amountUsd: "0.008" }, relayer: { amountUsd: "0.0219" } },
    details: {
      currencyIn: { currency: { chainId: 8453, address: TOKEN, symbol: "PENGU", decimals: 18 }, amountFormatted: "3000", amountUsd: "0.0054" },
      currencyOut: { currency: { chainId: 143, address: AUSD, symbol: "AUSD", decimals: 6 }, amountFormatted: "0.005397", amountUsd: "0.005397", minimumAmount: "5128" },
      timeEstimate: 1,
    },
    ...overrides,
  };
}

test("a sale is Relay's approval and deposit, both to the router, and nothing else", () => {
  const calls = saleCalls(relayQuote(), "8453", TOKEN, RAW);
  assert.deepEqual(calls, [{ to: TOKEN, value: "0", data: APPROVE }, { to: RELAY_ROUTER, value: "0", data: DEPOSIT }]);
  const withCalls = (items) => relayQuote({ steps: items.map((data, index) => ({ id: String(index), kind: "transaction", requestId: REQUEST, items: [{ data }] })) });
  assert.equal(saleCalls(withCalls([{ chainId: 8453, to: TOKEN, data: APPROVE, value: "0" }]), "8453", TOKEN, RAW), null);
  assert.equal(saleCalls(withCalls([{ chainId: 8453, to: TOKEN, data: APPROVE, value: "0" }, { chainId: 8453, to: RELAY_ROUTER, data: DEPOSIT, value: "1" }]), "8453", TOKEN, RAW), null);
  assert.equal(saleCalls(withCalls([{ chainId: 8453, to: TOKEN, data: APPROVE, value: "0" }, { chainId: 8453, to: "0x1111111111111111111111111111111111111111", data: DEPOSIT, value: "0" }]), "8453", TOKEN, RAW), null);
  assert.equal(saleCalls(withCalls([{ chainId: 1, to: TOKEN, data: APPROVE, value: "0" }, { chainId: 1, to: RELAY_ROUTER, data: DEPOSIT, value: "0" }]), "8453", TOKEN, RAW), null);
  assert.equal(saleCalls(relayQuote(), "8453", TOKEN, "3000000000000000000001"), null);
  const permit = relayQuote({ steps: [{ id: "authorize1", kind: "signature", requestId: REQUEST, items: [{ data: {} }] }] });
  assert.equal(saleCalls(permit, "8453", TOKEN, RAW), null);
  const elsewhere = relayQuote({ details: { ...relayQuote().details, currencyOut: { currency: { chainId: 143, address: "0x0000000000000000000000000000000000000000" } } } });
  assert.equal(saleCalls(elsewhere, "8453", TOKEN, RAW), null);
});

test("the sale summary carries the calls, the AUSD arriving and the account's state", () => {
  const quote = relayQuote();
  const out = summarizeSale(quote, saleCalls(quote, "8453", TOKEN, RAW), RAW, 18, "PENGU", { delegated: false, authorizationNonce: 12, batchNonce: "0" });
  assert.equal(out.requestId, REQUEST);
  assert.equal(out.chainId, 8453);
  assert.deepEqual(out.pay, { amount: "3000", raw: RAW, symbol: "PENGU", usd: "0.0054" });
  assert.deepEqual(out.receive, { amount: "0.005397", minimum: "0.005128", usd: "0.005397", symbol: "AUSD" });
  assert.equal(out.feeUsd, "0.03");
  assert.deepEqual(out.account, { delegated: false, authorizationNonce: 12, batchNonce: "0" });
});

test("Calibur's execute call data matches viem's encoding of the same batch", () => {
  const calls = [{ to: TOKEN, value: "0", data: APPROVE }, { to: RELAY_ROUTER, value: "0", data: DEPOSIT }];
  const data = executeCalldata({ calls, nonce: "7", signature: "0x" + "11".repeat(32) + "22".repeat(32) + "1b" });
  assert.equal(data.length, 2250);
  assert.equal(data.slice(0, 10), "0xc3c16ee4");
  assert.equal(keccak256(data), "0x7fbc1c46b61f9fa86baf574ecd40fdef0b3a29181336667f05980df4b4c1bb79");
});

function response() {
  const out = { statusCode: 200, body: null, headers: {} };
  out.status = (code) => { out.statusCode = code; return out; };
  out.json = (body) => { out.body = body; return out; };
  out.setHeader = (name, value) => { out.headers[name] = value; };
  return out;
}

test("execute forwards the signed batch and the authorization to Relay under the key", async () => {
  const previous = process.env.RELAY_API_KEY;
  process.env.RELAY_API_KEY = "test-key";
  const sent = [];
  const handler = createHandler(async (url, init) => {
    sent.push({ url, init });
    return { ok: true, status: 200, json: async () => ({ requestId: REQUEST }) };
  });
  const res = response();
  const body = { chainId: 8453, user: USER, requestId: REQUEST, calls: [{ to: TOKEN, value: "0", data: APPROVE }, { to: RELAY_ROUTER, value: "0", data: DEPOSIT }], batchNonce: "7", signature: "0x" + "11".repeat(32) + "22".repeat(32) + "1b", authorization: { nonce: 12, yParity: 1, r: "0x" + "33".repeat(32), s: "0x" + "44".repeat(32) } };
  await handler({ method: "POST", query: { view: "execute" }, body, url: "/api/relay-quote?view=execute" }, res);
  assert.equal(res.statusCode, 200, JSON.stringify(res.body));
  assert.deepEqual(res.body, { requestId: REQUEST });
  assert.equal(sent[0].url, "https://api.relay.link/execute");
  assert.equal(sent[0].init.headers["x-api-key"], "test-key");
  const payload = JSON.parse(sent[0].init.body);
  assert.equal(payload.executionKind, "rawCalls");
  assert.equal(payload.data.to, USER);
  assert.equal(payload.data.value, "0");
  assert.equal(payload.data.data.slice(0, 10), "0xc3c16ee4");
  assert.deepEqual(payload.data.authorizationList, [{ chainId: 8453, address: CALIBUR, nonce: 12, yParity: 1, r: "0x" + "33".repeat(32), s: "0x" + "44".repeat(32) }]);
  assert.equal(payload.requestId, REQUEST);
  assert.equal(payload.executionOptions.subsidizeFees, false);

  // Already delegated: no authorization rides along. A bad field never reaches Relay.
  sent.length = 0;
  await handler({ method: "POST", query: { view: "execute" }, body: { ...body, authorization: undefined }, url: "" }, response());
  assert.equal(JSON.parse(sent[0].init.body).data.authorizationList, undefined);
  for (const bad of [{ chainId: 143 }, { signature: "0x12" }, { calls: body.calls.slice(0, 1) }, { authorization: { nonce: -1, yParity: 0, r: "0x", s: "0x" } }, { batchNonce: "x" }]) {
    sent.length = 0;
    const r = response();
    await handler({ method: "POST", query: { view: "execute" }, body: { ...body, ...bad }, url: "" }, r);
    assert.equal(r.statusCode, 400, JSON.stringify(bad));
    assert.equal(sent.length, 0);
  }
  const get = response();
  await handler({ method: "GET", query: { view: "execute" }, url: "" }, get);
  assert.equal(get.statusCode, 405);
  process.env.RELAY_API_KEY = "";
  const off = response();
  await handler({ method: "POST", query: { view: "execute" }, body, url: "" }, off);
  assert.equal(off.statusCode, 503);
  if (previous === undefined) delete process.env.RELAY_API_KEY; else process.env.RELAY_API_KEY = previous;
});
