// /api/copy end to end against stand-ins for KMS and Perpl: a real wallet signs the enrolment and
// the grant, a real P-256 key plays the Secure Enclave, and the engine picks up what the API wrote.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createPrivateKey, createPublicKey, generateKeyPairSync, randomBytes, sign as cryptoSign } from "node:crypto";
import { privateKeyToAccount } from "viem/accounts";
import { memoryStore } from "../api/_store.mjs";
import { createCopyHandler, grantText, parseGrant, deviceCanonical, seal, unseal, checkedRules, LABEL } from "../api/_copy.mjs";
import { enrolmentDigest, jsonSpan, verifyEd25519 } from "../copyd/perpl.mjs";
import { createEngine, copierId } from "../copyd/engine.mjs";
import { DEFAULT_RULES } from "../copyd/planner.mjs";

const fixture = readFileSync(new URL("../../DeskKit/Tests/DeskFlowTests/EnrolmentPayload.json", import.meta.url), "utf8");
const context = JSON.parse(readFileSync(new URL("../../DeskKit/Tests/DeskFlowTests/Context-testnet.json", import.meta.url)));
const openMarkets = new Map(context.markets.filter((m) => m.config.is_open).map((m) => [m.id, m]));
const wallet = privateKeyToAccount("0x7c56100e187f2845a35ce856646662dfc2024be2b4a150b45ad1f62564617128");
const ME = wallet.address;
const TRADER = "0x52ac212e7187a799a7382c7a768cb35b72a3e20a";
const TOKEN_KEY = randomBytes(32).toString("base64");
const CAPS = { maxMarginPerTrade: 50, maxLeverage: 10, maxOpenCopies: 5, maxOpenNotional: 1000, maxDailyLoss: 100, maxOrdersPerHour: 30 };
const PKCS8 = Buffer.from("302e020100300506032b657004220420", "hex");

function fakeKms() {
  const keys = new Map();
  const calls = [];
  return {
    calls, keys,
    async send(command) {
      const name = command.constructor.name;
      const input = command.input;
      calls.push(name);
      switch (name) {
        case "CreateKeyCommand": {
          const id = `key-${keys.size + 1}`;
          const priv = createPrivateKey({ key: Buffer.concat([PKCS8, randomBytes(32)]), format: "der", type: "pkcs8" });
          keys.set(id, { priv, spki: createPublicKey(priv).export({ format: "der", type: "spki" }), enabled: true, tags: input.Tags });
          return { KeyMetadata: { KeyId: id } };
        }
        case "CreateAliasCommand": return {};
        case "GetPublicKeyCommand": return { KeyId: input.KeyId, KeySpec: "ECC_NIST_EDWARDS25519", PublicKey: new Uint8Array(keys.get(input.KeyId).spki) };
        case "SignCommand": {
          const key = keys.get(input.KeyId);
          if (!key.enabled) throw new Error("KMSInvalidStateException");
          return { Signature: new Uint8Array(cryptoSign(null, Buffer.from(input.Message), key.priv)) };
        }
        case "DisableKeyCommand": keys.get(input.KeyId).enabled = false; return {};
        case "ScheduleKeyDeletionCommand": return {};
        default: throw new Error(`unexpected ${name}`);
      }
    },
  };
}

/// Perpl's two public endpoints: the payload names whatever key it was asked about; the enrolment
/// checks the proof of possession the way the gateway would before answering with a token.
function fakePerpl() {
  const seen = { payloads: [], enrolments: [] };
  async function fetchImpl(url, { body }) {
    const json = JSON.parse(body);
    if (url.endsWith("/v1/api-key/payload")) {
      seen.payloads.push(json);
      const b64 = Buffer.from(json.public_key.slice(2), "hex").toString("base64url");
      const text = fixture.replace("iWhNhy3ZOebBOyydUBRlvf41RqgdMsKIncpbaEcEYQA", b64).replace(`"label":"desk"`, `"label":${JSON.stringify(json.label)}`);
      return new Response(text, { status: 200 });
    }
    if (url.endsWith("/v1/api-key/enroll")) {
      seen.enrolments.push(json);
      const typed = JSON.parse(jsonSpan(body, "typed_data"));
      const digest = Buffer.from(enrolmentDigest(typed).slice(2), "hex");
      const publicKey = Buffer.from(typed.message.publicKey, "base64url");
      if (!verifyEd25519(publicKey, digest, Buffer.from(json.pop_signature.slice(2), "hex"))) return new Response("bad pop", { status: 400 });
      return new Response(JSON.stringify({ api_key: { api_key: "perpl-token-1" } }), { status: 200 });
    }
    return new Response("no", { status: 404 });
  }
  return { fetchImpl, seen };
}

