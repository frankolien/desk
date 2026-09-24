/// Nad Name Service on Monad mainnet, read through the chain and written as calldata the
/// phone signs. Addresses are pinned here and in the app; the app refuses to sign for
/// any other target, so this module can only ever ask the wallet to talk to nad.
import { createPublicClient, encodeFunctionData, formatUnits, http, namehash, parseAbi } from "viem";

export const NNS = "0xCc7a1bfF8845573dbF0B3b96e25B9b549d4a2eC7";
export const CONTROLLER = "0xE18a7550AA35895c87A1069d1B775Fa275Bc93Fb";
export const ORACLE = "0xdF0e18bb6d8c5385d285C3c67919E99c0dce020d";
export const MON = "0x0000000000000000000000000000000000000000";
export const USDC = "0x754704Bc059F8C67012fEd69BC8A327a5aafb603";
export const RECORD_KEYS = ["avatar", "description", "url", "com.twitter"];
const RESERVED_URL = "https://api.nad.domains/is-name-reserved/";

export const nnsAbi = parseAbi([
  "function isNameAvailable(string name) view returns (bool)",
  "function getNamesOfAddress(address addr) view returns (string[])",
  "function getPrimaryNameForAddress(address addr) view returns (string)",
  "function getOwnerOfName(string name) view returns (address)",
  "function getNameAttribute(bytes32 node, string key) view returns (string)",
  "function getNameAttributes(bytes32 node, string[] keys) view returns ((string key, string value)[])",
  "function setNameAttributes(bytes32 node, (string key, string value)[] attributes)",
  "function setPrimaryNameForAddress(string name, address addr)",
]);
export const oracleAbi = parseAbi([
  "function getRegisteringPriceInToken(string name, address token) view returns ((uint256 base, address token, uint8 decimals))",
]);
export const controllerAbi = parseAbi([
  "function registerWithSignature((string name, address nameOwner, bool setAsPrimaryName, address referrer, bytes32 discountKey, bytes discountClaimProof, uint256 nonce, uint256 deadline, (string key, string value)[] attributes, address paymentToken) params, bytes signature) payable",
]);

/// The label nad accepts from Desk: lower-case letters, digits and hyphens, 1–32 long.
/// nad itself allows emoji; Desk keeps to what a keyboard types until that is asked for.
export function cleanLabel(value) {
  const label = String(value ?? "").trim().toLowerCase().replace(/\.nad$/, "");
  return /^[a-z0-9-]{1,32}$/.test(label) && !label.startsWith("-") && !label.endsWith("-") ? label : null;
}

export const node = (label) => namehash(`${label}.nad`);

export function nadClient(rpc = "https://rpc.monad.xyz") {
  return createPublicClient({ transport: http(rpc, { timeout: 8_000, batch: true }) });
}

/// Whether the label can be had, what it costs, and what its records say if it is taken.
export async function nameStatus(label, { client = nadClient(), fetchImpl = fetch } = {}) {
  const [available, mon, usdc, reserved] = await Promise.all([
    client.readContract({ address: NNS, abi: nnsAbi, functionName: "isNameAvailable", args: [label] }),
    client.readContract({ address: ORACLE, abi: oracleAbi, functionName: "getRegisteringPriceInToken", args: [label, MON] }),
    client.readContract({ address: ORACLE, abi: oracleAbi, functionName: "getRegisteringPriceInToken", args: [label, USDC] }).catch(() => null),
    fetchImpl(`${RESERVED_URL}${encodeURIComponent(label)}`).then((r) => r.json()).then((b) => b?.isReserved === true).catch(() => false),
  ]);
  const out = {
    name: `${label}.nad`, label, available: Boolean(available) && !reserved, reserved,
    priceMON: formatUnits(mon.base, mon.decimals), priceUSDC: usdc ? formatUnits(usdc.base, usdc.decimals) : null,
  };
  if (!available) {
    const [owner, records] = await Promise.all([
      client.readContract({ address: NNS, abi: nnsAbi, functionName: "getOwnerOfName", args: [label] }).catch(() => null),
      client.readContract({ address: NNS, abi: nnsAbi, functionName: "getNameAttributes", args: [node(label), RECORD_KEYS] }).catch(() => []),
    ]);
    out.owner = owner ?? null;
    out.records = Object.fromEntries((records ?? []).filter((r) => r.value).map((r) => [r.key, r.value]));
  }
  return out;
}

