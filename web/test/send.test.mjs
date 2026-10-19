import assert from "node:assert/strict";
import { test } from "node:test";
import { privateKeyToAccount } from "viem/accounts";
import { decodeFunctionData } from "viem";

import {
  AUSD, K, MONAD, RELAY_DEPOSITORY, SEND_ABI, SEND_CONTRACT, SOLANA, USDC_SOLANA,
  amountRaw, checkCalls, createSendWorker, destinationOf, hashCalls, permitTypedData, prepare, sendCalldata, sendTypedData, status, submit, transferCall,
} from "../api/_send.mjs";
import { memoryStore } from "../api/_store.mjs";

const wallet = privateKeyToAccount("0x7c56100e187f2845a35ce856646662dfc2024be2b4a150b45ad1f62564617128");
const FRIEND = "0x000000000000000000000000000000000000b0b0";
const SOL = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM";
const nonces = async () => "7";
const fixedNow = () => 1_792_350_000_000;

const relayQuote = (user) => ({
  steps: [
    { id: "approve", kind: "transaction", requestId: "0x" + "ab".repeat(32), items: [{ data: { from: user, to: AUSD, data: "0x095ea7b3" + RELAY_DEPOSITORY.slice(2).padStart(64, "0") + (20_000_000).toString(16).padStart(64, "0"), value: "0", chainId: 143 } }] },
    { id: "deposit", kind: "transaction", requestId: "0x" + "ab".repeat(32), items: [{ data: { from: user, to: RELAY_DEPOSITORY, data: "0xe8017952" + user.slice(2).padStart(64, "0"), value: "0", chainId: 143 } }] },
  ],
  details: { currencyOut: { amount: "19964581", amountFormatted: "19.964581", currency: { symbol: "USDC" } }, timeEstimate: 1, totalImpact: { percent: "-0.16" } },
  fees: { relayer: { amountUsd: "0.025995" }, app: { amountUsd: "0" } },
});
const relayFetch = (reply = relayQuote) => async (url, init) => {
  if (!String(url).includes("relay.link/quote")) return { ok: false, status: 404, json: async () => ({}) };
  const body = JSON.parse(init.body);
  const out = reply(body.user, body);
  return { ok: !out.errorCode, status: out.errorCode ? 400 : 200, json: async () => out };
};

const signPair = async (body) => ({
  signature: await wallet.signTypedData({ domain: { ...body.typedData.send.domain, chainId: 143n }, types: { Send: body.typedData.send.types.Send }, primaryType: "Send", message: { ...body.intent, amount: BigInt(body.intent.amount), nonce: BigInt(body.intent.nonce), deadline: BigInt(body.intent.deadline) } }),
  permit: await wallet.signTypedData({ domain: { ...body.typedData.permit.domain, chainId: 143n }, types: { Permit: body.typedData.permit.types.Permit }, primaryType: "Permit", message: { owner: wallet.address.toLowerCase(), spender: body.contract, value: BigInt(body.intent.amount), nonce: BigInt(body.intent.nonce), deadline: BigInt(body.intent.deadline) } }),
});

test("a destination is read off the address: Solana by its shape, EVM by the chain named, Monad by default", () => {
  assert.equal(destinationOf({ to: SOL }).chainId, SOLANA);
  assert.equal(destinationOf({ to: SOL }).symbol, "USDC");
  assert.equal(destinationOf({ to: FRIEND }).chainId, MONAD);
  assert.equal(destinationOf({ to: FRIEND, chainId: "8453" }).name, "Base");
  assert.equal(destinationOf({ to: FRIEND, chainId: 56 }), null, "no AUSD on BNB: refused, not guessed");
  assert.equal(destinationOf({ to: "not an address" }), null);
  assert.equal(amountRaw("20"), 20_000_000n);
  assert.equal(amountRaw("0.5"), 500_000n);
  assert.equal(amountRaw("1e3"), null);
});

test("the calls are fenced the way DeskSend fences them", () => {
  const monad = { chainId: MONAD, recipient: FRIEND };
  assert.equal(checkCalls([transferCall(FRIEND, 20_000_000n)], { destination: monad, amount: 20_000_000n }), null);
  assert.match(checkCalls([transferCall(wallet.address, 20_000_000n)], { destination: monad, amount: 20_000_000n }), /not to the recipient/);
  assert.match(checkCalls([{ to: FRIEND, data: "0x" }], { destination: monad, amount: 1n }), /call to/);
  const solana = { chainId: SOLANA, recipient: SOL };
  const quote = relayQuote(SEND_CONTRACT);
  const calls = quote.steps.flatMap((s) => s.items.map((i) => ({ to: i.data.to, data: i.data.data, value: "0" })));
  assert.equal(checkCalls(calls, { destination: solana, amount: 20_000_000n }), null);
  const stranger = [{ to: AUSD, data: "0x095ea7b3" + FRIEND.slice(2).padStart(64, "0") + "1".padStart(64, "0") }, calls[1]];
  assert.match(checkCalls(stranger, { destination: solana, amount: 20_000_000n }), /stranger/);
  assert.match(checkCalls([transferCall(FRIEND, 1n)], { destination: solana, amount: 1n }), /cross-chain/);
});

