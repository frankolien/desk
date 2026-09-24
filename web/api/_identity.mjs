import { createPublicClient, http } from "viem";
import { deskProfiles } from "./_profile.mjs";
import { mainnet } from "viem/chains";

/// Who a wallet is, from every place a Monad wallet can carry a public name: a .nad
/// primary name, a nad.fun profile, an ENS name, a Farcaster account. The first source
/// with a name wins the name; an avatar, bio or X handle it lacks is borrowed from the
/// others. A wallet with none of them resolves to nulls and the app shows the address.
///
///   GET /api/traders?view=identity&addresses=0x…,0x…   (up to 50)
///
/// A view on traders rather than a function of its own: the Hobby plan allows twelve
/// functions per deployment.

export const MAX_ADDRESSES = 50;
export class NameLookupUnavailable extends Error {}
const MONAD_CHAIN_ID = "143";
const NNS_URL = "https://api.nad.domains/v1/protocol/profiles";
const NADFUN_URL = "https://api.nad.fun/profile/";
const NEYNAR_URL = "https://api.neynar.com/v2/farcaster/user/bulk-by-address/";
const SNS_PRIMARY_URL = "https://sns-api.bonfida.com/v2/user/fav-domains/";
const TTL_SECONDS = 24 * 3600;
const NADFUN_DEFAULT_IMAGE = /\/default_profile_\d+\.png$/i;

const text = (value) => (typeof value === "string" && value.trim() ? value.trim() : null);
const evmAddress = (value) => /^0x[a-fA-F0-9]{40}$/.test(value);
const solanaAddress = (value) => /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(value);
const identityKey = (address) => evmAddress(address) ? address.toLowerCase() : address;

async function snsPrimary(addresses, fetchImpl) {
  const found = new Map();
  for (let start = 0; start < addresses.length; start += 20) {
    const batch = addresses.slice(start, start + 20);
    try {
      const response = await fetchImpl(`${SNS_PRIMARY_URL}${batch.join(",")}`);
      if (!response.ok) continue;
      const body = await response.json();
      for (const address of batch) {
        const domain = text(body?.[address]);
        if (domain) found.set(address, { name: domain.endsWith(".sol") ? domain : `${domain}.sol` });
      }
    } catch { /* a missing SNS profile must not hide other identities */ }
  }
  return found;
}

export function ensReader(rpcURL = process.env.ETHEREUM_RPC || "https://ethereum-rpc.publicnode.com") {
  const client = createPublicClient({ chain: mainnet, transport: http(rpcURL, { timeout: 8_000, batch: true }) });
  return async function ens(address) {
    const name = await client.getEnsName({ address });
    if (!name) return null;
    const [avatar, x] = await Promise.all([
      client.getEnsAvatar({ name }).catch(() => null),
      client.getEnsText({ name, key: "com.twitter" }).catch(() => null),
    ]);
    return { name, avatar: text(avatar), x: text(x)?.replace(/^@/, "") ?? null };
  };
}

async function nadNames(addresses, fetchImpl) {
  const found = new Map();
  if (addresses.length === 0) return found;
  try {
    const response = await fetchImpl(`${NNS_URL}?addrs=${addresses.join(";")}&chainId=${MONAD_CHAIN_ID}`);
    if (!response.ok) return found;
    const body = await response.json();
    for (const row of body?.profiles ?? []) {
      const name = text(row?.primaryName);
      if (name && row?.addr) found.set(row.addr.toLowerCase(), { name, avatar: text(row.avatar) });
    }
  } catch { /* the name service is one source of several */ }
  return found;
}

/// nad.fun answers for every address; a wallet that never set a profile echoes its
/// address as the nickname and a numbered default picture, and that is not a profile.
async function nadFun(address, fetchImpl) {
  try {
    const response = await fetchImpl(`${NADFUN_URL}${address}`);
    if (!response.ok) return null;
    const info = (await response.json())?.account_info;
    const nickname = text(info?.nickname);
    const name = nickname && nickname.toLowerCase() !== address.toLowerCase() ? nickname : null;
    const image = text(info?.image_uri);
    const avatar = image && !NADFUN_DEFAULT_IMAGE.test(image) ? image : null;
    if (!name && !avatar) return null;
    return { name, avatar, bio: text(info?.bio) };
  } catch {
    return null;
  }
}

