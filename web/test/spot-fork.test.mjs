// Spot Auto-Copy end to end on a fork of Monad mainnet (anvil), run with SPOT_FORK=1. The real
// API turns copying on from a wallet's signatures; the real engine relays the setup through the
// real executor, copies a leader's WMON buy with a live 0x quote, and sells it with the leader.
// Calibur, AllowanceHolder, Settler and AUSD are the deployed ones; DeskCopyHook is the compiled
// contract (forge build in contracts/); Desk's key signs as KMS would, in DER.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { generateKeyPairSync } from "node:crypto";
import { createTestClient, http, parseAbi, toHex } from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import { secp256k1 } from "@noble/curves/secp256k1";
import { memoryStore } from "../api/_store.mjs";
import { createCopyHandler } from "../api/_copy.mjs";
import { spotGrantText } from "../api/_spot.mjs";
import { SPOT, accountFromSigner, batchFor, keyHashOf, CALIBUR_ABI } from "../copyd/spot-chain.mjs";
import { monad, monadClients, spotChain, spotReads } from "../copyd/spot-node.mjs";
import { createSpotExecutor } from "../copyd/spot-executor.mjs";
import { S, createSpotEngine } from "../copyd/spot-engine.mjs";
import { readableUnits } from "../api/swap-quote.mjs";

const run = process.env.SPOT_FORK === "1";
const PORT = 8547;
const RPC = `http://127.0.0.1:${PORT}`;
const HOOK_AT = "0xDe5C0000000000000000000000000000dC0B501e";
const WMON = "0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A";
const AUSD_HOLDER = "0xaD01C20d5886137e056775af56915de824c8fCe5";
const LEADER = "0x52ac212e7187a799a7382c7a768cb35b72a3e20a";
const API = process.env.DESK_API || "https://web-lovat-nine-49.vercel.app";
const ERC20 = parseAbi(["function balanceOf(address) view returns (uint256)", "function transfer(address,uint256) returns (bool)"]);

/// Quotes from Desk's public swap view (no fee): the same 0x route the copy view would ask for.
async function publicQuote({ kind, taker, sellToken, buyToken, sellAmount }) {
  const buying = sellToken.toLowerCase() === SPOT.ausd.toLowerCase();
  const token = buying ? buyToken : sellToken;
  const amount = buying ? readableUnits(String(sellAmount), 6) : readableUnits(String(sellAmount), 18);
  const query = new URLSearchParams({ view: "swap", user: taker, token, amount, symbol: "WMON", sell: buying ? "AUSD" : "TOKEN", ...(buying ? {} : { buy: "AUSD" }) });
  const body = await (await fetch(`${API}/api/swap-quote?${query}`)).json();
  if (!body.transaction) throw new Error(body.error ?? "no quote");
  void kind;
  return { to: body.transaction.to, data: body.transaction.data, buyAmount: body.receive.minimumRaw, fee: "0" };
}

