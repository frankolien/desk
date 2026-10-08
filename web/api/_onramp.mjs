/// Card and Apple Pay deposits through Crossmint. The server creates the order with the
/// user's own wallet as the recipient and hands the app a secret scoped to that one order;
/// Crossmint's sheet takes the payment and the KYC, and the tokens land in the wallet. The
/// key never reaches the app, and the app never talks to Crossmint directly.

export const AUSD_ON_MONAD = "monad:0x00000000efe302beaa2b3e6e1b18d08d69a9012a";
/// Crossmint's staging stand-in: test USDC on Base Sepolia. Nothing from staging reaches Monad.
export const STAGING_TOKEN = "base-sepolia:0x036CbD53842c5426634e7929541eC2318f3dCF7e";
export const MIN_USD = 2;
export const MAX_USD = 2_000;
const CURRENCIES = new Set(["usd", "eur"]);
const EVM = /^0x[a-fA-F0-9]{40}$/;
const ORDER_ID = /^[A-Za-z0-9_-]{8,64}$/;

/// The environment follows the key: a staging key can only ever talk to staging. CROSSMINT_ENV
/// may name it too, and a locator override points staging at another test token.
export function onrampEnv(env = process.env) {
  const key = env.CROSSMINT_API_KEY || null;
  if (!key) return { configured: false };
  const fromKey = key.startsWith("sk_production_") ? "production" : key.startsWith("sk_staging_") ? "staging" : null;
  const named = env.CROSSMINT_ENV === "production" ? "production" : env.CROSSMINT_ENV === "staging" ? "staging" : null;
  const environment = fromKey ?? named ?? "staging";
  const tokenLocator = env.CROSSMINT_TOKEN_LOCATOR || (environment === "production" ? AUSD_ON_MONAD : STAGING_TOKEN);
  const [chain, address] = tokenLocator.split(":");
  return {
    configured: true,
    key,
    // The client key is public by design: Crossmint's sheet in the app identifies itself with it.
    clientKey: env.CROSSMINT_CLIENT_KEY || null,
    environment,
    base: environment === "production" ? "https://www.crossmint.com" : "https://staging.crossmint.com",
    tokenLocator,
    chain,
    address,
    symbol: tokenLocator === AUSD_ON_MONAD ? "AUSD" : "USDC",
    test: environment !== "production",
  };
}

export function parseDeposit(body) {
  if (!body || typeof body !== "object") return { error: "A JSON body is required." };
  const wallet = String(body.wallet ?? "");
  if (!EVM.test(wallet)) return { error: "A wallet address is required." };
  const amount = Number(body.amount);
  if (!Number.isFinite(amount) || amount < MIN_USD || amount > MAX_USD || Math.round(amount * 100) !== amount * 100) {
    return { error: `Enter an amount between ${MIN_USD} and ${MAX_USD.toLocaleString("en-US")}, to the cent.` };
  }
  const currency = String(body.currency ?? "usd").toLowerCase();
  if (!CURRENCIES.has(currency)) return { error: "Pay in USD or EUR." };
  // Crossmint sends the receipt and any identity check to it, so an order cannot open without one.
  const email = String(body.email ?? "").trim().toLowerCase();
  if (!email) return { error: "An email for the receipt is required." };
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) return { error: "That doesn't look like an email address." };
  return { wallet, amount: amount.toFixed(2).replace(/\.?0+$/, ""), currency, email };
}

export function orderBody({ wallet, amount, currency, email }, tokenLocator) {
  return {
    recipient: { walletAddress: wallet },
    payment: { method: "card", currency, receiptEmail: email },
    lineItems: [{ tokenLocator, executionParameters: { mode: "exact-in", amount: String(amount) } }],
  };
}

const text = (value) => (value == null ? null : String(value));

/// Who the wallet belongs to, in Crossmint's terms: a user of Desk's own naming, one per
/// wallet, so the link never changes when the receipt email does. A wallet linked under one
/// locator cannot be linked under another.
export const userLocator = ({ wallet }) => `userId:desk-${wallet.toLowerCase()}`;

