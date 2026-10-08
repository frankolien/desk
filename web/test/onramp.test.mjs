import assert from "node:assert/strict";
import { test } from "node:test";

import { AUSD_ON_MONAD, STAGING_TOKEN, describeOrder, handleOnramp, onrampEnv, orderBody, parseDeposit, userLocator } from "../api/_onramp.mjs";

const WALLET = "0x50B240678777451BEfd67B7e8c3b4366482ba8F9";

function recorder() {
  const out = { status: null, body: null, headers: {} };
  return { out, res: { setHeader(k, v) { out.headers[k] = v; }, status(code) { out.status = code; return this; }, json(value) { out.body = value; return out; } } };
}

test("the environment follows the key, and the token follows the environment", () => {
  assert.deepEqual(onrampEnv({}), { configured: false });
  const staging = onrampEnv({ CROSSMINT_API_KEY: "sk_staging_abc" });
  assert.deepEqual([staging.environment, staging.base, staging.tokenLocator, staging.symbol, staging.test], ["staging", "https://staging.crossmint.com", STAGING_TOKEN, "USDC", true]);
  const production = onrampEnv({ CROSSMINT_API_KEY: "sk_production_abc", CROSSMINT_ENV: "staging" });
  assert.deepEqual([production.environment, production.chain, production.symbol, production.test], ["production", "monad", "AUSD", false]);
  const named = onrampEnv({ CROSSMINT_API_KEY: "weird", CROSSMINT_ENV: "production" });
  assert.equal(named.environment, "production");
  const overridden = onrampEnv({ CROSSMINT_API_KEY: "sk_staging_abc", CROSSMINT_TOKEN_LOCATOR: "base:0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" });
  assert.deepEqual([overridden.chain, overridden.symbol], ["base", "USDC"]);
});

test("a deposit is a wallet, a fiat amount to the cent within limits, a currency and maybe an email", () => {
  assert.deepEqual(parseDeposit({ wallet: WALLET, amount: 50, email: "a@b.co" }), { wallet: WALLET, amount: "50", currency: "usd", email: "a@b.co" });
  assert.match(parseDeposit({ wallet: WALLET, amount: 50 }).error, /email/);
  assert.deepEqual(parseDeposit({ wallet: WALLET, amount: "12.5", currency: "EUR", email: "A@B.co" }).email, "a@b.co");
  assert.equal(parseDeposit({ wallet: WALLET, amount: "12.5", email: "a@b.co" }).amount, "12.5");
  assert.match(parseDeposit({ wallet: "0x1", amount: 50 }).error, /wallet/);
  assert.match(parseDeposit({ wallet: WALLET, amount: 1, email: "a@b.co" }).error, /between/);
  assert.match(parseDeposit({ wallet: WALLET, amount: 2001, email: "a@b.co" }).error, /between/);
  assert.match(parseDeposit({ wallet: WALLET, amount: 10.123, email: "a@b.co" }).error, /cent/);
  assert.match(parseDeposit({ wallet: WALLET, amount: 50, currency: "ngn", email: "a@b.co" }).error, /USD or EUR/);
  assert.match(parseDeposit({ wallet: WALLET, amount: 50, email: "nope" }).error, /email/);
  assert.match(parseDeposit(null).error, /JSON/);
  assert.deepEqual(orderBody(parseDeposit({ wallet: WALLET, amount: 50, email: "a@b.co" }), AUSD_ON_MONAD), {
    recipient: { walletAddress: WALLET },
    payment: { method: "card", currency: "usd", receiptEmail: "a@b.co" },
    lineItems: [{ tokenLocator: AUSD_ON_MONAD, executionParameters: { mode: "exact-in", amount: "50" } }],
  });
});

test("an order is read as a phase, a payment, a delivery and what arrives", () => {
  const order = {
    orderId: "b2959ca5", phase: "payment",
    quote: { status: "valid", totalPrice: { amount: "52.1", currency: "usd" }, expiresAt: "2026-10-08T10:00:00Z" },
    payment: { status: "awaiting-payment" },
    lineItems: [{ quote: { quantityRange: { lowerBound: "49.2", upperBound: "50" } }, delivery: { status: "awaiting-payment" } }],
  };
  const read = describeOrder(order, "AUSD");
  assert.deepEqual(read, {
    orderId: "b2959ca5", phase: "payment", payment: "awaiting-payment", delivery: "awaiting-payment", txId: null,
    quote: { status: "valid", total: "52.1", currency: "usd", expiresAt: "2026-10-08T10:00:00Z", receive: { min: "49.2", max: "50", symbol: "AUSD" } },
    completed: false, failed: false, needsProof: false, proofMessage: null,
  });
  assert.equal(describeOrder({ ...order, phase: "completed", lineItems: [{ delivery: { status: "completed", txId: "0xabc" } }] }, "AUSD").completed, true);
  assert.equal(describeOrder({ ...order, lineItems: [{ delivery: { status: "failed" } }] }, "AUSD").failed, true);
  assert.equal(describeOrder({ ...order, payment: { status: "failed-kyc" } }, "AUSD").failed, true);
  const proof = describeOrder({ ...order, payment: { status: "requires-recipient-verification", preparation: { message: "crossmint.com wants you to sign in" } } }, "AUSD");
  assert.deepEqual([proof.needsProof, proof.proofMessage], [true, "crossmint.com wants you to sign in"]);
  assert.equal(read.needsProof, false);
});

