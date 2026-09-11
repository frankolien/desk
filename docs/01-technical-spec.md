# Desk: the technical spec

How the app in `00-prd.md` is built. Written 11 September 2026, before any code, so
that the first week is assembly rather than discovery.

Everything here that concerns Perpl was proven against the live testnet API on 10
September by a Node script, which stays the reference implementation: when the Swift
and the script disagree, the script is right until proven otherwise.

## Platform

Native Swift and SwiftUI, iOS 18 minimum, because the WebAuthn PRF extension needs it.

Not React Native, for three reasons. The Mera derivation is already written in Swift
and pinned to Mera's own vector. Face ID and the passkey ceremony are first class
rather than bridged, and this is a bounty judged on user experience. And the app
reuses a working iOS codebase, which is most of the schedule's slack.

The brief allows it. It asks for an app that "authenticates users via Mera", not for a
particular package, and Mera's own documentation says a native app can reuse passkeys
created with the library through the platform WebAuthn APIs. Mera is a WebAuthn PRF
ceremony, which is Apple's API on iOS 18, plus a short public derivation rule, which is
the next section. Neither part needs JavaScript.

The one residual risk is a reader who looks for the package rather than the behaviour,
and it is closed by demonstration rather than by argument: the page at
`recourse-arc.vercel.app/spike/passkey` runs Mera's real library at the same relying
party, so the same passkey can be shown deriving the same address in both. That
comparison goes in the write-up and in the video.

The fallback, if the PRF probe fails on a real device, is React Native with Mera's
library directly, which the library supports through its `react-native-passkey` peer
dependency. That decision is owed before 17 September and is the only thing that can
change this section.

## Chains and addresses

| | Monad testnet | Monad mainnet |
|---|---|---|
| Chain id | 10143 | 143 |
| RPC | `https://testnet-rpc.monad.xyz` | `https://rpc.monad.xyz` |
| Explorer | `testnet.monadexplorer.com` | `monadexplorer.com` |
| Perpl Exchange | `0x1964C32f0bE608E7D29302AFF5E61268E72080cc` | `0x34B6552d57a35a1D042CcAe1951BD1C370112a6F` |
| AUSD | `0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC` | `0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a` |
| Perpl API | `https://testnet.perpl.xyz/api` | `https://app.perpl.xyz/api` |
| Trading socket | `wss://testnet.perpl.xyz/ws/v1/trading` | `wss://app.perpl.xyz/ws/v1/trading` |
| BTC perpetual | 16 | 1 |
| Agora AUSD faucet | `0xd236c18D274E54FAccC3dd9DDA4b27965a73ee6C` | none |

Read off Monad testnet on 11 September rather than taken from a page: chain id 10143,
AUSD has code, answers `AUSD` and six decimals, the Exchange is a proxy pointing at
`0xbcbd3701ed0bde8acbb727f0d92a8b85a169adbb`, and the faucet has code.

Market ids, price decimals and size decimals come from `GET /api/v1/pub/context`
rather than from this table, which exists so a reader knows what to expect, not so
the app can hardcode it.

### Testnet AUSD

Agora runs faucet contracts that mint to any address on request, and one is deployed
to Monad testnet at the address above. `requestFunds(address)` simulates clean from a
fresh address, and the contract holds 670,000 AUSD, so it is not an empty faucet. The
documented payout is 10,000 AUSD per call; confirm the figure on the first real run.

The caller needs MON for gas first, from Monad's own faucet. So the Fund screen's
testnet path is two faucets and then the desk, which is worth building as one guided
sequence rather than three links.

### A note on AUSD's extensions

AUSD implements EIP-712, ERC-2612 permit, ERC-3009 transfer with authorization, and
ERC-1271. Two of those are opportunities rather than commitments, and both are written
down here so they are not rediscovered in week three.

ERC-2612 would remove the approve transaction from the opening sequence, but only if
Perpl's Exchange exposes a permit-aware entry point. Check the ABI before promising it.

ERC-3009 is the interesting one: a signed authorization lets somebody else pay the gas
that moves the collateral. With a relayer, the phone would not need MON at all, which
would delete the one wart in the Fund screen. That is real infrastructure and it is
below the cut line for version one, but it is the obvious version two and it is the
same mechanism the Recourse cheque uses, so the code to build it already exists next
door.

## Keys

One passkey is the root. Everything else is derived from its PRF output, and the rule
is Mera's, so it cannot be changed without changing every address.

```
PRF salt      sha256("mera.prf.salt.v1")
              = 896d46ac4ac191885c46137439db7bb52fb05cff3ecd34af7cdae0a1e0c00db9
PRF output    32 bytes, used as BIP-39 entropy (24 words)
Seed          BIP-39 seed, empty passphrase, PBKDF2 2048 rounds
Wallet key    BIP-32, m/44'/60'/0'/0/0, secp256k1
Trading key   SLIP-0010, m/44'/501'/0'/0', ed25519, every step hardened
```

