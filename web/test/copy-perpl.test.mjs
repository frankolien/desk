// The server's Perpl client against the vectors DeskKit is pinned to: canonical strings and
// signatures byte for byte (Node's Ed25519 is deterministic, as the reference generator is),
// the EIP-712 enrolment digest, and order specs with OrderRequestTests' inputs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { privateKeyToAccount } from "viem/accounts";
import {
  localSigner, canonical, stamp, signinFrame, enrolmentDigest, checkEnrolmentPayload, enrolBody, jsonSpan,
  tokenFrom, marketOpen, marketClose, protectiveClose, requestCounter, stopCondition, takeCondition, verifyEd25519, payloadBody,
} from "../copyd/perpl.mjs";
import { marketFromContext, scaled } from "../copyd/planner.mjs";

const vectors = JSON.parse(readFileSync(new URL("../../DeskKit/Tests/DeskPerplTests/CanonicalVectors.json", import.meta.url)));
const payloadText = readFileSync(new URL("../../DeskKit/Tests/DeskFlowTests/EnrolmentPayload.json", import.meta.url), "utf8");
const context = JSON.parse(readFileSync(new URL("../../DeskKit/Tests/DeskFlowTests/Context-testnet.json", import.meta.url)));
const btc = marketFromContext(context.markets.find((m) => m.id === 16));

const signer = localSigner(vectors.ed25519Seed);
const ADDRESS = "0x50B240678777451BEfd67B7e8c3b4366482ba8F9";
const wallet = privateKeyToAccount("0x7c56100e187f2845a35ce856646662dfc2024be2b4a150b45ad1f62564617128");

test("The seed's public key is the one the derivation vectors pin", () => {
  assert.equal(signer.publicKey.toString("hex"), "89684d872dd939e6c13b2c9d501465bdfe3546a81d32c2889dca5b6847046100");
  assert.equal(wallet.address, ADDRESS);
});

test("Every REST request is stamped exactly as the vectors", async () => {
  for (const v of vectors.rest) {
    assert.equal(canonical(vectors.chainId, v.method, v.target, vectors.timestamp, vectors.nonce, v.body), v.canonical);
    const headers = await stamp({ signer, apiKey: "tok", chainId: vectors.chainId, method: v.method, target: v.target, body: v.body, timestamp: vectors.timestamp, nonce: vectors.nonce });
    assert.equal(headers["X-API-Signature"], v.signature, `${v.method} ${v.target}`);
    assert.equal(headers["X-API-Nonce"], vectors.nonce);
    assert.equal(headers["X-API-Timestamp"], vectors.timestamp);
  }
});

test("The trading socket's sign-in frame carries the vector signature", async () => {
  const frame = JSON.parse(await signinFrame({ signer, apiKey: "tok", chainId: vectors.chainId, timestamp: vectors.timestamp, nonce: vectors.nonce }));
  assert.equal(frame.mt, 29);
  assert.equal(frame.signature, vectors.signin.signature);
});

test("A signer whose signature does not verify is refused before anything is sent", async () => {
  const liar = { ...signer, async sign() { return Buffer.alloc(64, 1); } };
  await assert.rejects(stamp({ signer: liar, apiKey: "t", chainId: 143, method: "GET", target: "/v1/trading/wallet" }), /does not verify/);
});

test("The enrolment digest hashes chainId and time as integers", () => {
  const typed = JSON.parse(jsonSpan(payloadText, "typed_data"));
  assert.equal(enrolmentDigest(typed), "0xb57fe053266b9449f2ac34eada069eae0deb8b069d372ac77a80f13cf2fbe389");
});

test("The payload must be for this wallet, this key, this chain and trade scope, and nothing undeclared", () => {
  const typed = JSON.parse(jsonSpan(payloadText, "typed_data"));
  assert.ok(checkEnrolmentPayload(typed, { address: ADDRESS, publicKey: signer.publicKey, chainId: 10143 }));
  const other = localSigner("11".repeat(32));
  assert.throws(() => checkEnrolmentPayload(typed, { address: ADDRESS, publicKey: other.publicKey, chainId: 10143 }), /another key/);
  assert.throws(() => checkEnrolmentPayload(typed, { address: wallet.address.replace("50B2", "50B3"), publicKey: signer.publicKey, chainId: 10143 }), /another wallet|address/i);
  assert.throws(() => checkEnrolmentPayload(typed, { address: ADDRESS, publicKey: signer.publicKey, chainId: 143 }), /another chain/);
  const sneaky = { ...typed, message: { ...typed.message, withdraw: "yes" } };
  assert.throws(() => checkEnrolmentPayload(sneaky, { address: ADDRESS, publicKey: signer.publicKey, chainId: 10143 }), /undeclared/);
  const wider = { ...typed, message: { ...typed.message, scope: "7" } };
  assert.throws(() => checkEnrolmentPayload(wider, { address: ADDRESS, publicKey: signer.publicKey, chainId: 10143 }), /scope/);
});

