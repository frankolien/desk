// node --test web/test/fx.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import { CURRENCIES, createHandler, pickRates } from "../api/fx.mjs";

function recorder() {
  const out = { status: null, body: null, headers: {} };
  return {
    status(code) { out.status = code; return this; },
    json(value) { out.body = value; return out; },
    setHeader(key, value) { out.headers[key] = value; },
  };
}

const full = Object.fromEntries(CURRENCIES.map((code, index) => [code, code === "USD" ? 1 : index + 0.5]));

test("every supported currency must be present and positive", () => {
  assert.deepEqual(pickRates({ result: "success", rates: { ...full, XYZ: 9 } }), full);
  assert.equal(pickRates({ result: "success", rates: { ...full, NGN: 0 } }), null);
  const { EUR, ...missing } = full;
  assert.equal(pickRates({ result: "success", rates: missing }), null);
  assert.equal(pickRates({ result: "error", rates: full }), null);
  assert.equal(pickRates({ result: "success", rates: { ...full, USD: 1.2 } }), null);
});

test("rates are served with an hour of edge caching, and outages as 502", async () => {
  const ok = await createHandler(async () => ({
    ok: true, json: async () => ({ result: "success", time_last_update_unix: 1789603351, rates: full }),
  }))({ method: "GET" }, recorder());
  assert.equal(ok.status, 200);
  assert.equal(ok.body.rates.NGN, full.NGN);
  assert.equal(ok.body.updatedAt, 1789603351000);
  assert.match(ok.headers["Cache-Control"], /s-maxage=3600/);
  const down = await createHandler(async () => { throw new Error("down"); })({ method: "GET" }, recorder());
  assert.equal(down.status, 502);
});
