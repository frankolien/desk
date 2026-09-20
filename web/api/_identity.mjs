import { createPublicClient, http } from "viem";
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
const MONAD_CHAIN_ID = "143";
const NNS_URL = "https://api.nad.domains/v1/protocol/profiles";
const NADFUN_URL = "https://api.nad.fun/profile/";
const NEYNAR_URL = "https://api.neynar.com/v2/farcaster/user/bulk-by-address/";
const TTL_SECONDS = 24 * 3600;
const NADFUN_DEFAULT_IMAGE = /\/default_profile_\d+\.png$/i;

const text = (value) => (typeof value === "string" && value.trim() ? value.trim() : null);

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
  const verified = (user) => (user?.verified_addresses?.eth_addresses ?? [])
    .some((entry) => String(entry).toLowerCase() === lower);
  return (Array.isArray(users) ? users : [])
    .filter((user) => text(user?.username) && !user.username.startsWith("!"))
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
      found.set(address.toLowerCase(), {
        name: text(user.display_name) ?? username,
        username,
        avatar: text(user.pfp_url),
        bio: text(user.profile?.bio?.text),
      });
    }
  } catch { /* optional source */ }
  return found;
}

export function describeIdentity(address, { nad = null, fun = null, ens = null, cast = null, perpl = null } = {}) {
  const sources = [
    nad && { source: "nad", name: nad.name, avatar: nad.avatar ?? null },
    fun && { source: "nadfun", name: fun.name, avatar: fun.avatar ?? null, bio: fun.bio ?? null },
    ens && { source: "ens", name: ens.name, avatar: ens.avatar ?? null, x: ens.x ?? null },
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
  const wanted = [...new Set(addresses.map((value) => value.toLowerCase()))];
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

  const [nad, casts, funs, enses, perpls] = await Promise.all([
    nadNames(missing, fetchImpl),
    farcaster(missing, fetchImpl, neynarKey),
    Promise.all(missing.map((address) => nadFun(address, fetchImpl))),
    Promise.all(missing.map((address) => (ens ? ens(address).catch(() => null) : null))),
    Promise.all(missing.map((address) => (chain
      ? chain.accountByAddress(address).then((account) =>
        (account && account.accountId !== 0n ? account.accountId.toString() : null)).catch(() => null)
      : null))),
  ]);

  missing.forEach((address, index) => {
    const identity = describeIdentity(address, {
      nad: nad.get(address), fun: funs[index], ens: enses[index], cast: casts.get(address), perpl: perpls[index],
    });
    identities[address] = identity;
    if (store) store.set(cacheKey(address), JSON.stringify(identity), { ex: TTL_SECONDS }).catch(() => {});
  });
  return identities;
}
