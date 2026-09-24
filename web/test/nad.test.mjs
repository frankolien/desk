// node --test web/test/nad.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import { decodeFunctionData, namehash } from "viem";

import { CONTROLLER, NNS, cleanLabel, controllerAbi, nnsAbi, node, registerCalldata, setPrimaryCalldata, setRecordsCalldata } from "../api/_nad.mjs";

test("labels are lower-case letters, digits and hyphens, with or without the suffix", () => {
  assert.equal(cleanLabel(" Olien.nad "), "olien");
  assert.equal(cleanLabel("monad-trader"), "monad-trader");
  assert.equal(cleanLabel("-bad"), null);
  assert.equal(cleanLabel("has space"), null);
  assert.equal(cleanLabel(""), null);
  assert.equal(cleanLabel("x".repeat(33)), null);
});

test("the node is the ENS namehash of label.nad, which is what the contract resolves", () => {
  assert.equal(node("salmo"), namehash("salmo.nad"));
});

test("record and primary calldata target the name service with the right arguments", () => {
  const records = setRecordsCalldata("olien", { avatar: "https://a.test/p.jpg", description: "trader", ignored: "x" });
  assert.equal(records.to, NNS);
  const decoded = decodeFunctionData({ abi: nnsAbi, data: records.data });
  assert.equal(decoded.functionName, "setNameAttributes");
  assert.equal(decoded.args[0], node("olien"));
  assert.deepEqual(decoded.args[1], [{ key: "avatar", value: "https://a.test/p.jpg" }, { key: "description", value: "trader" }]);
  assert.equal(setRecordsCalldata("olien", { ignored: "x" }), null);

  const primary = setPrimaryCalldata("olien", "0x03508bb71268bba25ecacc8f620e01866650532c");
  const p = decodeFunctionData({ abi: nnsAbi, data: primary.data });
  assert.equal(p.functionName, "setPrimaryNameForAddress");
  assert.deepEqual([p.args[0], p.args[1].toLowerCase()], ["olien", "0x03508bb71268bba25ecacc8f620e01866650532c"]);
});

test("registration calldata carries nad's signed params, the price as value, and the controller as target", () => {
  const params = {
    name: "olien", nameOwner: "0x03508bb71268bba25ecacc8f620e01866650532c", setAsPrimaryName: true,
    referrer: "0x0000000000000000000000000000000000000000", discountKey: "0x" + "00".repeat(32), discountClaimProof: "0x",
    nonce: 1n, deadline: 1790000000n, attributes: [{ key: "avatar", value: "x" }], paymentToken: "0x0000000000000000000000000000000000000000",
  };
  const built = registerCalldata(params, "0x" + "ab".repeat(65), "488000000000000000000");
  assert.equal(built.to, CONTROLLER);
  assert.equal(built.value, "488000000000000000000");
  const d = decodeFunctionData({ abi: controllerAbi, data: built.data });
  assert.equal(d.functionName, "registerWithSignature");
  assert.equal(d.args[0].name, "olien");
  assert.equal(d.args[0].setAsPrimaryName, true);
  assert.equal(built.data.slice(0, 10), "0x623f1166");
});
