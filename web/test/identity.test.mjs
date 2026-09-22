import assert from "node:assert/strict";
import { test } from "node:test";

import { describeIdentity, lookupName, pickFarcasterUser, resolveIdentities } from "../api/_identity.mjs";
import { memoryStore } from "../api/_store.mjs";
import { createHandler } from "../api/traders.mjs";

const SALMO = "0xeaC3D06097Fc94956FC1eEE65d503Ff9a739A7C6";
const PLAIN = "0x95D2602d30DA1179fd13274839e60345857ca648";
const VITALIK = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";
const SOLANA = "Fw1ETanDZafof7xEULsnq9UY6o71Tpds89tNwPkWLb1v";

const json = (body, ok = true) => ({ ok, json: async () => body });

function sources({ nad = {}, fun = {}, cast = null } = {}) {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push(String(url));
    if (url.startsWith("https://api.nad.domains/")) {
      const addrs = new URL(url).searchParams.get("addrs").split(";");
      return json({ success: true, profiles: addrs.map((addr) => ({ addr, primaryName: nad[addr.toLowerCase()]?.name ?? null, avatar: nad[addr.toLowerCase()]?.avatar ?? null })) });
    }
    if (url.startsWith("https://api.nad.fun/profile/")) {
      const address = url.slice("https://api.nad.fun/profile/".length);
      const profile = fun[address.toLowerCase()];
      return json({ account_info: profile ?? { account_id: address, nickname: address, bio: "", image_uri: "https://storage.nadapp.net/default_profile_2.png" } });
    }
    if (url.startsWith("https://api.neynar.com/")) {
      assert.equal(options.headers["x-api-key"], "neynar-test");
      return json(cast ?? {});
    }
    throw new Error(`unexpected ${url}`);
  };
  return { fetchImpl, calls };
}

test("a .nad name wins, and the avatar it lacks comes from nad.fun", async () => {
  const { fetchImpl } = sources({
    nad: { [SALMO.toLowerCase()]: { name: "salmo.nad", avatar: null } },
    fun: { [SALMO.toLowerCase()]: { nickname: "Salmo", bio: "monad maxi", image_uri: "https://storage.nadapp.net/u/salmo.png" } },
  });
  const identities = await resolveIdentities([SALMO], { fetchImpl });
  assert.deepEqual(identities[SALMO.toLowerCase()], {
    address: SALMO.toLowerCase(), name: "salmo.nad", source: "nad",
    avatar: "https://storage.nadapp.net/u/salmo.png", bio: "monad maxi", x: null, farcaster: null, perplAccount: null,
  });
});

test("nad.fun's defaults are not a profile, so ENS is next", async () => {
  const { fetchImpl } = sources();
  const ens = async (address) => (address === VITALIK.toLowerCase()
    ? { name: "vitalik.eth", avatar: "https://euc.li/vitalik.eth", x: "VitalikButerin" } : null);
  const identities = await resolveIdentities([VITALIK, PLAIN], { fetchImpl, ens });
  assert.equal(identities[VITALIK.toLowerCase()].name, "vitalik.eth");
  assert.equal(identities[VITALIK.toLowerCase()].source, "ens");
  assert.equal(identities[VITALIK.toLowerCase()].x, "VitalikButerin");
  assert.equal(identities[PLAIN.toLowerCase()].name, null);
  assert.equal(identities[PLAIN.toLowerCase()].source, null);
});

test("a wallet with nothing public keeps its Perpl account number", async () => {
  const { fetchImpl } = sources();
  const chain = { async accountByAddress(address) { return address === PLAIN.toLowerCase() ? { accountId: 3901n } : { accountId: 0n }; } };
  const identities = await resolveIdentities([PLAIN, SALMO], { fetchImpl, chain });
  assert.equal(identities[PLAIN.toLowerCase()].perplAccount, "3901");
  assert.equal(identities[SALMO.toLowerCase()].perplAccount, null);
});