Pinned vector, computed with the libraries Mera's own demo uses, and already an
assertion in the Recourse test suite:

```
prfOutput        0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20
evmPrivateKey    7c56100e187f2845a35ce856646662dfc2024be2b4a150b45ad1f62564617128
evmAddress       0x50B240678777451BEfd67B7e8c3b4366482ba8F9
ed25519Seed      e6ab0994f80a3abf9a1c10d8d27733d24de8c873af6bee177a93a0da5a4b0f79
ed25519PublicKey 89684d872dd939e6c13b2c9d501465bdfe3546a81d32c2889dca5b6847046100
```

The Ed25519 key is not used as a chain identity here, only as the Perpl API key. Its
derivation path says Solana because that is the path Mera assigns to its Ed25519
account, and following Mera exactly is worth more than a tidier path.

## The signing session

The one piece of architecture that is not obvious, and the product's main idea.

`SigningSession` is the only object that ever sees PRF output. It holds the 32 byte
Ed25519 seed in a single heap allocation it can overwrite, constructs a signing key
per use, and overwrites the buffer when the session ends. It ends when the countdown
expires, when the user ends it, or when the app leaves the foreground.

The wallet key is never held at all. A contract call or an enrolment asks for a fresh
PRF ceremony, derives the secp256k1 key, signs, and overwrites. The extra Face ID
prompt is correct: signing a transaction that moves collateral should feel different
from placing an order.

Be honest in the code comments about the limit: Swift and CryptoKit copy bytes where
they please, so overwriting one buffer reduces the window rather than closing it. The
property that actually holds is that nothing is written to disk and nothing survives
the session, and that is the property the Account screen claims.

What the keychain holds, both non-secrets:
- the passkey credential id, so an assertion can target the right credential
- Perpl's opaque `api_key` token from enrolment, which is re-issuable by enrolling
  again and cannot move money on its own

## Modules

```
Core/Auth
  PasskeyAccounts.swift      derivation, ported and already pinned
  PasskeyCeremony.swift      ASAuthorization wrapper, create and assert with PRF
  SigningSession.swift       holds, expires, zeroes

Core/Chain
  MonadRPC.swift             JSON-RPC transport
  EIP712.swift               domain separator, struct hash, typed data digest
  ERC20.swift                balanceOf, allowance, approve
  Exchange.swift             createAccount, depositCollateral, getAccountByAddr, withdraw
  TransactionSender.swift    nonce, fees, sign, send raw, await receipt

Core/Perpl
  PerplCanonical.swift       the canonical strings and their signatures
  PerplREST.swift            signed GET and POST
  PerplEnrolment.swift       payload then enroll
  PerplSocket.swift          sign in, subscribe, order, cancel, reconnect
  PerplModels.swift          message shapes, market context, order and position

Core/Domain
  DeskStore.swift            the observable state the screens read
  SnapshotCache.swift        last good answer per account, ported

Features
  SignIn/  Fund/  Market/  Position/  Account/

DesignSystem
  Colour, type, amount keypad, all ported
```

## Perpl, precisely

### Authentication

Every REST request and the socket sign-in are signed with the Ed25519 key over a
canonical string. Newline separated, no trailing newline.

```
REST      chain_id \n METHOD \n target \n ts \n nonce \n sha256(body) as lowercase hex
Socket    chain_id \n trading-ws-signin \n ts \n nonce
```

`target` is the path with its query. `ts` is unix time. `nonce` is fresh per request.
For an empty body the hash is sha256 of zero bytes. The socket sign-in is message type
29 and must complete before any other message is accepted.

### Enrolment

Two calls, and the wallet signs once.

1. `POST /api/v1/api-key/payload` with `{ chain_id, address, public_key, scope_mask, label }`,
   where `public_key` is the Ed25519 public key as 32 bytes of 0x-hex and `scope_mask`
   is 1 for read, 2 for trade, 3 for both. Desk asks for 3.
   The answer is EIP-712 typed data plus a `mac` to be returned unchanged.
   Primary type `PerplRegisterApiKey`. Domain `{ name: "perpl.xyz", version: "1",
   chainId, verifyingContract: 0x0, salt }`. Message fields `builderId, expiresAt,
   ipCidrs, label, maxBuilderFeePer100K, origin, publicKey, scope, signer, statement,
   time`.
   **Trap found in the spike:** the chain id arrives as a hex string. It must be
   hashed as a number. Getting this wrong returns 400.

2. `POST /api/v1/api-key/enroll` with `{ chain_id, address, typed_data, mac, signature,
   pop_signature }`, where `signature` is the wallet's EIP-712 signature over the
   digest and `pop_signature` is the Ed25519 proof of possession over the same digest.
   **This answers 404 for a wallet with no exchange account**, which is why the desk is
   opened before the key is enrolled.

### Messages

| Type | Direction | Meaning |
|---|---|---|
| 29 | out | sign in |
| 22 | out | place order, fields `{sn, rq, mkt, acc, t, p, s, fl, lv, lb}` |
| 19 | in | wallet snapshot |
| 3 | in | order status |

