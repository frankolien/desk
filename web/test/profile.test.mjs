import assert from "node:assert/strict";
import { test } from "node:test";
import { privateKeyToAccount } from "viem/accounts";

import { describeIdentity } from "../api/_identity.mjs";
import { cleanName, cleanTag, deleteMessage, deleteProfile, deskProfiles, imageType, profileMessage, readProfile, saveProfile, tagAvailability, tagOwner } from "../api/_profile.mjs";
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

test("a profile is deleted only with a delete signature from its wallet", async () => {
  const store = memoryStore();
  assert.equal((await saveProfile(store, await signed(), { now: NOW })).status, 200);
  assert.ok(await readProfile(store, account.address));

  const save = await signed();
  const replay = await deleteProfile(store, { address: save.address, timestamp: save.timestamp, signature: save.signature }, { now: NOW });
  assert.equal(replay.status, 401);
  assert.ok(await readProfile(store, account.address));

  const signature = await account.signMessage({ message: deleteMessage(account.address, NOW) });
  const outcome = await deleteProfile(store, { address: account.address, timestamp: NOW, signature }, { now: NOW });
  assert.equal(outcome.status, 200);
  assert.equal(await readProfile(store, account.address), null);
});

test("tags are cleaned, reserved names refused, and a tag is first come first served", async () => {
  assert.deepEqual(cleanTag("@Frank"), { tag: "frank" });
  assert.deepEqual(cleanTag("frank.desk"), { tag: "frank" });
  assert.deepEqual(cleanTag(""), { tag: "" });
  assert.match(cleanTag("fr").error, /at least 3/);
  assert.match(cleanTag("1frank").error, /starting with a letter/);
  assert.match(cleanTag("fr ank").error, /Letters, numbers/);
  assert.match(cleanTag("desk").error, /reserved/);
  assert.match(cleanTag("a".repeat(21)).error, /at most 20/);

  const store = memoryStore();
  const first = await saveProfile(store, await signed({ tag: "@Frank", image: undefined, name: "" }), { now: NOW });
  assert.equal(first.status, 200);
  assert.equal(first.body.profile.tag, "frank");
  assert.equal(await tagOwner(store, "frank"), account.address.toLowerCase());
  assert.deepEqual((await tagAvailability(store, "frank")).body, { tag: "frank", available: false, address: account.address.toLowerCase() });
  assert.deepEqual((await tagAvailability(store, "ada")).body, { tag: "ada", available: true, address: null });

  const other = privateKeyToAccount("0x" + "22".repeat(32));
  const otherSignature = await other.signMessage({ message: profileMessage(other.address, NOW + 1) });
  const taken = await saveProfile(store, { address: other.address, timestamp: NOW + 1, signature: otherSignature, name: "Ada", tag: "frank" }, { now: NOW + 1 });
  assert.equal(taken.status, 409);
  assert.equal(await tagOwner(store, "frank"), account.address.toLowerCase());

  // The profile keeps its tag when a save leaves the field out, and frees it when changed.
  const rested = () => store.values.delete(`profile:rate:${account.address.toLowerCase()}`);
  rested();
  const unchanged = await saveProfile(store, await signed({ name: "Frank O", image: undefined }, NOW + 30_000), { now: NOW + 30_000 });
  assert.equal(unchanged.body.profile.tag, "frank");
  rested();
  const renamed = await saveProfile(store, await signed({ name: "Frank O", tag: "franko", image: undefined }, NOW + 60_000), { now: NOW + 60_000 });
  assert.equal(renamed.body.profile.tag, "franko");
  assert.equal(await tagOwner(store, "frank"), null);
  assert.equal(await tagOwner(store, "franko"), account.address.toLowerCase());

  // The merged identity carries the tag, and a tag alone is a name.
  const profiles = await deskProfiles(store, [account.address]);
  const identity = describeIdentity(account.address.toLowerCase(), { desk: profiles.get(account.address.toLowerCase()) });
  assert.equal(identity.tag, "franko");
  assert.equal(identity.name, "Frank O");
  const tagOnly = describeIdentity("0xabc", { desk: { tag: "ada" } });
  assert.equal(tagOnly.name, "@ada");
  assert.equal(tagOnly.source, "desk");

  const deleteSignature = await account.signMessage({ message: deleteMessage(account.address, NOW + 90_000) });
  await deleteProfile(store, { address: account.address, timestamp: NOW + 90_000, signature: deleteSignature }, { now: NOW + 90_000 });
  assert.equal(await tagOwner(store, "franko"), null);
});