test("Farcaster is asked only with a key, and its display name is used", async () => {
  const cast = { [VITALIK.toLowerCase()]: [{ username: "vitalik.eth", display_name: "Vitalik", pfp_url: "https://i.imgur.com/v.png", profile: { bio: { text: "hmm" } } }] };
  const withKey = sources({ cast });
  const found = await resolveIdentities([VITALIK], { fetchImpl: withKey.fetchImpl, neynarKey: "neynar-test" });
  assert.equal(found[VITALIK.toLowerCase()].name, "Vitalik");
  assert.equal(found[VITALIK.toLowerCase()].farcaster, "vitalik.eth");
  const withoutKey = sources({ cast });
  await resolveIdentities([VITALIK], { fetchImpl: withoutKey.fetchImpl, neynarKey: undefined });
  assert.ok(!withoutKey.calls.some((url) => url.includes("neynar")));
});

test("the order of sources is fixed: .nad, nad.fun, ENS, Farcaster", () => {
  const all = describeIdentity("0xabc", {
    nad: { name: "a.nad" }, fun: { name: "b" }, ens: { name: "c.eth", x: "cee" }, cast: { name: "d", username: "dee", bio: "bio" },
  });
  assert.equal(all.name, "a.nad");
  assert.equal(all.x, "cee");
  assert.equal(all.bio, "bio");
  assert.equal(describeIdentity("0xabc", { fun: { name: "b" }, ens: { name: "c.eth" } }).source, "nadfun");
});

test("the handler validates, batches, and answers from the cache the second time", async () => {
  const store = memoryStore();
  const { fetchImpl, calls } = sources({ nad: { [SALMO.toLowerCase()]: { name: "salmo.nad" } } });
  const handler = createHandler({ chain: null, fetchImpl, store, ens: async () => null });
  const recorder = () => ({ status(code) { this.code = code; return this; }, json(body) { return { status: this.code, body }; }, setHeader() {} });

  const bad = await handler({ method: "GET", query: { view: "identity", addresses: "nope" } }, recorder());
  assert.equal(bad.status, 400);

  const first = await handler({ method: "GET", query: { view: "identity", addresses: `${SALMO},${PLAIN}` } }, recorder());
  assert.equal(first.status, 200);
  assert.equal(first.body.identities[SALMO.toLowerCase()].name, "salmo.nad");
  assert.equal(first.body.identities[PLAIN.toLowerCase()].name, null);
  const before = calls.length;

  const again = await handler({ method: "GET", query: { view: "identity", addresses: SALMO } }, recorder());
  assert.equal(again.body.identities[SALMO.toLowerCase()].name, "salmo.nad");
  assert.equal(calls.length, before);
});

test("of several Farcaster accounts on one address, the one that verified it wins, never a placeholder", () => {
  const address = "0xD7029BDEa1c17493893AAfE29AAD69EF892B8ff2";
  const users = [
    { fid: 188133, username: "!188133", follower_count: 0 },
    { fid: 9, username: "throwaway", follower_count: 12, verified_addresses: { eth_addresses: [] } },
    { fid: 3, username: "dwr.eth", follower_count: 500000, verified_addresses: { eth_addresses: [address.toLowerCase()] } },
  ];
  assert.equal(pickFarcasterUser(address, users).username, "dwr.eth");
  assert.equal(pickFarcasterUser(address, [users[0]]), null);
  assert.equal(pickFarcasterUser(address, [users[1], { username: "big", follower_count: 90 }]).username, "big");
});

test("a name becomes an address: .nad through the name service, .eth through ENS, @handle through Farcaster", async () => {
  const fetchImpl = async (url, options) => {
    if (url.includes("resolved-address/salmo.nad")) return json({ success: true, resolvedAddress: SALMO });
    if (url.includes("resolved-address/")) return json({ success: false });
    if (url.includes("by_username?username=vitalik")) { assert.equal(options.headers["x-api-key"], "k"); return json({ user: { verified_addresses: { eth_addresses: [VITALIK] } } }); }
    return json({}, false);
  };
  assert.deepEqual(await lookupName("Salmo.nad", { fetchImpl }), { address: SALMO.toLowerCase(), source: "nad" });
  assert.equal(await lookupName("nobody.nad", { fetchImpl }), null);
  assert.deepEqual(await lookupName("vitalik.eth", { fetchImpl, ensAddress: async () => VITALIK }), { address: VITALIK.toLowerCase(), source: "ens" });
  assert.deepEqual(await lookupName("@vitalik", { fetchImpl, neynarKey: "k" }), { address: VITALIK.toLowerCase(), source: "farcaster" });
  assert.deepEqual(await lookupName(PLAIN, { fetchImpl }), { address: PLAIN.toLowerCase(), source: "address" });
});

