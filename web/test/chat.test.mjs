// node --test web/test/chat.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import { cleanName, cleanText, MAX_TEXT, postMessage, readRoom, ROOM_CAP, who } from "../api/_chat.mjs";
import { createHandler } from "../api/activity.mjs";
import { memoryStore } from "../api/_store.mjs";

const INSTALL = "a".repeat(64);
const OTHER = "b".repeat(64);
const ME = "0x82EC56aaf7aA35C6ac62B598E6C964a4B186f775";

function recorder() {
  const out = { status: null, body: null };
  return {
    status(code) { out.status = code; return this; },
    json(value) { out.body = value; return out; },
    setHeader() {},
  };
}

test("text is trimmed, flattened, stripped of control characters and capped", () => {
  assert.equal(cleanText("  gm\n\n  everyone\u0000 "), "gm everyone");
  assert.equal(cleanText("x".repeat(MAX_TEXT + 50)).length, MAX_TEXT);
  assert.equal(cleanText("   "), "");
  assert.equal(cleanName(" heliben\u200b "), "heliben");
  assert.equal(cleanName("n".repeat(40)).length, 24);
});

test("a phone's identity in the room is a hash, never the install secret", () => {
  assert.equal(who(INSTALL).length, 16);
  assert.notEqual(who(INSTALL), who(OTHER));
  assert.ok(!who(INSTALL).includes(INSTALL.slice(0, 8)));
});

test("a message is posted, read back oldest first, and the poster counts as present", async () => {
  const store = memoryStore();
  const first = await postMessage(store, { market: "btc", install: INSTALL, address: ME, name: "heliben", text: "gm" }, 1_000);
  assert.equal(first.status, 200);
  assert.equal(first.body.message.address, ME.toLowerCase());
  assert.equal(first.body.message.name, "heliben");
  assert.ok(!("install" in first.body.message));
  await postMessage(store, { market: "BTC", install: OTHER, text: "up only" }, 2_000);

  const room = await readRoom(store, { market: "BTC", install: "c".repeat(64) }, 3_000);
  assert.equal(room.status, 200);
  assert.deepEqual(room.body.messages.map((m) => m.text), ["gm", "up only"]);
  assert.equal(room.body.messages[1].address, null);
  assert.equal(room.body.here, 3);

  // Two minutes on, the early posters have left; the reader is still there.
  const later = await readRoom(store, { market: "BTC", install: "c".repeat(64) }, 3_000 + 121_000);
  assert.equal(later.body.here, 1);
});

test("a fourth message inside ten seconds is refused, and the room is capped", async () => {
  const store = memoryStore();
  for (let index = 0; index < 3; index += 1) {
    assert.equal((await postMessage(store, { market: "ETH", install: INSTALL, text: `m${index}` })).status, 200);
  }
  assert.equal((await postMessage(store, { market: "ETH", install: INSTALL, text: "m3" })).status, 429);
  for (let index = 0; index < ROOM_CAP + 20; index += 1) {
    await postMessage(store, { market: "SOL", install: `${index}`.padStart(64, "0"), text: `m${index}` });
  }
  assert.equal(store.lists.get("chat:room:SOL").length, ROOM_CAP);
});

test("bad input is refused before anything is stored", async () => {
  const store = memoryStore();
  assert.equal((await postMessage(store, { market: "b t c", install: INSTALL, text: "x" })).status, 400);
  assert.equal((await postMessage(store, { market: "BTC", install: "short", text: "x" })).status, 401);
  assert.equal((await postMessage(store, { market: "BTC", install: INSTALL, text: "   " })).status, 400);
  assert.equal((await readRoom(store, { market: "" })).status, 400);
  assert.equal(store.lists.size, 0);
});

test("the activity function routes the room on GET and POST", async () => {
  const store = memoryStore();
  const handler = createHandler(async () => { throw new Error("no network"); }, () => "key", { store });
  const posted = await handler({ method: "POST", query: { view: "chat" }, body: { market: "BTC", install: INSTALL, text: "hello" } }, recorder());
  assert.equal(posted.status, 200);
  const read = await handler({ method: "GET", query: { view: "chat", market: "BTC", install: OTHER } }, recorder());
  assert.equal(read.status, 200);
  assert.equal(read.body.messages[0].text, "hello");
  assert.equal(read.body.here, 2);
});
