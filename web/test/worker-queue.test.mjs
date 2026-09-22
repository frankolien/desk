import assert from "node:assert/strict";
import { test } from "node:test";
import { selectWallets } from "../worker/queue.mjs";

test("new follows go first without starving the rest of the index queue", () => {
  const tracked = Array.from({ length: 12 }, (_, i) => `wallet-${i}`);
  const first = selectWallets(tracked, ["wallet-11", "wallet-10", "not-tracked"], 0, 5, 2);
  assert.deepEqual(first.wallets, ["wallet-11", "wallet-10", "wallet-0", "wallet-1", "wallet-2"]);
  const next = selectWallets(tracked, ["wallet-11", "wallet-10"], first.nextCursor, 5, 2);
  assert.deepEqual(next.wallets, ["wallet-11", "wallet-10", "wallet-3", "wallet-4", "wallet-5"]);
});
