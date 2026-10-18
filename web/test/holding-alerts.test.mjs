import assert from "node:assert/strict";
import { test } from "node:test";

import { carryTold, holdingDeliveries, holdingEvent, holdingPayload, parseHoldingAlerts, stepLevel } from "../api/_holding-alerts.mjs";
import { parseSubscription } from "../api/alerts.mjs";

const MON = "0x3bd359c1119da7da1d913d1c4d2b7c461115433a";
const CHOG = "0xaaaa000000000000000000000000000000000001";
const INSTALL = "ab".repeat(32);
const TOKEN = "cd".repeat(32);
const alert = (overrides = {}) => ({ chainIndex: "143", contract: MON, symbol: "MON", anchor: 0.02, step: 0.05, up: true, down: true, told: 0, ...overrides });

test("holding alerts are validated: a chain, a token, the price paid and a 5, 10 or 20 percent step", () => {
  const parsed = parseHoldingAlerts([{ chainIndex: "143", contract: MON.toUpperCase().replace("0X", "0x"), symbol: "MON", anchor: 0.02, step: 0.05 }]);
  assert.deepEqual(parsed, [alert()]);
  assert.equal(parseHoldingAlerts(null).length, 0);
  assert.equal(parseHoldingAlerts("nope"), null, "not a list: refused");
  // A row that cannot be read is dropped on its own; the rows beside it still count.
  assert.deepEqual(parseHoldingAlerts([{ chainIndex: "143", contract: MON, anchor: 0.02, step: 0.07 }, alert()]), [alert()]);
  assert.deepEqual(parseHoldingAlerts([{ chainIndex: "143", contract: "0x12", anchor: 0.02, step: 0.05 }]), []);
  assert.deepEqual(parseHoldingAlerts([{ chainIndex: "143", contract: MON, anchor: 0, step: 0.05 }]), []);
  assert.equal(parseHoldingAlerts(Array(31).fill({ chainIndex: "143", contract: MON, anchor: 1, step: 0.05 })).length, 1, "the list is cut at 30, then deduplicated");
  // Neither direction wanted is no alert; the same token twice is one alert.
  assert.equal(parseHoldingAlerts([{ chainIndex: "143", contract: MON, anchor: 1, step: 0.05, up: false, down: false }]).length, 0);
  assert.equal(parseHoldingAlerts([alert(), alert({ step: 0.1 })]).length, 1);
  const sub = parseSubscription({ install: INSTALL, token: TOKEN, environment: "sandbox", traders: [], holdings: [alert()] });
  assert.equal(sub.record.holdings.length, 1);
  assert.equal(sub.wantsPrices, true);
});

test("steps are counted from the price paid, with a margin so a price on the line rings once", () => {
  const a = alert();
  assert.equal(stepLevel(a, 0.02), 0);
  assert.equal(stepLevel(a, 0.0209), 0, "up 4.5%: not a step yet");
  assert.equal(stepLevel(a, 0.0210), 0, "up exactly 5%: on the line, no margin yet");
  assert.equal(stepLevel(a, 0.02135), 1, "up 6.75%: a third past the line");
  assert.equal(stepLevel(a, 0.0176), -2, "down 12%: two steps, no margin needed for a jump of two");
  assert.equal(stepLevel(a, 0.0189), 0, "down 5.5%: only just past the line, not yet");
  assert.equal(stepLevel(a, 0.0186), -1, "down 7%: a step down");
  // Once told of -1, drifting back to 3% down does not re-arm; coming back within 2% of the price paid is even.
  assert.equal(stepLevel(alert({ told: -1 }), 0.0194), -1);
  assert.equal(stepLevel(alert({ told: -1 }), 0.0204), 0, "back to the price paid: level 0 again");
  assert.equal(stepLevel(alert({ told: -1 }), 0.0228), 2, "from 5% down to 14% up: a flip to two steps up");
  assert.equal(stepLevel(alert({ told: 2 }), 0.0214), 2, "from 14% up back to 7% up: nothing yet");
});

test("an event names the direction and the move since purchase, and quiet directions still advance", () => {
  const down = holdingEvent(alert(), 0.0186);
  assert.equal(down.alert.told, -1);
  assert.equal(down.event.direction, "down");
  assert.equal(down.event.percent, -7);
  const payload = holdingPayload(alert(), down.event);
  assert.equal(payload.aps.alert.title, "Your token is down");
  assert.match(payload.aps.alert.body, /^MON is down 7\.0% since you bought 🔴 · \$0\.0186$/);
  const even = holdingPayload(alert({ told: -1 }), holdingEvent(alert({ told: -1 }), 0.0203).event);
  assert.match(even.aps.alert.body, /^MON is back to what you paid 🟢/);
  assert.equal(payload.desk.type, "holding");
  assert.equal(payload.desk.token, MON);

  const quiet = holdingEvent(alert({ up: false }), 0.0226);
  assert.equal(quiet.alert.told, 2);
  assert.equal(quiet.event, null, "up 13% with up alerts off: remembered, not sent");
  assert.equal(holdingEvent(alert(), 0.0201), null, "no new step: nothing");
  assert.equal(holdingEvent(alert(), undefined), null, "no price: nothing");
});

test("a re-sync keeps what the server already told, unless the anchor or step changed", () => {
  const kept = carryTold([alert(), alert({ contract: CHOG, symbol: "CHOG", anchor: 1 })], [alert({ told: -2 }), alert({ contract: CHOG, symbol: "CHOG", anchor: 1.5, told: 3 })]);
  assert.equal(kept[0].told, -2);
  assert.equal(kept[1].told, 0, "a new anchor starts over");
});

test("deliveries read each token once, push per person per new step, and hand back the records to store", async () => {
  const asked = [];
  const prices = async (chainIndex, contracts) => {
    asked.push([chainIndex, [...contracts].sort()]);
    return new Map([[MON, 0.0186], [CHOG, 1.3]]);
  };
  const subscribers = [
    { id: "a", record: { token: "t1", holdings: [alert(), alert({ contract: CHOG, symbol: "CHOG", anchor: 1, step: 0.2 })] } },
    { id: "b", record: { token: "t2", holdings: [alert({ down: false })] } },
    { id: "c", record: { token: "t3" } },
  ];
  const out = await holdingDeliveries({ subscribers, prices });
  assert.deepEqual(asked, [["143", [MON, CHOG].sort()]]);
  assert.equal(out.events, 2, "a hears MON down and CHOG up; b has down alerts off");
  assert.deepEqual(out.deliveries.map((d) => [d.id, d.payload.desk.symbol, d.payload.desk.direction]), [["a", "MON", "down"], ["a", "CHOG", "up"]]);
  const changed = new Map(out.changed);
  assert.equal(changed.get("a").holdings[0].told, -1);
  assert.equal(changed.get("a").holdings[1].told, 1);
  assert.equal(changed.get("b").holdings[0].told, -1, "b's level moved on silently");
  assert.equal(changed.has("c"), false);
  assert.equal(out.deliveries[0].record.holdings[0].told, -1, "the delivery carries the updated record");

  const again = await holdingDeliveries({ subscribers: [...changed].map(([id, record]) => ({ id, record })), prices });
  assert.equal(again.events, 0, "the same price the next scan says nothing new");
});