test("The enrol body splices Perpl's bytes untouched, with the wallet's signature and the key's proof", async () => {
  const digest = enrolmentDigest(JSON.parse(jsonSpan(payloadText, "typed_data")));
  const walletSignature = await wallet.sign({ hash: digest });
  const { body } = await enrolBody({ payloadText, chainId: 10143, address: ADDRESS, walletSignature, signer });
  assert.ok(body.includes(`"typed_data":${jsonSpan(payloadText, "typed_data")}`));
  assert.ok(body.includes(`"mac":${jsonSpan(payloadText, "mac")}`));
  const parsed = JSON.parse(body);
  assert.equal(parsed.signature, walletSignature);
  assert.ok(verifyEd25519(signer.publicKey, Buffer.from(digest.slice(2), "hex"), Buffer.from(parsed.pop_signature.slice(2), "hex")));
  const stranger = privateKeyToAccount(`0x${"22".repeat(32)}`);
  await assert.rejects(enrolBody({ payloadText, chainId: 10143, address: ADDRESS, walletSignature: await stranger.sign({ hash: digest }), signer }), /not this account/);
});

test("The payload request names the key as hex and asks for trade scope", () => {
  const body = JSON.parse(payloadBody({ chainId: 143, address: ADDRESS.toLowerCase(), publicKey: signer.publicKey, label: "Desk Auto-Copy (server)" }));
  assert.equal(body.public_key, "0x89684d872dd939e6c13b2c9d501465bdfe3546a81d32c2889dca5b6847046100");
  assert.equal(body.scope_mask, 3);
  assert.equal(body.address, ADDRESS);
  assert.equal(tokenFrom({ api_key: { api_key: "abc", scope_mask: 3 } }), "abc");
  assert.equal(tokenFrom({ api_key: "xyz" }), "xyz");
});

test("Order specs match OrderRequestTests", () => {
  const open = marketOpen({ market: btc, account: 7, side: "long", size: scaled(1480n, 5), leverageHundredths: 100, slippageBps: 50, rq: 41n });
  assert.deepEqual(open, { rq: 41, mkt: 16, acc: 7, t: 1, p: 0, s: 1480, fl: 4, lv: 100, lb: 0, ms: 50 });
  assert.equal(marketOpen({ market: btc, account: 7, side: "short", size: scaled(1480n, 5), leverageHundredths: 300, slippageBps: 50, rq: 1n }).t, 2);
  assert.equal(marketClose({ market: btc, account: 7, side: "long", size: scaled(1480n, 5), slippageBps: 50, rq: 1n }).t, 3);
  assert.equal(marketClose({ market: btc, account: 7, side: "short", size: scaled(1480n, 5), slippageBps: 50, rq: 1n }).t, 4);
  const stop = protectiveClose({ market: btc, account: 7, side: "long", size: scaled(1480n, 5), trigger: scaled(640_000n, 1), condition: stopCondition("long"), linkedRequest: 41n, slippageBps: 50, rq: 42n });
  assert.equal(stop.t, 3); assert.equal(stop.p, 0); assert.equal(stop.fl, 4); assert.equal(stop.tp, 640_000);
  assert.equal(stop.tpc, 4); assert.equal(stop.tr, 41); assert.equal(stop.lb, 0); assert.equal(stop.ms, 50);
  assert.throws(() => protectiveClose({ market: btc, account: 7, side: "long", size: scaled(1480n, 5), trigger: scaled(640_000n, 1), condition: 4, slippageBps: 50, rq: 42n }), /linked/);
  assert.throws(() => marketOpen({ market: btc, account: 7, side: "long", size: scaled(1480n, 5), leverageHundredths: 1600, slippageBps: 50, rq: 1n }), /leverage/);
  assert.throws(() => marketOpen({ market: btc, account: 7, side: "long", size: scaled(1480n, 5), leverageHundredths: 100, slippageBps: 0, rq: 1n }), /slippage/);
  assert.equal(takeCondition("long"), 3); assert.equal(stopCondition("short"), 3); assert.equal(takeCondition("short"), 4);
});

test("Request ids climb past Perpl's last forwarded, past this process, and to the clock", () => {
  let clock = 1_000n;
  const next = requestCounter(() => clock);
  assert.equal(next(5n), 1_000n);
  assert.equal(next(5n), 1_001n);
  assert.equal(next(5_000n), 5_001n);
  clock = 10_000n;
  assert.equal(next(5_000n), 10_000n);
});