/// An address can belong to several Farcaster accounts (custody of one, verified on
/// another, or a throwaway). A name beginning with "!" is a placeholder for an account
/// that never registered one. The account that verified this address wins, then the
/// most followed.
export function pickFarcasterUser(address, users) {
  const lower = address.toLowerCase();
  const solana = solanaAddress(address);
  const verified = (user) => (user?.verified_addresses?.eth_addresses ?? [])
    .some((entry) => String(entry).toLowerCase() === lower);
  return (Array.isArray(users) ? users : [])
    .filter((user) => text(user?.username) && !user.username.startsWith("!"))
    .filter((user) => !solana || (user?.verified_addresses?.sol_addresses ?? []).includes(address))
    .sort((a, b) => (Number(verified(b)) - Number(verified(a))) || ((b.follower_count ?? 0) - (a.follower_count ?? 0)))[0] ?? null;
}

async function farcaster(addresses, fetchImpl, key) {
  const found = new Map();
  if (!key || addresses.length === 0) return found;
  try {
    const response = await fetchImpl(`${NEYNAR_URL}?addresses=${addresses.join(",")}`, { headers: { "x-api-key": key } });
    if (!response.ok) return found;
    const body = await response.json();
    for (const [address, users] of Object.entries(body ?? {})) {
      const user = pickFarcasterUser(address, users);
      const username = text(user?.username);
      if (!username) continue;
      found.set(identityKey(address), {
        name: text(user.display_name) ?? username,
        username,
        avatar: text(user.pfp_url),
        bio: text(user.profile?.bio?.text),
      });
    }
  } catch { /* optional source */ }
  return found;
}

export function describeIdentity(address, { desk = null, nad = null, fun = null, ens = null, sns = null, cast = null, perpl = null } = {}) {
  const sources = [
    // What the wallet said about itself comes first; the chains' records fill the gaps.
    desk && { source: "desk", name: desk.name ?? null, avatar: desk.avatar ?? null },
    nad && { source: "nad", name: nad.name, avatar: nad.avatar ?? null },
    fun && { source: "nadfun", name: fun.name, avatar: fun.avatar ?? null, bio: fun.bio ?? null },
    ens && { source: "ens", name: ens.name, avatar: ens.avatar ?? null, x: ens.x ?? null },
    sns && { source: "sns", name: sns.name, avatar: sns.avatar ?? null },
    cast && { source: "farcaster", name: cast.name, avatar: cast.avatar ?? null, bio: cast.bio ?? null },
  ].filter(Boolean);
  const named = sources.find((entry) => entry.name);
  const first = (field) => sources.find((entry) => entry[field])?.[field] ?? null;
  return {
    address,
    name: named?.name ?? null,
    source: named?.source ?? null,
    avatar: named?.avatar ?? first("avatar"),
    bio: named?.bio ?? first("bio"),
    x: named?.x ?? first("x"),
    farcaster: cast?.username ?? null,
    perplAccount: perpl ?? null,
  };
}

const cacheKey = (address) => `id:${address}`;

export async function resolveIdentities(addresses, { fetchImpl = fetch, chain = null, store = null, ens = null, neynarKey = process.env.NEYNAR_API_KEY, fresh = false } = {}) {
  const wanted = [...new Set(addresses.map(identityKey).filter((value) => evmAddress(value) || solanaAddress(value)))];
  const identities = {};
  let missing = wanted;

  if (store && !fresh) {
    const cached = await store.mget(wanted.map(cacheKey)).catch(() => wanted.map(() => null));
    missing = [];
    wanted.forEach((address, index) => {
      try {
        if (cached[index]) identities[address] = JSON.parse(cached[index]);
        else missing.push(address);
      } catch {
        missing.push(address);
      }
    });
  }
  if (missing.length === 0) return identities;

  const evm = missing.filter(evmAddress);
  const solana = missing.filter(solanaAddress);
  const [desks, nad, sns, casts, funs, enses, perpls] = await Promise.all([
    deskProfiles(store, missing),
    nadNames(evm, fetchImpl),
    snsPrimary(solana, fetchImpl),
    farcaster(missing, fetchImpl, neynarKey),
    Promise.all(missing.map((address) => (evmAddress(address) ? nadFun(address, fetchImpl) : null))),
    Promise.all(missing.map((address) => (evmAddress(address) && ens ? ens(address).catch(() => null) : null))),
    Promise.all(missing.map((address) => (evmAddress(address) && chain
      ? chain.accountByAddress(address).then((account) =>
        (account && account.accountId !== 0n ? account.accountId.toString() : null)).catch(() => null)
      : null))),
  ]);

  missing.forEach((address, index) => {
    const identity = describeIdentity(address, {
      desk: desks.get(address), nad: nad.get(address), fun: funs[index], ens: enses[index], sns: sns.get(address), cast: casts.get(address), perpl: perpls[index],
    });
    identities[address] = identity;
    if (store) store.set(cacheKey(address), JSON.stringify(identity), { ex: TTL_SECONDS }).catch(() => {});
  });
  return identities;
}

