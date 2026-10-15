// The KMS signer against a stand-in for KMS that answers the real commands' shapes: a DER
// SubjectPublicKeyInfo, PureEdDSA over the raw message. Holding the vector seed, it must produce
// the vector signatures, which is the proof that a KMS key signs the way Perpl expects.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createPrivateKey, createPublicKey, sign as edSign } from "node:crypto";
import { kmsSigner, createKey, retireKey, ed25519FromSpki, aliasFor, kmsCommands } from "../copyd/kms.mjs";
import { stamp } from "../copyd/perpl.mjs";

const vectors = JSON.parse(readFileSync(new URL("../../DeskKit/Tests/DeskPerplTests/CanonicalVectors.json", import.meta.url)));
const PKCS8 = Buffer.from("302e020100300506032b657004220420", "hex");

function fakeKms(seedHex, { spec = "ECC_NIST_EDWARDS25519" } = {}) {
  const keys = new Map();
  const calls = [];
  const add = (id, seed) => {
    const priv = createPrivateKey({ key: Buffer.concat([PKCS8, Buffer.from(seed, "hex")]), format: "der", type: "pkcs8" });
    keys.set(id, { priv, spki: createPublicKey(priv).export({ format: "der", type: "spki" }), enabled: true });
  };
  add("key-1", seedHex);
  return {
    calls, keys,
    async send(command) {
      const name = command.constructor.name;
      const input = command.input;
      calls.push({ name, input });
      switch (name) {
        case "CreateKeyCommand": { add("key-new", "33".repeat(32)); return { KeyMetadata: { KeyId: "key-new" } }; }
        case "CreateAliasCommand": return {};
        case "GetPublicKeyCommand": return { KeyId: input.KeyId, KeySpec: spec, PublicKey: new Uint8Array(keys.get(input.KeyId).spki) };
        case "SignCommand": {
          const key = keys.get(input.KeyId);
          if (!key.enabled) throw new Error("DisabledException");
          assert.equal(input.MessageType, "RAW");
          assert.equal(input.SigningAlgorithm, "ED25519_SHA_512");
          return { Signature: new Uint8Array(edSign(null, Buffer.from(input.Message), key.priv)) };
        }
        case "DisableKeyCommand": keys.get(input.KeyId).enabled = false; return {};
        case "ScheduleKeyDeletionCommand": return { DeletionDate: new Date() };
        default: throw new Error(`unexpected ${name}`);
      }
    },
  };
}

test("A KMS-held key signs requests exactly as the vectors", async () => {
  const client = fakeKms(vectors.ed25519Seed);
  const signer = await kmsSigner({ client, keyId: "key-1" });
  assert.equal(signer.publicKey.toString("hex"), "89684d872dd939e6c13b2c9d501465bdfe3546a81d32c2889dca5b6847046100");
  for (const v of vectors.rest) {
    const headers = await stamp({ signer, apiKey: "tok", chainId: vectors.chainId, method: v.method, target: v.target, body: v.body, timestamp: vectors.timestamp, nonce: vectors.nonce });
    assert.equal(headers["X-API-Signature"], v.signature);
  }
});

test("A key that is not Ed25519 is refused", async () => {
  await assert.rejects(kmsSigner({ client: fakeKms(vectors.ed25519Seed, { spec: "ECC_SECG_P256K1" }), keyId: "key-1" }), /not ECC_NIST_EDWARDS25519/);
  assert.throws(() => ed25519FromSpki(Buffer.alloc(44)), /not Ed25519/);
});

test("Each enrolment gets its own tagged key under the account's alias, and retiring it stops it signing", async () => {
  const client = fakeKms(vectors.ed25519Seed);
  const signer = await createKey({ client, network: "mainnet", address: "0xABCDEF0000000000000000000000000000000001", generation: 3 });
  const created = client.calls.find((c) => c.name === "CreateKeyCommand").input;
  assert.equal(created.KeySpec, "ECC_NIST_EDWARDS25519");
  assert.equal(created.KeyUsage, "SIGN_VERIFY");
  assert.ok(created.Tags.some((t) => t.TagKey === "desk:account" && t.TagValue === "0xabcdef0000000000000000000000000000000001"));
  const alias = client.calls.find((c) => c.name === "CreateAliasCommand").input;
  assert.equal(alias.AliasName, aliasFor({ network: "mainnet", address: "0xABCDEF0000000000000000000000000000000001", generation: 3 }));
  assert.equal(alias.AliasName, "alias/desk-copy/mainnet/0xabcdef0000000000000000000000000000000001/3");
  await signer.sign(Buffer.from("hello"));
  await retireKey({ client, keyId: signer.keyId });
  await assert.rejects(signer.sign(Buffer.from("hello")), /Disabled/);
  assert.equal(client.calls.find((c) => c.name === "ScheduleKeyDeletionCommand").input.PendingWindowInDays, 7);
});

test("The real SDK exposes the commands the signer sends", async () => {
  const c = await kmsCommands();
  for (const name of ["CreateKeyCommand", "CreateAliasCommand", "GetPublicKeyCommand", "SignCommand", "DisableKeyCommand", "ScheduleKeyDeletionCommand"]) {
    assert.equal(typeof c[name], "function", name);
  }
});
