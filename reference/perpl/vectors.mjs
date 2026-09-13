// Generates the canonical-string and signature vectors DeskPerpl is pinned to.
// The key is the Ed25519 seed from Mera's published derivation vector, so the whole
// chain — PRF output to signature — is reproducible from one starting point.
//
//   node reference/perpl/vectors.mjs
import { createHash, createPrivateKey, sign as edSign } from "node:crypto";

const ED25519_SEED = "e6ab0994f80a3abf9a1c10d8d27733d24de8c873af6bee177a93a0da5a4b0f79";
const PKCS8_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");
const key = createPrivateKey({
  key: Buffer.concat([PKCS8_PREFIX, Buffer.from(ED25519_SEED, "hex")]),
  format: "der",
  type: "pkcs8",
});

const b64url = (bytes) => Buffer.from(bytes).toString("base64url");
const signEd = (text) => b64url(edSign(null, Buffer.from(text), key));
const sha256Hex = (body) => createHash("sha256").update(body).digest("hex");

const CHAIN = 10143;
const TIMESTAMP = "1789000000000";
const NONCE = b64url(Buffer.from("0102030405060708090a0b0c0d0e0f10", "hex"));

const rest = (method, target, body = "") => {
  const canonical = [CHAIN, method, target, TIMESTAMP, NONCE, sha256Hex(body)].join("\n");
  return { method, target, body, canonical, signature: signEd(canonical) };
};

const signin = () => {
  const canonical = [CHAIN, "trading-ws-signin", TIMESTAMP, NONCE].join("\n");
  return { canonical, signature: signEd(canonical) };
};

console.log(JSON.stringify({
  chainId: CHAIN,
  ed25519Seed: ED25519_SEED,
  timestamp: TIMESTAMP,
  nonce: NONCE,
  emptyBodySha256: sha256Hex(""),
  rest: [
    rest("GET", "/v1/trading/account-history"),
    rest("GET", "/v1/trading/fills?page=2&count=100"),
    rest("POST", "/v1/api-key/enroll", JSON.stringify({ chain_id: CHAIN, address: "0x50B240678777451BEfd67B7e8c3b4366482ba8F9" })),
    rest("POST", "/v1/trading/order", "{}"),
  ],
  signin: signin(),
}, null, 2));