test("prepare: a Monad send is one transfer, a Solana send is Relay's approve and deposit from DeskSend, each with both things to sign", async () => {
  const store = memoryStore();
  const monad = await prepare({ store, fetchImpl: relayFetch(), nonces, user: wallet.address, to: FRIEND, amount: "20", now: fixedNow });
  assert.equal(monad.status, 200, JSON.stringify(monad.body));
  assert.equal(monad.body.calls.length, 1);
  assert.equal(monad.body.arrives, "20.00");
  assert.equal(monad.body.feeUsd, 0);
  assert.equal(monad.body.intent.nonce, "7");
  assert.equal(monad.body.intent.callsHash, hashCalls(monad.body.calls));
  assert.equal(monad.body.typedData.send.domain.verifyingContract, SEND_CONTRACT);
  assert.equal(monad.body.typedData.permit.message.spender, SEND_CONTRACT);
  assert.equal(monad.body.typedData.permit.message.value, "20000000");
  assert.equal(monad.body.contract, SEND_CONTRACT);

  const solana = await prepare({ store, fetchImpl: relayFetch(), nonces, user: wallet.address, to: SOL, amount: "20", now: fixedNow });
  assert.equal(solana.status, 200, JSON.stringify(solana.body));
  assert.equal(solana.body.chain, "Solana");
  assert.equal(solana.body.symbol, "USDC");
  assert.equal(solana.body.arrives, "19.964581");
  assert.equal(solana.body.feeUsd, 0.026);
  assert.equal(solana.body.calls.length, 2);
  assert.equal(solana.body.calls[1].to, RELAY_DEPOSITORY);
  const prep = JSON.parse(await store.get(K.prep(solana.body.id)));
  assert.equal(prep.requestId, "0x" + "ab".repeat(32));

  // Relay was asked for DeskSend as the depositor, the wallet as the refund address, USDC on Solana out.
  let asked;
  await prepare({ store, fetchImpl: async (url, init) => { asked = JSON.parse(init.body); return { ok: true, status: 200, json: async () => relayQuote(asked.user) }; }, nonces, user: wallet.address, to: SOL, amount: "20", now: fixedNow });
  assert.equal(asked.user, SEND_CONTRACT);
  assert.equal(asked.refundTo, wallet.address);
  assert.equal(asked.recipient, SOL);
  assert.equal(asked.destinationCurrency, USDC_SOLANA);
});

test("prepare refuses what cannot be sent: below a dollar, to itself, to a chain without AUSD, a lossy route, a route with a stranger's call", async () => {
  const store = memoryStore();
  assert.equal((await prepare({ store, fetchImpl: relayFetch(), nonces, user: wallet.address, to: FRIEND, amount: "0.5" })).body.reason, "amount-too-low");
  assert.equal((await prepare({ store, fetchImpl: relayFetch(), nonces, user: wallet.address, to: wallet.address, amount: "5" })).body.reason, "self");
  assert.equal((await prepare({ store, fetchImpl: relayFetch(), nonces, user: wallet.address, to: FRIEND, chainId: 56, amount: "5" })).body.reason, "unsupported-destination");
  const lossy = await prepare({ store, fetchImpl: relayFetch((user) => ({ ...relayQuote(user), details: { ...relayQuote(user).details, totalImpact: { percent: "-2.4" } } })), nonces, user: wallet.address, to: SOL, amount: "20" });
  assert.equal(lossy.body.reason, "impact");
  const odd = await prepare({ store, fetchImpl: relayFetch((user) => { const q = relayQuote(user); q.steps[1].items[0].data.to = FRIEND; return q; }), nonces, user: wallet.address, to: SOL, amount: "20" });
  assert.equal(odd.body.reason, "unsupported-route");
  const none = await prepare({ store, fetchImpl: relayFetch(() => ({ errorCode: "NO_SWAP_ROUTES_FOUND" })), nonces, user: wallet.address, to: SOL, amount: "20" });
  assert.equal(none.status, 422);
  assert.match(none.body.error, /No route/);
});

test("submit takes the wallet's two signatures and queues once; a stranger's or a replay is refused", async () => {
  const store = memoryStore();
  const prepared = await prepare({ store, fetchImpl: relayFetch(), nonces, user: wallet.address, to: SOL, amount: "20", now: fixedNow });
  const pair = await signPair(prepared.body);
  const stranger = privateKeyToAccount(`0x${"22".repeat(32)}`);
  const forged = await stranger.signTypedData({ domain: { ...prepared.body.typedData.send.domain, chainId: 143n }, types: { Send: prepared.body.typedData.send.types.Send }, primaryType: "Send", message: { ...prepared.body.intent, amount: 20_000_000n, nonce: 7n, deadline: BigInt(prepared.body.intent.deadline) } });
  assert.equal((await submit({ store, body: { id: prepared.body.id, signature: forged, permit: pair.permit }, now: fixedNow })).status, 401);
  assert.equal((await submit({ store, body: { id: prepared.body.id, signature: "0x12", permit: pair.permit }, now: fixedNow })).status, 400);

  const ok = await submit({ store, body: { id: prepared.body.id, ...pair }, now: fixedNow });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.equal(await store.lpop(K.jobs), prepared.body.id);
  const job = JSON.parse(await store.get(K.job(prepared.body.id)));
  assert.equal(job.status, "queued");
  assert.equal(job.signature, pair.signature);
  assert.equal((await submit({ store, body: { id: prepared.body.id, ...pair }, now: fixedNow })).status, 410, "the preparation is spent");

  const expired = await prepare({ store, fetchImpl: relayFetch(), nonces, user: wallet.address, to: FRIEND, amount: "5", now: fixedNow });
  assert.equal((await submit({ store, body: { id: expired.body.id, ...(await signPair(expired.body)) }, now: () => fixedNow() + 200_000 })).status, 410);

  const st = await status({ store, id: prepared.body.id });
  assert.equal(st.body.status, "queued");
  assert.equal(st.body.destination.chain, "Solana");
});

