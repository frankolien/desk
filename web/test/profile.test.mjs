// node --test web/test/profile.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import { privateKeyToAccount } from "viem/accounts";

import { describeIdentity } from "../api/_identity.mjs";
import { cleanName, deskProfiles, imageType, profileMessage, readProfile, saveProfile } from "../api/_profile.mjs";
import { memoryStore } from "../api/_store.mjs";

const account = privateKeyToAccount("0x" + "11".repeat(32));
const NOW = 1_790_000_000_000;
// The smallest bytes that read as a JPEG and a PNG.
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46]).toString("base64");
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).toString("base64");

async function signed(overrides = {}, timestamp = NOW) {
  const address = account.address;
  const signature = await account.signMessage({ message: profileMessage(address, timestamp) });
  return { address, timestamp, signature, name: "heliben", image: JPEG, ...overrides };
}

test("names are cleaned and images are recognised by their bytes", () => {
  assert.equal(cleanName("  heli​ben  "), "heliben");
  assert.equal(cleanName("n".repeat(40)).length, 24);
  assert.equal(imageType(JPEG), "image/jpeg");
  assert.equal(imageType(PNG), "image/png");
  assert.equal(imageType(Buffer.from("hello world!").toString("base64")), null);
  assert.equal(imageType("not base64!!"), null);
});

test("a wallet sets its profile with a signature, and the resolver puts it first", async () => {
  const store = memoryStore();
  store.values.set(`id:${account.address.toLowerCase()}`, "{}");
  const saved = await saveProfile(store, await signed(), { now: NOW });
  assert.equal(saved.status, 200);
  assert.equal(saved.body.profile.name, "heliben");
  assert.match(saved.body.profile.avatar, /view=avatar&address=0x[0-9a-f]{40}&v=\d+$/);
  // The merged identity cache was dropped so the new profile is seen on the next read.
  assert.equal(store.values.has(`id:${account.address.toLowerCase()}`), false);

  const stored = await readProfile(store, account.address);
  assert.equal(stored.type, "image/jpeg");
  const profiles = await deskProfiles(store, [account.address.toLowerCase(), "0x" + "22".repeat(20)]);
  assert.equal(profiles.size, 1);

  const identity = describeIdentity(account.address.toLowerCase(), {
    desk: profiles.get(account.address.toLowerCase()),
    cast: { name: "someone-else", avatar: "https://fc.test/pfp.png", bio: "gm" },
  });
  assert.equal(identity.source, "desk");
  assert.equal(identity.name, "heliben");
  assert.match(identity.avatar, /view=avatar/);
  // What Desk does not carry is still borrowed from the other sources.
  assert.equal(identity.bio, "gm");
});

test("a wrong signature, another wallet's signature, or a stale one is refused", async () => {
  const store = memoryStore();
  const other = privateKeyToAccount("0x" + "22".repeat(32));
  const forged = await signed({ address: other.address });
  assert.equal((await saveProfile(store, forged, { now: NOW })).status, 401);
  const stale = await signed({}, NOW - 11 * 60_000);
  assert.equal((await saveProfile(store, stale, { now: NOW })).status, 400);
  const garbage = await signed({ signature: "0x" + "ab".repeat(65) });
  assert.equal((await saveProfile(store, garbage, { now: NOW })).status, 401);
  assert.equal(store.values.size, 0);
});

test("bad pictures and empty profiles are refused; a second save right away waits", async () => {
  const store = memoryStore();
  assert.equal((await saveProfile(store, await signed({ image: Buffer.from("plain text").toString("base64") }), { now: NOW })).status, 400);
  assert.equal((await saveProfile(store, await signed({ image: "A".repeat(200_000) }), { now: NOW })).status, 413);
  assert.equal((await saveProfile(store, await signed({ name: "", image: null }), { now: NOW })).status, 400);
  assert.equal((await saveProfile(store, await signed(), { now: NOW })).status, 200);
  assert.equal((await saveProfile(store, await signed({ name: "again" }), { now: NOW })).status, 429);
});

test("a save without a picture keeps the old one; an empty picture clears it", async () => {
  const store = memoryStore();
  assert.equal((await saveProfile(store, await signed(), { now: NOW })).status, 200);
  store.values.delete(`profile:rate:${account.address.toLowerCase()}`);
  const renamed = await saveProfile(store, await signed({ name: "heli", image: undefined }), { now: NOW + 1_000 });
  assert.equal(renamed.status, 200);
  assert.ok(renamed.body.profile.avatar);
  assert.equal((await readProfile(store, account.address)).name, "heli");
  store.values.delete(`profile:rate:${account.address.toLowerCase()}`);
  const cleared = await saveProfile(store, await signed({ name: "heli", image: "" }), { now: NOW + 2_000 });
  assert.equal(cleared.body.profile.avatar, null);
});
