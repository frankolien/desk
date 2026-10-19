/// Deploys DeskSend to Monad through the deterministic CREATE2 factory at salt zero, from Desk's
/// spot copy key in KMS, so its address is the one the app and the API pin (SEND_CONTRACT in
/// web/api/_send.mjs). The contract has no owner, so who deploys it grants nothing. Prints the
/// address. Run by send-setup.sh with the desk profile's credentials exported:
///   node copyd/send-deploy.mjs <kms key id> <path to DeskSend.json>
import { readFileSync } from "node:fs";
import { concat, getContractAddress, toHex } from "viem";
import { kmsAccount } from "./spot-chain.mjs";
import { monadClients } from "./spot-node.mjs";
import { SEND_CONTRACT } from "../api/_send.mjs";

const FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C";
const [keyId, artifactPath] = process.argv.slice(2);
if (!keyId || !artifactPath) { console.error("usage: node copyd/send-deploy.mjs <kms key id> <DeskSend.json>"); process.exit(2); }

const initCode = JSON.parse(readFileSync(artifactPath, "utf8")).bytecode.object;
const salt = toHex(0n, { size: 32 });
const address = getContractAddress({ opcode: "CREATE2", from: FACTORY, salt, bytecode: initCode });
if (address.toLowerCase() !== SEND_CONTRACT) {
  console.error(`this build deploys to ${address}, not the pinned ${SEND_CONTRACT}: the bytecode changed, so pin the new address in web/api/_send.mjs and DeskKit's AnyChainSend first`);
  process.exit(1);
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