/// Crossmint's order as the app reads it: where it is, what it costs, what arrives.
export function describeOrder(order, symbol) {
  const item = order?.lineItems?.[0] ?? {};
  const range = item.quote?.quantityRange ?? null;
  const delivery = item.delivery ?? {};
  const payment = order?.payment ?? {};
  return {
    orderId: text(order?.orderId),
    phase: text(order?.phase),
    payment: text(payment.status),
    delivery: text(delivery.status),
    txId: text(delivery.txId ?? payment.received?.txId),
    quote: {
      status: text(order?.quote?.status),
      total: text(order?.quote?.totalPrice?.amount),
      currency: text(order?.quote?.totalPrice?.currency),
      expiresAt: text(order?.quote?.expiresAt),
      receive: range ? { min: text(range.lowerBound), max: text(range.upperBound), symbol } : null,
    },
    completed: order?.phase === "completed" || delivery.status === "completed",
    failed: delivery.status === "failed" || payment.status === "failed-kyc",
    // Over Crossmint's thresholds the wallet must prove itself by signing this message.
    needsProof: payment.status === "requires-recipient-verification",
    proofMessage: text(payment.preparation?.message),
  };
}

async function talk(fetchImpl, env, path, init) {
  const response = await fetchImpl(`${env.base}/api/2022-06-09/${path}`, {
    ...init,
    headers: { "x-api-key": env.key, "content-type": "application/json", accept: "application/json", ...(init?.headers ?? {}) },
  });
  const body = await response.json().catch(() => null);
  return { status: response.status, body };
}

/// An external wallet must be linked to a Crossmint user before it can receive an order. The link
/// is a PUT, so repeating it is harmless; the proof of ownership comes later, only when asked.
export async function linkWallet(fetchImpl, env, deposit, proof = null) {
  const path = `users/${encodeURIComponent(userLocator(deposit))}/linked-wallets/${deposit.wallet}`;
  const response = await fetchImpl(`${env.base}/api/2025-06-09/${path}`, {
    method: "PUT",
    headers: { "x-api-key": env.key, "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({ chain: env.chain, ...(proof ? { proof } : {}) }),
  });
  const body = await response.json().catch(() => null);
  if (response.status >= 200 && response.status < 300) return { linked: true };
  return { error: text(body?.message ?? body?.error) || `Crossmint answered ${response.status} to the wallet link.`, status: response.status };
}

export async function createOrder(fetchImpl, env, deposit) {
  const link = await linkWallet(fetchImpl, env, deposit);
  if (link.error) return link;
  const { status, body } = await talk(fetchImpl, env, "orders", { method: "POST", body: JSON.stringify(orderBody(deposit, env.tokenLocator)) });
  if (status !== 201 && status !== 200) {
    return { error: text(body?.message ?? body?.error) || `Crossmint answered ${status}.`, status };
  }
  return { clientSecret: text(body?.clientSecret), order: describeOrder(body?.order, env.symbol) };
}

export async function readOrder(fetchImpl, env, orderId) {
  if (!ORDER_ID.test(orderId)) return { error: "An order id is required.", status: 400 };
  const { status, body } = await talk(fetchImpl, env, `orders/${encodeURIComponent(orderId)}`, { method: "GET" });
  if (status !== 200) return { error: text(body?.message ?? body?.error) || `Crossmint answered ${status}.`, status };
  return { order: describeOrder(body, env.symbol) };
}

/// The route the app calls: GET for what is set up, POST to open an order, GET ?orderId to follow it.
export async function handleOnramp(req, res, { env = onrampEnv(), fetchImpl = fetch } = {}) {
  res.setHeader("Cache-Control", "private, no-store");
  if (!env.configured) return res.status(503).json({ error: "Card deposits aren't set up on this server.", reason: "not-configured" });
  const setup = {
    environment: env.environment, test: env.test, clientKey: env.clientKey,
    token: { chain: env.chain, symbol: env.symbol }, limits: { min: MIN_USD, max: MAX_USD, currencies: [...CURRENCIES] },
  };
  if (req.method === "GET") {
    const orderId = String(req.query.orderId ?? "");
    if (!orderId) return res.status(200).json(setup);
    const read = await readOrder(fetchImpl, env, orderId).catch(() => ({ error: "Crossmint could not be reached.", status: 502 }));
    if (read.error) return res.status(read.status >= 400 && read.status < 600 ? read.status : 502).json({ error: read.error });
    return res.status(200).json({ ...read.order, environment: env.environment, test: env.test });
  }
  if (req.method !== "POST") return res.status(405).json({ error: "GET or POST required" });
  const body = typeof req.body === "string" ? (() => { try { return JSON.parse(req.body); } catch { return null; } })() : req.body;
  const deposit = parseDeposit(body);
  if (deposit.error) return res.status(400).json({ error: deposit.error });
  const created = await createOrder(fetchImpl, env, deposit).catch(() => ({ error: "Crossmint could not be reached.", status: 502 }));
  if (created.error) return res.status(created.status >= 400 && created.status < 600 ? created.status : 502).json({ error: created.error });
  return res.status(201).json({ ...created, ...setup });
}