test("Solana names resolve to Solana addresses, never EVM trader identities", async () => {
  const solana = SOLANA;
  const calls = [];
  const fetchImpl = async (url) => {
    calls.push(String(url));
    return json({ s: "ok", result: solana });
  };
  assert.deepEqual(await lookupName("Bonfida.sol", { fetchImpl }), {
    address: solana, source: "sns", chain: "solana", name: "bonfida.sol",
  });
  assert.deepEqual(await lookupName("Bonfida.solana", { fetchImpl }), {
    address: solana, source: "sns", chain: "solana", name: "bonfida.sol",
  });
  assert.ok(calls.every((url) => url.includes("sdk-proxy-v2.sns.id/resolve/bonfida.sol")));

  const handler = createHandler({
    chain: { async accountByAddress() { throw new Error("Solana name reached Perpl"); } },
    fetchImpl, store: null, ens: null, ensAddress: async () => null,
  });
  const response = { status(code) { this.code = code; return this; }, json(body) { return { status: this.code, body }; }, setHeader() {} };
  const result = await handler({ method: "GET", query: { view: "lookup", q: "Bonfida.sol" } }, response);
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, { query: "Bonfida.sol", address: solana, name: "bonfida.sol", via: "sns", chain: "solana" });
});

test("Solana primary names preserve address case and never call EVM-only identity providers", async () => {
  const calls = [];
  const fetchImpl = async (url) => {
    calls.push(String(url));
    if (String(url).startsWith("https://sns-api.bonfida.com/v2/user/fav-domains/")) {
      return json({ [SOLANA]: "iamgifted" });
    }
    throw new Error(`unexpected ${url}`);
  };
  const store = memoryStore();
  const chain = { async accountByAddress() { throw new Error("Solana reached Perpl"); } };
  const identities = await resolveIdentities([SOLANA], { fetchImpl, chain, store, neynarKey: null });
  assert.equal(identities[SOLANA].address, SOLANA);
  assert.equal(identities[SOLANA].name, "iamgifted.sol");
  assert.equal(identities[SOLANA].source, "sns");
  assert.equal(calls.length, 1);
  assert.equal((await resolveIdentities([SOLANA], { fetchImpl, chain, store, neynarKey: null }))[SOLANA].name, "iamgifted.sol");
  assert.equal(calls.length, 1);
  const handler = createHandler({ chain, fetchImpl, store, ens: null });
  const response = { status(code) { this.code = code; return this; }, json(body) { return { status: this.code, body }; }, setHeader() {} };
  const result = await handler({ method: "GET", query: { view: "identity", addresses: SOLANA } }, response);
  assert.equal(result.status, 200);
  assert.equal(result.body.identities[SOLANA].name, "iamgifted.sol");
});

test("Solana Farcaster profile requires the exact verified address", async () => {
  const users = [
    { username: "unrelated", follower_count: 100_000, verified_addresses: { sol_addresses: [] } },
    { username: "owner", verified_addresses: { sol_addresses: [SOLANA] } },
  ];
  assert.equal(pickFarcasterUser(SOLANA, users)?.username, "owner");
  assert.equal(pickFarcasterUser(SOLANA, [users[0]]), null);
});

test("typed ENS name remains visible even when another profile is the primary identity", async () => {
  const { fetchImpl } = sources({ fun: { [VITALIK.toLowerCase()]: { nickname: "Different name" } } });
  const handler = createHandler({ chain: null, fetchImpl, store: null, ens: null, ensAddress: async () => VITALIK });
  const response = { status(code) { this.code = code; return this; }, json(body) { return { status: this.code, body }; }, setHeader() {} };
  const result = await handler({ method: "GET", query: { view: "lookup", q: "vitalik.eth" } }, response);
  assert.equal(result.status, 200);
  assert.equal(result.body.identity.name, "vitalik.eth");
  assert.equal(result.body.identity.source, "ens");
});

test("name-service outages are not reported as unregistered names", async () => {
  const handler = createHandler({ chain: null, store: null, ens: null, ensAddress: async () => { throw new Error("RPC down"); } });
  const response = { status(code) { this.code = code; return this; }, json(body) { return { status: this.code, body }; }, setHeader() {} };
  const result = await handler({ method: "GET", query: { view: "lookup", q: "vitalik.eth" } }, response);
  assert.equal(result.status, 503);
  assert.match(result.body.error, /unavailable/i);
});
