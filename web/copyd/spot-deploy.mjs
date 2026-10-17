/// Deploys DeskCopyHook to Monad through the deterministic CREATE2 factory, from Desk's spot copy
/// key in KMS, at an address whose low five bits are 11110 (Calibur reads the hook's callbacks
/// from them). The hook has no owner, so who deploys it grants nothing. Prints the address.
/// Run by spot-setup.sh, with the desk profile's credentials exported:
///   node copyd/spot-deploy.mjs <kms key id> <path to DeskCopyHook.json>
import { readFileSync } from "node:fs";
import { concat, getContractAddress, toHex } from "viem";
import { kmsAccount } from "./spot-chain.mjs";
import { monadClients } from "./spot-node.mjs";

const FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C";
const [keyId, artifactPath] = process.argv.slice(2);
if (!keyId || !artifactPath) { console.error("usage: node copyd/spot-deploy.mjs <kms key id> <DeskCopyHook.json>"); process.exit(2); }

const initCode = JSON.parse(readFileSync(artifactPath, "utf8")).bytecode.object;
let salt;
let address;
for (let i = 0n; ; i += 1n) {
  salt = toHex(i, { size: 32 });
  address = getContractAddress({ opcode: "CREATE2", from: FACTORY, salt, bytecode: initCode });
  if ((BigInt(address) & 0x1fn) === 0x1en) break;
}

const { KMSClient } = await import("@aws-sdk/client-kms");
const client = new KMSClient({ region: process.env.AWS_REGION || "eu-north-1" });
const account = await kmsAccount({ client, keyId });
const { reader, writer } = monadClients({ account });

const existing = await reader.getCode({ address });
if (existing && existing !== "0x") {
  console.log(address);
  process.exit(0);
}
const hash = await writer.sendTransaction({ to: FACTORY, data: concat([salt, initCode]) });
const receipt = await reader.waitForTransactionReceipt({ hash });
const code = await reader.getCode({ address });
if (receipt.status !== "success" || !code || code === "0x") {
  console.error(`deploy failed: ${hash}`);
  process.exit(1);
}
console.error(`deployed in ${hash}`);
console.log(address);