test("spot copy on a Monad fork: turn on, copy a buy, sell with the leader", { skip: !run, timeout: 240_000 }, async (t) => {
  const anvil = spawn("anvil", ["--fork-url", process.env.MONAD_MAINNET_RPC || "https://rpc.monad.xyz", "--port", String(PORT), "--hardfork", "prague", "--silent"], { stdio: "ignore" });
  t.after(() => anvil.kill());
  const testClient = createTestClient({ chain: monad, mode: "anvil", transport: http(RPC) });
  for (let i = 0; i < 60; i += 1) {
    try { await testClient.getBlockNumber(); break; } catch { await new Promise((r) => setTimeout(r, 500)); }
  }

  const artifact = JSON.parse(readFileSync(new URL("../../contracts/out/DeskCopyHook.sol/DeskCopyHook.json", import.meta.url)));
  await testClient.setCode({ address: HOOK_AT, bytecode: artifact.deployedBytecode.object });

  // Desk's copy key, signing digests in DER the way KMS answers.
  const deskSecret = secp256k1.utils.randomPrivateKey();
  const deskAddress = privateKeyToAccount(toHex(deskSecret)).address;
  const deskAccount = accountFromSigner({ address: deskAddress, signDer: async (digest) => Buffer.from(secp256k1.sign(digest, deskSecret, { lowS: false }).toDERRawBytes()) });
  await testClient.setBalance({ address: deskAddress, value: 10n ** 19n });

  // The user's wallet: a fresh EOA holding 30 AUSD and no MON at all.
  const wallet = privateKeyToAccount(generatePrivateKey());
  await testClient.impersonateAccount({ address: AUSD_HOLDER });
  await testClient.setBalance({ address: AUSD_HOLDER, value: 10n ** 18n });
  const holderClient = (await import("viem")).createWalletClient({ chain: monad, transport: http(RPC), account: AUSD_HOLDER });
  await holderClient.writeContract({ address: SPOT.ausd, abi: ERC20, functionName: "transfer", args: [wallet.address, 30_000_000n] });

  const { reader, writer } = monadClients({ rpc: RPC, account: deskAccount });
  const reads = spotReads({ reader, hook: HOOK_AT, desk: deskAddress });
  const store = memoryStore();
  await store.set(S.desk, JSON.stringify({ address: deskAddress, hook: HOOK_AT }));
  const now = () => Date.now();
  const handler = createCopyHandler(() => ({ store, kms: null, now, spotReads: () => reads }));
  async function call(action, body) {
    const res = { code: 0, body: null, status(c) { this.code = c; return this; }, json(b) { this.body = b; return this; }, setHeader() {} };
    await handler({ method: "POST", query: { action }, headers: {}, body: JSON.stringify(body) }, res);
    return res;
  }

  // The phone: prepare, then one Face ID's three signatures.
  const prepared = (await call("spot-prepare", { wallet: wallet.address })).body;
  assert.equal(prepared.delegation, "none");
  const { publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const jwk = publicKey.export({ format: "jwk" });
  const deviceKey = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, "base64url"), Buffer.from(jwk.y, "base64url")]).toString("base64url");
  const block = await reader.getBlock();
  const expiry = Number(block.timestamp) + 30 * 86_400;
  const limits = { perTrade: 10, perDay: 20, expiry };
  const typed = batchFor({ kind: "enable", wallet: wallet.address, desk: deskAddress, hook: HOOK_AT, nonce: prepared.batchNonce, deadline: prepared.deadline, ...limits });
  const authorization = await wallet.signAuthorization({ chainId: SPOT.chainId, contractAddress: SPOT.calibur, nonce: Number(prepared.authorizationNonce) });
  const issuedAt = now();
  const enabled = await call("spot-enable", {
    wallet: wallet.address, deviceKey, ...limits, nonce: prepared.batchNonce, deadline: prepared.deadline,
    signature: await wallet.signTypedData(typed),
    authorization: { chainId: SPOT.chainId, address: SPOT.calibur, nonce: authorization.nonce, r: authorization.r, s: authorization.s, yParity: authorization.yParity },
    grant: { issuedAt, signature: await wallet.signMessage({ message: spotGrantText({ wallet: wallet.address, desk: deskAddress, deviceKey, ...limits, issuedAt }) }) },
    leaders: { [LEADER]: { rules: { amount: 5, minLeaderUsd: 0 } } },
  });
  assert.equal(enabled.code, 200, JSON.stringify(enabled.body));

  const executor = createSpotExecutor({ store, chain: spotChain({ reader, writer }), quote: publicQuote, hook: HOOK_AT, desk: deskAddress, logger: { log() {} } });
  const engine = createSpotEngine({ store, reads, executor, desk: { address: deskAddress, hook: HOOK_AT }, sleep: async () => {} });

  await engine.tick();
  const copier = JSON.parse(await store.get(S.copier(wallet.address)));
  assert.equal(copier.stage, "live", copier.error ?? "");
  assert.equal(await reader.readContract({ address: wallet.address, abi: CALIBUR_ABI, functionName: "isRegistered", args: [keyHashOf(deskAddress)] }), true);
  assert.equal(await reader.getBalance({ address: wallet.address }), 0n, "Desk paid every gas");

  // The leader buys WMON.
  const time = Date.now();
  await store.set(`wl:${LEADER}`, JSON.stringify({ trades: [], positions: {} }));
  await engine.tick();
  const bought = { time, hash: "0x" + "a".repeat(64), token: WMON.toLowerCase(), symbol: "WMON", side: "buy", amount: 5000, price: 0.03, value: 150, gain: null };
  await store.set(`wl:${LEADER}`, JSON.stringify({ trades: [bought], positions: { [WMON.toLowerCase()]: { holding: 5000, decimals: 18 } } }));
  await engine.tick();
  let log = (await store.lrange(S.log(wallet.address), 0, 10)).map((row) => JSON.parse(row));
  assert.equal(log[0].status, "copied", JSON.stringify(log[0]));
  const copied = await reads.copied(wallet.address, WMON);
  assert.ok(copied > 0n);
  assert.equal(await reader.readContract({ address: SPOT.ausd, abi: ERC20, functionName: "balanceOf", args: [wallet.address] }), 25_000_000n);
  assert.equal(await reads.remainingToday(wallet.address), 15_000_000n);

  // The leader sells it all.
  const sold = { ...bought, time: time + 60_000, hash: "0x" + "b".repeat(64), side: "sell", gain: 0 };
  await store.set(`wl:${LEADER}`, JSON.stringify({ trades: [bought, sold], positions: { [WMON.toLowerCase()]: { holding: 0, decimals: 18 } } }));
  await engine.tick();
  log = (await store.lrange(S.log(wallet.address), 0, 10)).map((row) => JSON.parse(row));
  assert.equal(log[0].status, "copied", JSON.stringify(log[0]));
  assert.equal(log[0].side, "sell");
  assert.equal(await reads.copied(wallet.address, WMON), 0n);
  const ausd = await reader.readContract({ address: SPOT.ausd, abi: ERC20, functionName: "balanceOf", args: [wallet.address] });
  assert.ok(ausd > 29_000_000n, `back to ${ausd}`);
});