test("the worker simulates, sends and records; a revert in simulation fails the job without a transaction", async () => {
  const store = memoryStore();
  const prepared = await prepare({ store, fetchImpl: relayFetch(), nonces, user: wallet.address, to: SOL, amount: "20", now: fixedNow });
  await submit({ store, body: { id: prepared.body.id, ...(await signPair(prepared.body)) }, now: fixedNow });
  const sent = [];
  const chain = {
    simulate: async ({ to, data }) => { if (to !== SEND_CONTRACT) throw new Error("wrong contract"); decodeFunctionData({ abi: SEND_ABI, data }); },
    send: async ({ to, data }) => { sent.push({ to, data }); return "0x" + "11".repeat(32); },
    wait: async () => ({ status: "success" }),
  };
  const worker = createSendWorker({ store, chain, logger: { log() {}, warn() {}, error() {} }, now: fixedNow });
  assert.equal(await worker.tick(), 1);
  assert.equal(sent.length, 1);
  const { args } = decodeFunctionData({ abi: SEND_ABI, data: sent[0].data });
  assert.equal(args[0].from.toLowerCase(), wallet.address.toLowerCase());
  assert.equal(args[0].amount, 20_000_000n);
  assert.equal(args[5].length, 2, "approve and deposit");
  assert.equal(args[2], 27 + Number.parseInt(JSON.parse(await store.get(K.job(prepared.body.id))).permit.slice(130), 16) % 27, "permit v as 27/28");
  const job = JSON.parse(await store.get(K.job(prepared.body.id)));
  assert.equal(job.status, "sent");
  assert.equal(job.hash, "0x" + "11".repeat(32));

  // Relay says delivered: status reports filled with the far-side transaction.
  const relayStatus = async () => ({ ok: true, json: async () => ({ status: "success", txHashes: ["0xfar"] }) });
  const filled = await status({ store, fetchImpl: relayStatus, id: prepared.body.id });
  assert.equal(filled.body.status, "filled");
  assert.equal(filled.body.destinationTx, "0xfar");

  const second = await prepare({ store, fetchImpl: relayFetch(), nonces, user: wallet.address, to: FRIEND, amount: "5", now: fixedNow });
  await submit({ store, body: { id: second.body.id, ...(await signPair(second.body)) }, now: fixedNow });
  const failing = createSendWorker({ store, chain: { ...chain, simulate: async () => { throw new Error("execution reverted: WrongNonce(8)"); } }, logger: { log() {}, warn() {}, error() {} }, now: fixedNow });
  await failing.tick();
  assert.equal(JSON.parse(await store.get(K.job(second.body.id))).status, "failed");
  assert.equal(JSON.parse(await store.get(K.job(second.body.id))).reason, "already-used");
  assert.equal(sent.length, 1, "nothing was sent");
});

test("typed data: the Send and the Permit carry what the contract hashes", () => {
  const typed = sendTypedData({ contract: SEND_CONTRACT, from: wallet.address, amount: "1", nonce: "0", deadline: "2", callsHash: "0x" + "00".repeat(32), destination: "0x" + "00".repeat(32) });
  assert.equal(typed.domain.name, "Desk Send");
  assert.equal(typed.types.Send.map((f) => f.name).join(","), "from,amount,nonce,deadline,callsHash,destination");
  const permit = permitTypedData({ owner: wallet.address, spender: SEND_CONTRACT, value: 1n, nonce: 0n, deadline: 2n });
  assert.equal(permit.domain.verifyingContract, AUSD);
  assert.equal(permit.types.Permit.map((f) => f.name).join(","), "owner,spender,value,nonce,deadline");
  // Round trip through the calldata encoder.
  const job = { intent: { from: wallet.address, amount: "1", nonce: "0", deadline: "2", callsHash: "0x" + "00".repeat(32), destination: "0x" + "00".repeat(32) }, signature: "0x" + "00".repeat(65), permit: "0x" + "00".repeat(64) + "1c", calls: [transferCall(FRIEND, 1n)] };
  const { functionName, args } = decodeFunctionData({ abi: SEND_ABI, data: sendCalldata(job) });
  assert.equal(functionName, "send");
  assert.equal(args[2], 28);
});
