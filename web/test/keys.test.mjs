import { test } from "node:test";
import assert from "node:assert/strict";
import { createPrivateKey, sign as edSign, createHash } from "node:crypto";
import {
  PRF_SALT, canonicalRest, canonicalSignIn, deriveTradingKey, deriveWallet, requestStamp, sha256Hex, signCanonical, signedHeaders, toHex,
} from "../public/app/keys.js";

// Mera's published vector, the one DeskAuth is pinned to.
const prf = Uint8Array.from({ length: 32 }, (_, i) => i + 1);

test("the PRF salt is Mera's", () => {
  assert.equal(toHex(PRF_SALT), `0x${createHash("sha256").update("mera.prf.salt.v1").digest("hex")}`);
});

test("derives the same wallet and trading key as the phone", () => {
  const wallet = deriveWallet(prf);
  assert.equal(toHex(wallet.privateKey), "0x7c56100e187f2845a35ce856646662dfc2024be2b4a150b45ad1f62564617128");
  assert.equal(wallet.address, "0x50B240678777451BEfd67B7e8c3b4366482ba8F9");
  const trading = deriveTradingKey(prf);
  assert.equal(toHex(trading.seed), "0xe6ab0994f80a3abf9a1c10d8d27733d24de8c873af6bee177a93a0da5a4b0f79");
  assert.equal(toHex(trading.publicKey), "0x89684d872dd939e6c13b2c9d501465bdfe3546a81d32c2889dca5b6847046100");
});

test("another index is another key, and a hardened index is refused", () => {
  assert.notEqual(toHex(deriveTradingKey(prf, 1).publicKey), toHex(deriveTradingKey(prf, 0).publicKey));
  assert.throws(() => deriveTradingKey(prf, 0x80000000));
  assert.throws(() => deriveWallet(new Uint8Array(31)));
});

test("signs Perpl's canonical strings exactly as the reference script does", () => {
  const seed = Buffer.from("e6ab0994f80a3abf9a1c10d8d27733d24de8c873af6bee177a93a0da5a4b0f79", "hex");
  const key = createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]), format: "der", type: "pkcs8" });
  const stamp = { timestamp: "1789000000000", nonce: Buffer.from("0102030405060708090a0b0c0d0e0f10", "hex").toString("base64url") };
  const body = JSON.stringify({ chain_id: 10143, address: "0x50B240678777451BEfd67B7e8c3b4366482ba8F9" });
  const canonical = canonicalRest(10143, "POST", "/v1/api-key/enroll", body, stamp);
  const expected = [10143, "POST", "/v1/api-key/enroll", stamp.timestamp, stamp.nonce, createHash("sha256").update(body).digest("hex")].join("\n");
  assert.equal(canonical, expected);
  assert.equal(signCanonical(new Uint8Array(seed), canonical), Buffer.from(edSign(null, Buffer.from(canonical), key)).toString("base64url"));
  const signin = canonicalSignIn(10143, stamp);
  assert.equal(signin, `10143\ntrading-ws-signin\n${stamp.timestamp}\n${stamp.nonce}`);
  assert.equal(sha256Hex(new Uint8Array()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
});

test("a stamp is fresh, unpadded and twelve-plus bytes of nonce", () => {
  const stamp = requestStamp(1789000000000);
  assert.equal(stamp.timestamp, "1789000000000");
  assert.match(stamp.nonce, /^[A-Za-z0-9_-]{22}$/);
  const headers = signedHeaders({ apiKey: "k", tradingSeed: deriveTradingKey(prf).seed, chainId: 143, method: "GET", target: "/v1/trading/wallet" });
  assert.deepEqual(Object.keys(headers), ["X-API-Key", "X-API-Timestamp", "X-API-Nonce", "X-API-Signature"]);
  assert.match(headers["X-API-Signature"], /^[A-Za-z0-9_-]{86}$/);
});