/// A name to an address: .nad on Monad, .eth on Ethereum, .sol/.sns on
/// Solana, or an @handle on Farcaster. Keep the chain with the result: a
/// Solana public key must never be treated as a Perpl/EVM trader address.
export async function lookupName(query, { fetchImpl = fetch, ensAddress = null, neynarKey = process.env.NEYNAR_API_KEY } = {}) {
  const text = String(query ?? "").trim();
  if (/^0x[a-fA-F0-9]{40}$/.test(text)) return { address: text.toLowerCase(), source: "address" };
  const lower = text.toLowerCase();
  if (/\.(sol|sns|solana)$/.test(lower)) {
    // .solana is a common spelling mistake, not an SNS TLD. Resolve its .sol
    // equivalent, and return the canonical name so the UI does not endorse it.
    const name = lower.endsWith(".solana") ? `${lower.slice(0, -7)}.sol` : lower;
    if (!/^(?:[a-z0-9-]+\.){1,2}(?:sol|sns)$/.test(name)) return null;
    try {
      const response = await fetchImpl(`https://sdk-proxy-v2.sns.id/resolve/${encodeURIComponent(name)}`);
      if (response.status >= 500) throw new NameLookupUnavailable("Solana name service is unavailable.");
      const body = response.ok ? await response.json() : null;
      const address = String(body?.s === "ok" ? body.result : "");
      if (/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(address)) return { address, source: "sns", chain: "solana", name };
    } catch (error) {
      if (error instanceof NameLookupUnavailable) throw error;
      throw new NameLookupUnavailable("Solana name service is unavailable.");
    }
    return null;
  }
  if (lower.endsWith(".nad")) {
    try {
      const response = await fetchImpl(`https://api.nad.domains/v1/protocol/resolved-address/${encodeURIComponent(lower)}?chainId=143`);
      const body = response.ok ? await response.json() : null;
      const address = String(body?.resolvedAddress ?? "");
      if (/^0x[a-fA-F0-9]{40}$/.test(address)) return { address: address.toLowerCase(), source: "nad" };
    } catch { /* not found */ }
    return null;
  }
  if (lower.endsWith(".eth") && ensAddress) {
    try {
      const address = await ensAddress(lower);
      if (address) return { address: address.toLowerCase(), source: "ens" };
    } catch { throw new NameLookupUnavailable("ENS lookup is unavailable."); }
    return null;
  }
  const handle = lower.replace(/^@/, "");
  if (neynarKey && /^[a-z0-9_.-]{1,32}$/.test(handle)) {
    try {
      const response = await fetchImpl(`https://api.neynar.com/v2/farcaster/user/by_username?username=${encodeURIComponent(handle)}`, { headers: { "x-api-key": neynarKey } });
      const user = response.ok ? (await response.json())?.user : null;
      const address = (user?.verified_addresses?.eth_addresses ?? [])[0] ?? user?.custody_address;
      if (/^0x[a-fA-F0-9]{40}$/.test(String(address ?? ""))) return { address: String(address).toLowerCase(), source: "farcaster" };
    } catch { /* not found */ }
  }
  return null;
}

export function ensAddressReader(rpcURL = process.env.ETHEREUM_RPC || "https://ethereum-rpc.publicnode.com") {
  const client = createPublicClient({ chain: mainnet, transport: http(rpcURL, { timeout: 8_000 }) });
  return (name) => client.getEnsAddress({ name });
}