function device() {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const jwk = publicKey.export({ format: "jwk" });
  const raw = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, "base64url"), Buffer.from(jwk.y, "base64url")]);
  return { key: raw.toString("base64url"), privateKey };
}

function setup({ kms = fakeKms(), clock = { t: Date.UTC(2026, 9, 16, 12) } } = {}) {
  const store = memoryStore();
  const perpl = fakePerpl();
  const handler = createCopyHandler(() => ({ store, kms, tokenKey: TOKEN_KEY, fetchImpl: perpl.fetchImpl, now: () => clock.t }));
  const phone = device();
  async function call(action, body, { headers = {}, raw = false } = {}) {
    const res = { code: 0, body: null, status(c) { this.code = c; return this; }, json(b) { this.body = b; return this; }, setHeader() {} };
    await handler({ method: "POST", query: { action }, headers: { "x-forwarded-for": "1.2.3.4", ...headers }, body: raw ? body : body }, res);
    return res;
  }
  /// What the app sends after enrolment: the body as text, signed by the device key.
  async function signed(action, payload = {}, { key = phone.privateKey, time = clock.t, nonce = randomBytes(16).toString("base64url"), encoding = "der" } = {}) {
    const text = JSON.stringify(payload);
    const message = deviceCanonical({ chainId: 10143, method: "POST", target: `/api/copy/${action}`, time: String(time), nonce, body: text });
    const signature = cryptoSign("sha256", Buffer.from(message), { key, dsaEncoding: encoding }).toString("base64url");
    return call(action, text, {
      raw: true,
      headers: { "x-desk-network": "testnet", "x-desk-account": ME, "x-desk-time": String(time), "x-desk-nonce": nonce, "x-desk-signature": signature },
    });
  }
  async function enable({ caps = CAPS, grantFor = null } = {}) {
    const prepared = await call("prepare", { network: "testnet", address: ME });
    assert.equal(prepared.code, 200, JSON.stringify(prepared.body));
    const typed = JSON.parse(jsonSpan(prepared.body.payload, "typed_data"));
    const walletSignature = await wallet.sign({ hash: enrolmentDigest(typed) });
    const text = grantText({ account: ME, network: "testnet", serverKey: prepared.body.serverKey, deviceKey: phone.key, caps, issuedAt: clock.t, ...(grantFor ?? {}) });
    const enrolled = await call("enroll", {
      network: "testnet", address: ME, walletSignature, timeZone: "Africa/Lagos",
      grant: { text, signature: await wallet.signMessage({ message: text }) },
    });
    return { prepared, enrolled };
  }
  return { store, kms, perpl, call, signed, enable, phone, clock, id: copierId("testnet", ME) };
}

test("One Face ID turns it on: a KMS key, Perpl's registration, and a copier the engine can read", async () => {
  const ctx = setup();
  const { prepared, enrolled } = await ctx.enable();
  assert.match(prepared.body.serverKey, /^0x[0-9a-f]{64}$/);
  assert.equal(ctx.perpl.seen.payloads[0].scope_mask, 3);
  assert.equal(ctx.perpl.seen.payloads[0].label, LABEL);
  assert.equal(enrolled.code, 200, JSON.stringify(enrolled.body));
  assert.equal(enrolled.body.copier.network, "testnet");
  assert.deepEqual(enrolled.body.copier.caps, CAPS);
  assert.deepEqual(enrolled.body.copier.guards, { maxOpenCopies: 3, dailyLossLimit: 50, maxMarketExposure: 250 });
  assert.equal(enrolled.body.copier.timeZone, "Africa/Lagos");
  assert.equal(JSON.stringify(enrolled.body).includes("perpl-token-1"), false, "the token never goes back to the app");

  const stored = JSON.parse(await ctx.store.get(`copy:copier:${ctx.id}`));
  assert.equal(unseal(stored.apiKey, TOKEN_KEY), "perpl-token-1");
  assert.notEqual(stored.apiKey, "perpl-token-1");
  assert.equal(stored.keyId, "key-1");
  assert.deepEqual(await ctx.store.smembers("copy:dirty"), [ctx.id]);
  assert.equal(await ctx.store.get(`copy:pending:${ctx.id}`), null);
  assert.deepEqual(ctx.kms.keys.get("key-1").tags.find((t) => t.TagKey === "desk:purpose"), { TagKey: "desk:purpose", TagValue: "auto-copy" });

  const again = await ctx.call("prepare", { network: "testnet", address: ME });
  assert.equal(again.code, 409);
});

