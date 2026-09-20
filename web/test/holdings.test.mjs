import test from "node:test";
import assert from "node:assert/strict";
import { describeHolding } from "../api/_holdings.mjs";

test("a balance is written in the token's own units, truncated to six places", () => {
  // 1234.5678901 with 18 decimals
  const raw = "0x" + (1234567890100000000000n).toString(16);
  const held = describeHolding(raw, 18, 2);
  assert.equal(held.balance, "1234.56789");
  assert.equal(held.units, 1234.5678901);
  assert.equal(held.value, 2469.1357802);
});

test("a whole balance carries no point", () => {
  assert.equal(describeHolding("0x" + (5n * 10n ** 6n).toString(16), 6, null).balance, "5");
});

test("no price means no value, not a zero", () => {
  const held = describeHolding("0x1", 0, null);
  assert.equal(held.value, null);
  assert.equal(held.price, null);
});

test("an empty or malformed result is not a balance", () => {
  assert.equal(describeHolding("0x", 18, 1).balance, "0");
  assert.equal(describeHolding("nope", 18, 1), null);
  assert.equal(describeHolding(undefined, 18, 1), null);
});