/// The names a wallet holds, which is primary, and each one's records.
export async function namesOf(address, { client = nadClient() } = {}) {
  const [names, primary] = await Promise.all([
    client.readContract({ address: NNS, abi: nnsAbi, functionName: "getNamesOfAddress", args: [address] }),
    client.readContract({ address: NNS, abi: nnsAbi, functionName: "getPrimaryNameForAddress", args: [address] }).catch(() => ""),
  ]);
  const records = await Promise.all(names.map((label) =>
    client.readContract({ address: NNS, abi: nnsAbi, functionName: "getNameAttributes", args: [node(label), RECORD_KEYS] }).catch(() => [])));
  return {
    primary: primary ? `${primary}.nad` : null,
    names: names.map((label, index) => ({
      name: `${label}.nad`, label, isPrimary: label === primary,
      records: Object.fromEntries((records[index] ?? []).filter((r) => r.value).map((r) => [r.key, r.value])),
    })),
  };
}

/// Calldata for the two writes the phone can make on its own, and for the registration
/// once nad's co-signature is in hand. Every result names its target so the app can pin it.
export function setRecordsCalldata(label, records) {
  const attributes = RECORD_KEYS.filter((key) => key in records).map((key) => ({ key, value: String(records[key] ?? "").slice(0, 280) }));
  if (!attributes.length) return null;
  return { to: NNS, value: "0", data: encodeFunctionData({ abi: nnsAbi, functionName: "setNameAttributes", args: [node(label), attributes] }) };
}

export function setPrimaryCalldata(label, address) {
  return { to: NNS, value: "0", data: encodeFunctionData({ abi: nnsAbi, functionName: "setPrimaryNameForAddress", args: [label, address] }) };
}

export function registerCalldata(params, signature, priceWei) {
  return {
    to: CONTROLLER, value: String(priceWei),
    data: encodeFunctionData({ abi: controllerAbi, functionName: "registerWithSignature", args: [params, signature] }),
  };
}

/// Registration needs nad's co-signature over the request. The endpoint that issues it
/// is not public; when nad gives Desk one it goes in `NAD_REGISTER_URL`, and this turns
/// their answer into a transaction the phone can check and sign. Until then: 503.
export async function registerRequest({ name, owner, setAsPrimary = true, attributes = [] }, { fetchImpl = fetch, url = process.env.NAD_REGISTER_URL } = {}) {
  if (!url) return { status: 503, body: { error: "Registering through Desk isn't open yet. Nad's signing endpoint is pending.", reason: "not-configured" } };
  const label = cleanLabel(name);
  if (!label) return { status: 400, body: { error: "A valid name is required." } };
  let answer;
  try {
    const response = await fetchImpl(url, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: label, owner, setAsPrimary, referrer: null, paymentToken: MON, attributes }),
    });
    answer = await response.json();
    if (!response.ok) return { status: 502, body: { error: String(answer?.message ?? "Nad refused the registration."), reason: "refused" } };
  } catch {
    return { status: 502, body: { error: "Nad could not be reached.", reason: "unreachable" } };
  }
  const params = answer?.registerData;
  const signature = String(answer?.signature ?? "");
  if (!params || !/^0x[a-fA-F0-9]{130}$/.test(signature) || String(params.nameOwner ?? "").toLowerCase() !== String(owner).toLowerCase() || params.name !== label) {
    return { status: 502, body: { error: "Nad's answer did not describe this registration.", reason: "mismatch" } };
  }
  const priceWei = BigInt(Math.round(Number(answer.price) * 1e6)) * 10n ** 12n;
  return { status: 200, body: { ...registerCalldata(params, signature, priceWei), priceMON: String(answer.price), deadline: Number(params.deadline) } };
}