test("A second prepare offers the same key; a stale one is retired before a new one is made", async () => {
  const ctx = setup();
  const a = await ctx.call("prepare", { network: "testnet", address: ME });
  const b = await ctx.call("prepare", { network: "testnet", address: ME });
  assert.equal(a.body.serverKey, b.body.serverKey);
  assert.equal(ctx.kms.calls.filter((c) => c === "CreateKeyCommand").length, 1);
  ctx.clock.t += 30 * 60_000;
  const c = await ctx.call("prepare", { network: "testnet", address: ME });
  assert.notEqual(c.body.serverKey, a.body.serverKey);
  assert.equal(ctx.kms.keys.get("key-1").enabled, false, "the abandoned key can no longer sign");
  for (let i = 0; i < 3; i++) await ctx.call("prepare", { network: "testnet", address: ME });
  assert.equal((await ctx.call("prepare", { network: "testnet", address: ME })).code, 429, "six an hour");
});

test("A key name KMS already holds moves to the next, and the unnamed key is retired", async () => {
  const kms = fakeKms();
  const taken = new Set(["alias/desk-copy/testnet/0x50b240678777451befd67b7e8c3b4366482ba8f9/1", "alias/desk-copy/testnet/0x50b240678777451befd67b7e8c3b4366482ba8f9/2"]);
  const send = kms.send.bind(kms);
  kms.send = async (command) => {
    if (command.constructor.name === "CreateAliasCommand" && taken.has(command.input.AliasName)) {
      throw Object.assign(new Error(`An alias with the name ${command.input.AliasName} already exists`), { name: "AlreadyExistsException" });
    }
    return send(command);
  };
  const ctx = setup({ kms });
  const prepared = await ctx.call("prepare", { network: "testnet", address: ME });
  assert.equal(prepared.code, 200, JSON.stringify(prepared.body));
  assert.equal(JSON.parse(await ctx.store.get(`copy:pending:${ctx.id}`)).generation, 3);
  assert.equal(kms.keys.get("key-1").enabled, false);
  assert.equal(kms.keys.get("key-2").enabled, false);
  assert.equal(kms.keys.get("key-3").enabled, true);
});

test("The grant must be this wallet's, for this server key, and fresh", async () => {
  const stranger = privateKeyToAccount(`0x${"22".repeat(32)}`);
  const ctx = setup();
  const prepared = await ctx.call("prepare", { network: "testnet", address: ME });
  const typed = JSON.parse(jsonSpan(prepared.body.payload, "typed_data"));
  const walletSignature = await wallet.sign({ hash: enrolmentDigest(typed) });
  const grant = (over = {}) => grantText({ account: ME, network: "testnet", serverKey: prepared.body.serverKey, deviceKey: ctx.phone.key, caps: CAPS, issuedAt: ctx.clock.t, ...over });
  const enrol = async (text, signer = wallet, signature = walletSignature) =>
    ctx.call("enroll", { network: "testnet", address: ME, walletSignature: signature, grant: { text, signature: await signer.signMessage({ message: text }) } });

  assert.equal((await enrol(grant(), stranger)).code, 403);
  assert.equal((await enrol(grant({ serverKey: `0x${"ab".repeat(32)}` }))).code, 400);
  assert.equal((await enrol(grant({ issuedAt: ctx.clock.t - 3_600_000 }))).code, 400);
  assert.equal((await enrol(grant({ deviceKey: Buffer.alloc(65, 4).toString("base64url") }))).code, 400);
  const edited = grant().replace("Max leverage: 10x", "Max leverage: 50x");
  assert.equal((await ctx.call("enroll", { network: "testnet", address: ME, walletSignature, grant: { text: edited, signature: await wallet.signMessage({ message: grant() }) } })).code, 403);
  const wrongEnrolment = await enrol(grant(), wallet, await stranger.sign({ hash: enrolmentDigest(typed) }));
  assert.equal(wrongEnrolment.code, 403);
  assert.equal(wrongEnrolment.body.error, "The Perpl registration wasn't signed by this account.");
  assert.equal(ctx.perpl.seen.enrolments.length, 0, "nothing reached Perpl");
  assert.equal((await enrol(grant())).code, 200);
});

