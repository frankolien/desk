// A live Relay route for the fork test: AUSD on Monad from `user` (the DeskSend contract) to a
// recipient on another chain. Prints abi.encode(address[] to, bytes[] data) of the quote's
// transaction steps, in order, for the test to feed through DeskSend.send.
//   node test/relay-send.mjs <user> <amountRaw> <destinationChainId> <destinationCurrency> <recipient> <refundTo>
import { encodeAbiParameters } from "../../web/node_modules/viem/_esm/index.js";

const [user, amount, destinationChainId, destinationCurrency, recipient, refundTo] = process.argv.slice(2);
const response = await fetch("https://api.relay.link/quote", {
  method: "POST", headers: { "content-type": "application/json" },
  body: JSON.stringify({
    user, recipient, refundTo, originChainId: 143, destinationChainId: Number(destinationChainId),
    originCurrency: "0x00000000efe302beaa2b3e6e1b18d08d69a9012a", destinationCurrency, amount, tradeType: "EXACT_INPUT",
  }),
});
const quote = await response.json();
if (!response.ok) { console.error(JSON.stringify(quote).slice(0, 300)); process.exit(1); }
const calls = quote.steps.filter((step) => step.kind === "transaction").flatMap((step) => step.items.map((item) => item.data));
process.stdout.write(encodeAbiParameters(
  [{ type: "address[]" }, { type: "bytes[]" }],
  [calls.map((call) => call.to), calls.map((call) => call.data)],
));
