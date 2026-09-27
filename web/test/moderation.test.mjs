// node --test web/test/moderation.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import { act, authorized, cleanReason, isProfileHidden, overview, report, reporter } from "../api/_moderation.mjs";
import { postMessage, readRoom, who } from "../api/_chat.mjs";
import { deskProfiles } from "../api/_profile.mjs";
import { createHandler } from "../api/activity.mjs";
import { memoryStore } from "../api/_store.mjs";

const phone = (c) => c.repeat(64);
const POSTER = phone("a");
const [A, B, C] = [phone("1"), phone("2"), phone("3")];
const WALLET = "0x52AC212e7187a799a7382C7A768cb35B72A3E20A";

const recorder = () => {
  const res = { status(code) { res.code = code; return res; }, json(body) { res.body = body; return res; }, setHeader() {}, send(body) { res.body = body; return res; } };
  return res;
};

test("a reporter is a hash, and a reason is cleaned and capped", () => {
  assert.notEqual(reporter(A), A);
  assert.equal(reporter(A).length, 16);
  assert.equal(cleanReason("  spam\u0000 spam  "), "spam spam");
  assert.equal(cleanReason("x".repeat(200)).length, 140);
});

test("three phones hide a message; three hidden messages block the poster; a moderator can undo it", async () => {
  const store = memoryStore();
  const ids = [];
  for (let i = 0; i < 3; i += 1) {
    const posted = await postMessage(store, { market: "BTC", install: POSTER, text: `gm ${i}` }, 1_000 + i);
    ids.push(posted.body.message.id);
  }
  const poster = who(POSTER);

  const first = await report(store, { kind: "message", install: A, market: "BTC", id: ids[0], who: poster });
  assert.equal(first.status, 200);
  assert.deepEqual([first.body.reports, first.body.hidden], [1, false]);
  // The same phone again does not count twice.
  const again = await report(store, { kind: "message", install: A, market: "BTC", id: ids[0], who: poster });
  assert.equal(again.body.reports, 1);
  await report(store, { kind: "message", install: B, market: "BTC", id: ids[0], who: poster });
  const third = await report(store, { kind: "message", install: C, market: "BTC", id: ids[0], who: poster });
  assert.deepEqual([third.body.reports, third.body.hidden, third.body.blocked], [3, true, false]);
  assert.deepEqual((await readRoom(store, { market: "BTC" })).body.messages.map((m) => m.id), [ids[1], ids[2]]);

  for (const id of [ids[1], ids[2]]) {
    for (const install of [A, B, C]) await report(store, { kind: "message", install, market: "BTC", id, who: poster });
  }
  assert.equal((await readRoom(store, { market: "BTC" })).body.messages.length, 0);
  const refused = await postMessage(store, { market: "BTC", install: POSTER, text: "again" }, 20_000);
  assert.equal(refused.status, 403);

  const view = await overview(store);
  assert.deepEqual(view.blockedWhos, [poster]);
  assert.equal(view.hiddenMessages.length, 3);
  assert.equal(view.reports.length, 10);
  assert.equal(view.reports[0].kind, "message");

  await act(store, { action: "unblock-who", who: poster });
  await act(store, { action: "unhide-message", id: ids[2] });
  assert.deepEqual((await overview(store)).blockedWhos, []);
  assert.deepEqual((await readRoom(store, { market: "BTC" })).body.messages.map((m) => m.id), [ids[2]]);
});

test("a reported profile is hidden from the identity resolver and can be unhidden", async () => {
  const store = memoryStore();
  await store.set(`profile:${WALLET.toLowerCase()}`, JSON.stringify({ name: "Alice", updatedAt: 1 }));
  assert.equal((await deskProfiles(store, [WALLET])).get(WALLET.toLowerCase())?.name, "Alice");
  for (const install of [A, B]) await report(store, { kind: "profile", install, address: WALLET });
  assert.equal(await isProfileHidden(store, WALLET), false);
  const third = await report(store, { kind: "profile", install: C, address: WALLET, reason: "impersonation" });
  assert.equal(third.body.hidden, true);
  assert.equal(await isProfileHidden(store, WALLET), true);
  assert.equal((await deskProfiles(store, [WALLET])).size, 0);
  await act(store, { action: "unhide-profile", address: WALLET });
  assert.equal(await isProfileHidden(store, WALLET), false);
});

test("bad reports are refused and a phone is limited to five a minute", async () => {
  const store = memoryStore();
  assert.equal((await report(store, { kind: "video", install: A })).status, 400);
  assert.equal((await report(store, { kind: "message", install: "nope", market: "BTC", id: "a-00000000" })).status, 401);
  assert.equal((await report(store, { kind: "message", install: A, market: "btc!", id: "a-00000000" })).status, 400);
  assert.equal((await report(store, { kind: "profile", install: A, address: "0x12" })).status, 400);
  assert.equal((await act(store, { action: "block-who", who: "not-a-hash" })).status, 400);
  for (let i = 0; i < 5; i += 1) {
    assert.equal((await report(store, { kind: "profile", install: A, address: WALLET.replace(/0A$/, String(i).padStart(2, "0")) })).status, 200);
  }
  assert.equal((await report(store, { kind: "profile", install: A, address: WALLET })).status, 429);
});

test("the activity function takes a message report from anyone and moderation only with the secret", async () => {
  const store = memoryStore();
  const handler = createHandler(async () => { throw new Error("no network"); }, () => "key", { store });
  const posted = await handler({ method: "POST", query: { view: "chat" }, body: { market: "BTC", install: POSTER, text: "hello" } }, recorder());
  const id = posted.body.message.id;
  const reported = await handler({ method: "POST", query: { view: "chat-report" }, body: { install: A, market: "BTC", id, who: who(POSTER) } }, recorder());
  assert.equal(reported.code, 200);
  assert.equal(reported.body.reported, true);

  const previous = process.env.CRON_SECRET;
  process.env.CRON_SECRET = "s3cret";
  try {
    const denied = await handler({ method: "GET", query: { view: "moderation" }, headers: {} }, recorder());
    assert.equal(denied.code, 401);
    const seen = await handler({ method: "GET", query: { view: "moderation" }, headers: { authorization: "Bearer s3cret" } }, recorder());
    assert.equal(seen.code, 200);
    assert.equal(seen.body.reports.length, 1);
    const acted = await handler({ method: "POST", query: { view: "moderation" }, headers: { authorization: "Bearer s3cret" }, body: { action: "hide-message", id } }, recorder());
    assert.equal(acted.code, 200);
    assert.equal((await readRoom(store, { market: "BTC" })).body.messages.length, 0);
    assert.equal(authorized({ headers: { authorization: "Bearer wrong" } }, "s3cret"), false);
  } finally {
    if (previous === undefined) delete process.env.CRON_SECRET; else process.env.CRON_SECRET = previous;
  }
});