test("The grant reads back exactly as written, and nothing else parses", () => {
  const fields = { account: ME, network: "mainnet", serverKey: `0x${"cd".repeat(32)}`, deviceKey: "AQ", caps: CAPS, issuedAt: Date.UTC(2026, 9, 16) };
  const text = grantText(fields);
  assert.match(text, /^Desk Auto-Copy grant\nI let Desk's server copy trades for this account within these limits\.\nAccount: 0x50B2/);
  assert.match(text, /Max margin per trade: 50 AUSD\nMax leverage: 10x\nMax open copies: 5\n/);
  assert.deepEqual(parseGrant(text), { ...fields, account: ME });
  assert.throws(() => parseGrant(`${text}\nExtra: 1`));
  assert.throws(() => parseGrant(text.replace("Max open copies: 5", "Max open copies: -5")));
  assert.throws(() => parseGrant(text.replace("mainnet", "devnet")));
});

test("After enrolment only the phone's device key is listened to, once per request, within a minute", async () => {
  const ctx = setup();
  await ctx.enable();
  const state = await ctx.signed("state");
  assert.equal(state.code, 200, JSON.stringify(state.body));
  assert.deepEqual(state.body.open, []);
  assert.equal(state.body.copier.paused, false);
  assert.equal((await ctx.signed("state", {}, { encoding: "ieee-p1363" })).code, 200, "CryptoKit's raw signatures too");

  const nonce = randomBytes(16).toString("base64url");
  assert.equal((await ctx.signed("pause", {}, { nonce })).code, 200);
  assert.equal((await ctx.signed("pause", {}, { nonce })).code, 409, "a replay is refused");
  assert.equal((await ctx.signed("state", {}, { key: device().privateKey })).code, 401, "another phone's key");
  assert.equal((await ctx.signed("state", {}, { time: ctx.clock.t - 90_000 })).code, 401, "a stale request");
  const parsed = await ctx.call("state", {}, { headers: {} });
  assert.equal(parsed.code, 415, "a body already parsed can't be checked against its signature");
  assert.equal((await ctx.call("state", "{}", { raw: true })).code, 401, "unsigned");
});

test("Rules stay inside what Face ID approved: lowering is free, raising is refused", async () => {
  const ctx = setup();
  await ctx.enable();
  const rules = { ...DEFAULT_RULES, marginPerTrade: 20, maxLeverage: 5 };
  const ok = await ctx.signed("rules", { traders: { [TRADER]: { rules } }, guards: { maxOpenCopies: 2, dailyLossLimit: 40, maxMarketExposure: 200 } });
  assert.equal(ok.code, 200, JSON.stringify(ok.body));
  assert.deepEqual(Object.keys(ok.body.copier.traders), [TRADER]);
  assert.deepEqual(await ctx.store.smembers(`copy:followers:${TRADER}`), [ctx.id]);

  const refusals = [
    { traders: { [TRADER]: { rules: { ...rules, marginPerTrade: 60 } } } },
    { traders: { [TRADER]: { rules: { ...rules, marginPerTrade: 30, sizing: "conviction" } } } },
    { traders: { [TRADER]: { rules: { ...rules, maxLeverage: 20 } } } },
    { guards: { maxOpenCopies: 9, dailyLossLimit: 40, maxMarketExposure: 200 } },
    { guards: { maxOpenCopies: 2, dailyLossLimit: 500, maxMarketExposure: 200 } },
  ];
  for (const body of refusals) assert.equal((await ctx.signed("rules", body)).code, 403, JSON.stringify(body));
  assert.equal((await ctx.signed("rules", { traders: { nope: { rules } } })).code, 400);
  assert.equal((await ctx.signed("rules", { traders: { [TRADER]: { rules: { ...rules, mode: "yolo" } } } })).code, 400);

  ctx.clock.t += 60_000;
  const dropped = await ctx.signed("rules", { traders: {} });
  assert.deepEqual(dropped.body.copier.traders, {});
  assert.deepEqual(await ctx.store.smembers(`copy:followers:${TRADER}`), []);
  assert.throws(() => checkedRules({ ...rules, marginPerTrade: 0 }, CAPS));
});

test("The engine follows what the API writes: new copiers, rules, a close from the app, and turning off", async () => {
  const ctx = setup();
  const books = { [TRADER]: { accountId: "9", portfolio: 20_000, positions: {} } };
  const notes = [];
  const engine = createEngine({
    store: ctx.store, markets: async () => openMarkets, now: () => ctx.clock.t, logger: { warn() {} },
    readTrader: async (a) => books[a], notify: async (c, row) => notes.push(row),
  });
  await engine.ready();
  await ctx.enable();
  assert.equal(await engine.refresh(), 1);
  assert.ok(await engine.copier(ctx.id));

  await ctx.signed("rules", { traders: { [TRADER]: { rules: { ...DEFAULT_RULES, maxChaseBps: 200 } } } });
  await engine.refresh();
  await engine.processTrader(TRADER);
  books[TRADER].positions = { BTC: { symbol: "BTC", side: "long", size: 0.5, entry: 60_000, mark: 60_000, collateral: 2_000, leverage: 5, marketId: 16 } };
  await engine.processTrader(TRADER);
  const [copy] = await engine.openCopies(ctx.id);
  assert.equal(copy.symbol, "BTC");

  const state = await ctx.signed("state");
  assert.equal(state.body.open[0].id, copy.id);
  assert.equal(state.body.log[0].kind, "opened");

  assert.equal((await ctx.signed("close", { copyId: "nope" })).code, 404);
  assert.equal((await ctx.signed("close", { copyId: copy.id })).code, 200);
  await engine.refresh();
  assert.deepEqual(await engine.openCopies(ctx.id), []);
  assert.equal(notes.at(-1).detail, "Closed from the app.");
  assert.deepEqual(await ctx.store.smembers(`copy:close:${ctx.id}`), []);

  await ctx.store.set(`copy:pause:${ctx.id}`, "Today's copy losses reached your limit.");
  await engine.refresh();
  const resumed = await ctx.signed("resume");
  assert.equal(resumed.body.copier.paused, false);
  assert.equal(await ctx.store.get(`copy:pause:${ctx.id}`), null, "resuming clears the engine's pause too");

  const off = await ctx.signed("disable");
  assert.deepEqual(off.body, { disabled: true, keyRetired: true });
  assert.equal(ctx.kms.keys.get("key-1").enabled, false);
  await engine.refresh();
  assert.equal(await engine.copier(ctx.id), null);
  assert.equal((await ctx.signed("state")).code, 404, "nothing answers for a copier that is off");
  assert.equal((await ctx.call("prepare", { network: "testnet", address: ME })).code, 200, "and it can be turned on again, with a new key");
  assert.equal(ctx.kms.calls.filter((c) => c === "CreateKeyCommand").length, 2);
});

test("A wallet Perpl has no account for is told to deposit first", async () => {
  const ctx = setup();
  const real = ctx.perpl.fetchImpl;
  const handler = createCopyHandler(() => ({ store: ctx.store, kms: ctx.kms, tokenKey: TOKEN_KEY, now: () => ctx.clock.t,
    fetchImpl: (url, init) => (url.endsWith("/enroll") ? Promise.resolve(new Response("not found", { status: 404 })) : real(url, init)) }));
  const res = { status(c) { this.code = c; return this; }, json(b) { this.body = b; return this; }, setHeader() {} };
  const prepared = await ctx.call("prepare", { network: "testnet", address: ME });
  const typed = JSON.parse(jsonSpan(prepared.body.payload, "typed_data"));
  const text = grantText({ account: ME, network: "testnet", serverKey: prepared.body.serverKey, deviceKey: ctx.phone.key, caps: CAPS, issuedAt: ctx.clock.t });
  await handler({ method: "POST", query: { action: "enroll" }, headers: {}, body: {
    network: "testnet", address: ME, walletSignature: await wallet.sign({ hash: enrolmentDigest(typed) }),
    grant: { text, signature: await wallet.signMessage({ message: text }) } } }, res);
  assert.equal(res.code, 409);
  assert.match(res.body.error, /no Perpl account yet/);
});

test("Without AWS configured it says so instead of half-enrolling", async () => {
  const ctx = setup({ kms: null });
  const res = await ctx.call("prepare", { network: "testnet", address: ME });
  assert.equal(res.code, 503);
  assert.equal(ctx.perpl.seen.payloads.length, 0);
});

test("The token at rest opens only with its key", () => {
  const sealed = seal("perpl-token-1", TOKEN_KEY);
  assert.equal(unseal(sealed, TOKEN_KEY), "perpl-token-1");
  assert.throws(() => unseal(sealed, randomBytes(32).toString("base64")));
  assert.throws(() => seal("x", "short"));
});