Prices and sizes are scaled integers using the decimals from `pub/context`, not
floats. Every message shape gets a decode test against a captured payload before the
screen that uses it is written, so a change in Perpl's API fails in a test rather than
in a demo.

The exact shapes of cancel, position updates and fills were not reached by the spike.
They are the first thing to establish on the 17th, by capturing real traffic from the
Node script against a funded account.

### The exchange account

Order of operations, each a contract call from the derived wallet:

1. `aUSD.approve(exchange, amount)`
2. `Exchange.createAccount(uint256 amountCNS)`, which opens the account with its first
   collateral. `getAccountByAddr(address)` reads it back; the account id is a `u32`.
3. `Exchange.depositCollateral(uint256 amountCNS)` for later top-ups.
4. Enrol the Ed25519 key, then trade over the socket.
5. Withdrawals are contract calls the wallet signs, never the API key.

The phone needs a little MON for steps 1, 2 and 5. That is the only reason the Fund
screen mentions a gas token at all.

## Reuse from Recourse

The Recourse repository at `../recourse` is where half of this already exists. Copied,
not linked, because the two projects are going to diverge and a shared package would
couple two hackathon deadlines together.

| Take | From |
|---|---|
| Mera derivation and its vector test | `mobile/Recourse/Core/Auth/PasskeyAccounts.swift`, `mobile/RecourseTests/PasskeyAccountsTests.swift` |
| The PRF ceremony, both create and assert | `mobile/Recourse/Features/Profile/PasskeyPRFProbeView.swift` |
| keccak and EIP-712 hashing | `mobile/Recourse/Core/Chain/SafeSigning.swift` |
| secp256k1 signing over web3swift | `mobile/Recourse/Core/Auth/TestnetLocalSigner.swift` |
| JSON-RPC transport and contract reads | `mobile/Recourse/Core/Chain/ArcRPCTransport.swift`, `ArcContractReader.swift` |
| Last good answer per account | `mobile/Recourse/Core/Domain/SnapshotCache.swift` |
| Amount entry, colour, type | `mobile/Recourse/Core/DesignSystem/` |
| Project generation from a script | `mobile/scripts/generate_project.rb` |

The Perpl reference script is `../recourse/docs/treasury/perpl/spike.mjs` and its
findings are in the README beside it. Both move here once this repo is the one being
worked in.

The one dependency carried over is web3swift, for secp256k1 and BIP-32. Everything
else is CryptoKit and Foundation.

## Tests

The rule is that no signature reaches a server before a test pins it.

- **Derivation.** The Mera vector above, already written.
- **Canonical strings.** Fixed inputs, expected string and expected signature,
  generated by the Node script and pasted in.
- **EIP-712.** The enrolment digest for a captured payload, checked against the digest
  the script computes.
- **Message decoding.** Captured frames for types 19 and 3, decoded into the models.
- **Scaling.** Price and size conversion both ways for a market with awkward decimals,
  because an off by ten in a leveraged order is the worst bug this app can have.
- **Session.** The key is gone after expiry, after an explicit end, and after a
  background event.

Live tests against Perpl testnet are opt in behind an environment variable, the way
the Arc live tests are in Recourse, so the normal suite never depends on a third party
being up.

## Build order

Four weeks, shared with Olien on Monad, which is the primary entry. Olien takes the
mornings and every collision.

| Dates | Desk |
|---|---|
| 17 to 18 Sept | Repo, project, derivation verified on a real device, `PerplCanonical` and `PerplREST` with vectors pinned, real traffic captured for the socket |
| 19 to 21 Sept | Sign in, Fund, the opening sequence, enrolment, one real order sent from the phone |
| 22 to 25 Sept | Market, ticket, Position, close |
| 26 to 30 Sept | Withdraw, the session screen, the second device demo, design pass |
| 1 to 8 Oct | The treasury stretch if Olien on Monad is finished, otherwise polish and a TestFlight build |
| 9 to 12 Oct | Record, write up, submit both entries, well ahead of the 14 October 04:59 GMT+1 deadline |

**The cut line, in the order things get cut:** the treasury stretch goes first. Then
withdraw becomes a contract call shown from a script in the video rather than a screen.
Then the depth view. Market, Position and Fund ship no matter what, because an app that
cannot open a desk and place an order is not an entry.

## Blocking unknowns

One left, owed before 17 September, and it does not block the Perpl client, which can
be written and vector tested without a funded account.

**PRF on a real device.** The probe screen in Recourse registers a passkey, asserts
twice, and prints the derived accounts. The page at
`recourse-arc.vercel.app/spike/passkey` does the same through Mera's own library at the
same relying party. Matching addresses means the design stands, and the same comparison
is the evidence that answers anyone asking whether a native app really uses Mera.

**Closed on 11 September: testnet AUSD.** Agora's faucet is on Monad testnet, funded,
and its `requestFunds` call simulates clean. See the chains section above.