test("the route says what is set up, opens an order with the key on the server only, and follows it", async () => {
  const env = onrampEnv({ CROSSMINT_API_KEY: "sk_staging_abc" });
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    if (init.method === "PUT") return { status: 200, json: async () => ({}) };
    if (init.method === "POST") return { status: 201, json: async () => ({ clientSecret: "cs_1", order: { orderId: "b2959ca5-65e4-466a-bd26-1bd05cb4f837", phase: "payment", quote: { totalPrice: { amount: "51", currency: "usd" } }, payment: { status: "requires-kyc" }, lineItems: [{ delivery: { status: "awaiting-payment" } }] } }) };
    return { status: 200, json: async () => ({ orderId: "b2959ca5-65e4-466a-bd26-1bd05cb4f837", phase: "completed", payment: { status: "completed" }, lineItems: [{ delivery: { status: "completed", txId: "0xdead" } }] }) };
  };

  let { out, res } = recorder();
  await handleOnramp({ method: "GET", query: {} }, res, { env, fetchImpl });
  assert.equal(out.status, 200);
  assert.deepEqual(out.body.token, { chain: "base-sepolia", symbol: "USDC" });
  assert.equal(out.body.test, true);
  assert.equal(out.body.clientKey, null);
  assert.equal(onrampEnv({ CROSSMINT_API_KEY: "sk_staging_abc", CROSSMINT_CLIENT_KEY: "ck_staging_x" }).clientKey, "ck_staging_x");
  assert.equal(out.headers["Cache-Control"], "private, no-store");

  ({ out, res } = recorder());
  await handleOnramp({ method: "POST", query: {}, body: { wallet: WALLET, amount: 50, email: "a@b.co" } }, res, { env, fetchImpl });
  assert.equal(out.status, 201);
  assert.equal(out.body.clientSecret, "cs_1");
  assert.deepEqual([out.body.order.orderId, out.body.order.payment, out.body.environment], ["b2959ca5-65e4-466a-bd26-1bd05cb4f837", "requires-kyc", "staging"]);
  // The wallet is linked to a user of Desk's naming first, on the token's chain, then the order opens.
  assert.equal(calls[0].url, `https://staging.crossmint.com/api/2025-06-09/users/${encodeURIComponent("userId:desk-" + WALLET.toLowerCase())}/linked-wallets/${WALLET}`);
  assert.deepEqual([calls[0].init.method, JSON.parse(calls[0].init.body)], ["PUT", { chain: "base-sepolia" }]);
  assert.equal(calls[1].url, "https://staging.crossmint.com/api/2022-06-09/orders");
  assert.equal(calls[1].init.headers["x-api-key"], "sk_staging_abc");
  assert.equal(JSON.parse(calls[1].init.body).recipient.walletAddress, WALLET);
  assert.equal(userLocator({ wallet: WALLET, email: "a@b.co" }), "userId:desk-" + WALLET.toLowerCase());
  assert.equal(JSON.parse(calls[1].init.body).payment.receiptEmail, "a@b.co");
  assert.equal(JSON.stringify(out.body).includes("sk_staging"), false);

  ({ out, res } = recorder());
  await handleOnramp({ method: "GET", query: { orderId: "b2959ca5-65e4-466a-bd26-1bd05cb4f837" } }, res, { env, fetchImpl });
  assert.deepEqual([out.status, out.body.completed, out.body.txId], [200, true, "0xdead"]);

  ({ out, res } = recorder());
  await handleOnramp({ method: "POST", query: {}, body: { wallet: WALLET, amount: 0.5, email: "a@b.co" } }, res, { env, fetchImpl });
  assert.equal(out.status, 400);
  ({ out, res } = recorder());
  await handleOnramp({ method: "GET", query: {} }, res, { env: onrampEnv({}), fetchImpl });
  assert.deepEqual([out.status, out.body.reason], [503, "not-configured"]);
  ({ out, res } = recorder());
  await handleOnramp({ method: "POST", query: {}, body: { wallet: WALLET, amount: 50, email: "a@b.co" } }, res, { env, fetchImpl: async (url, init) => (init.method === "PUT" ? { status: 200, json: async () => ({}) } : { status: 400, json: async () => ({ message: "Unsupported token" }) }) });
  assert.deepEqual([out.status, out.body.error], [400, "Unsupported token"]);
  ({ out, res } = recorder());
  await handleOnramp({ method: "POST", query: {}, body: { wallet: WALLET, amount: 50, email: "a@b.co" } }, res, { env, fetchImpl: async () => ({ status: 422, json: async () => ({ message: "Invalid user locator" }) }) });
  assert.deepEqual([out.status, out.body.error], [422, "Invalid user locator"]);
});
