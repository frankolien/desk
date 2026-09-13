# Desk: the system design

What version one contains and how the parts fit. Written 12 September 2026, the day
code starts, on top of five research threads that checked the protocol rather than
trusting its documentation. Where this contradicts `01-technical-spec.md`, this is
newer and this wins; the corrections are listed at the end.

`04-algorithms.md` owns every formula. `03-screen-designs.md` owns every screen. This
document owns the shape between them.

## What version one contains

Five screens, unchanged from the product document. The feature set beneath them is
settled here so that nothing arrives by accident in week three.

| | Ships in v1 | Deliberately not in v1 |
|---|---|---|
| Sign in | Passkey create and assert, PRF derivation, address verification against a stored copy | Account switching, multiple passkeys, export |
| Fund | MON and AUSD balances, guided testnet funding, open a desk, top up | Fiat on-ramp, a relayer, permit-based funding |
| Market | One market, live price, depth-lite, order ticket, market and limit | Charts beyond a sparkline, multiple markets, TP/SL, cancel management |
| Position | One position, close whole or partial | Order history, fills list, multiple sub-accounts |
| Account | Address, collateral, withdraw, session control | Notifications, referral codes, builder fees |

Three things were added to the feature set by research and are not optional:

1. **`allowOrderForwarding(true)`** is a third contract call in the opening sequence.
   Without it every API order fails with `sr: 34`, after being acknowledged as `code: 0`.
2. **An address-verification step on sign in.** Apple has an open bug where a synced
   passkey returns different PRF output on different devices. The app compares the
   derived address against the last one it saw before it shows a balance.
3. **A staleness model with four states**, because a socket can be connected and
   stalled, and a trading app that shows a stale number as a live one is lying.

## The opening sequence, corrected

The single most important flow in the app, and it is four steps, not three.

```
1  aUSD.approve(exchange, amount)                 wallet signature, MON
2  Exchange.createAccount(amountCNS)              wallet signature, MON
3  Exchange.allowOrderForwarding(true)            wallet signature, MON
4  POST /api-key/payload  →  POST /api-key/enroll  wallet EIP-712 + Ed25519 PoP
```

Steps 1 to 3 are three transactions from the derived wallet, so three nonces and three
receipts. Step 4 is two HTTP calls and no gas. After step 3 trading itself is gasless,
because the exchange forwards and pays for every API order — that is a real sentence
for the Fund screen, not a footnote.

`pub/context` also carries `chain.gas` — Monad's base fee, its median, its 95th
percentile and the head block — so the fee a transaction is priced at comes from the
same call the app already makes rather than a second round trip to an RPC. On 13
September the base fee read exactly 100 gwei, which is the floor the chain enforces.

The minimum to open an account on testnet is 100 AUSD. One faucet call is 10,000, so
the user is never near the floor.

**Resumability is a requirement, not a nicety.** Each step is idempotent or checkable:
allowance is readable, `getAccountByAddr` reverts when no account exists, `fw` is
readable on the Account object from the wallet snapshot, and enrolment can be repeated.
A failure at any step resumes from the first unsatisfied precondition rather than from
the beginning, which is what the product document's acceptance criterion asks for.

## Modules

Supersedes the sketch in `01-technical-spec.md`, which described folders in a single
app target, ported from Recourse's vocabulary before any code existed.

```
Package.swift                  one local package, DeskKit, six library targets
Sources/
  DeskMoney/                   no dependencies, so it cannot reach the network
    Scaled.swift               scaled Int64 with a phantom decimals tag
    Money.swift                AUSD amounts, formatting, parsing
    DecimalText.swift          parsing and rendering, over UTF-8 bytes not Characters
    Rounding.swift  Pow10.swift
    Margin.swift               initial margin, liquidation, unrealised PnL
    Funding.swift              the 2,580s interval and the derived premium relation
    OrderQuote.swift           every figure the ticket shows before Face ID

  DeskNet/                     no dependencies
    HTTPTransport.swift        TLS enforced, redirects refused, ephemeral
    WebSocketChannel.swift     close codes readable after the read fails

  DeskAuth/                    P256K, CryptoSwift
    SecureBytes.swift          write-once, wiped in deinit
    BIP39.swift  BIP32.swift  SLIP10.swift  BIP39Wordlist.swift
    Hashing.swift  Keccak.swift  EthereumAddress.swift
    PasskeyAccounts.swift      derivation, pinned to Mera's vector
    WalletSigner.swift         recoverable secp256k1 over a keccak digest
    SigningSession.swift       lends the key, never hands it over
    AddressGuard.swift         derived against last seen, before any balance shows
    RelyingParty.swift         the one value that can never change

  DeskChain/                   DeskAuth, DeskMoney, DeskNet
    ABIWord.swift  RLP.swift  Quantity.swift  JSONValue.swift
    EIP712.swift               typed data hashing
    SigningGuard.swift         what the wallet key is allowed to sign
    Calldata.swift             every contract call, selectors derived from signatures
    Transaction.swift          EIP-1559, pinned to viem
    GasPolicy.swift  NonceRegistry.swift
    MonadRPC.swift  TransactionSender.swift

  DeskPerpl/                   DeskAuth, DeskMoney, DeskNet
    APIKey.swift               redacted in both descriptions, not merely private
    Base64URL.swift  RequestStamp.swift  PerplHeaders.swift
    PerplCanonical.swift       the strings that get signed
    PerplSigner.swift  PerplEndpoint.swift  PerplREST.swift
    PerplSocket.swift  SocketFrames.swift
    PerplContext.swift         every per-market number, from the wire
    OrderRequest.swift         message 22 and its four shapes
    Freshness.swift            four states, aged on a local monotonic clock
    MarketQuote.swift          a quote against a live market

  DeskFlow/                    all five
    Enrolment.swift            payload, guard, two signatures, token
    OpeningSequence.swift      approve, create, allow forwarding, enrol
    JSONSpan.swift             echoes the payload back byte for byte
```

The layout is flat on purpose, and the choice was checked rather than assumed. SwiftPM's
own default lookup is `predefinedDir.path.appending(component: target.name)` — a single
path component — so `Sources/Core/Money` is unreachable without an explicit `path:`,
which SE-0162 introduced for "existing C libraries or large projects, which would be
difficult to reorganize". A survey of fourteen production Swift packages on 13 September
found every one of them flat and none nesting targets inside a grouping folder; the
densest are the flattest, isowords at 124 targets and 86 sibling directories with no
`path:` at all.

Grouping is a real pattern, but it sits above the manifest rather than inside `Sources`:
ProtonMail keeps eighteen packages under `Modules/`, Ice Cubes thirteen under
`Packages/`, DuckDuckGo twenty-four under `SharedPackages/`. If Desk ever outgrows one
package, that is the move — `Packages/DeskMoney/` with its own manifest, never
`Sources/Core/DeskMoney/`.

What the module boundary buys, and what the `Core/` folder layout inherited from Recourse
could not, is enforcement. `DeskMoney` declares no dependencies, so nothing in it can
reach the network — not by agreement but because the import would not resolve. In a
single-target app with folders, `Features/Home` doing its own arithmetic compiles fine.

`DeskFlow` was added on 13 September and is where the three integrations actually meet.
Nothing below it knows about the others: `DeskChain` does not import `DeskPerpl`, and
`DeskPerpl` does not know a transaction exists. The opening sequence and the enrolment
are the only two places that need both, so they live in one module above both.

Enrolment carries one rule worth stating on its own: **the payload is never re-encoded.**
Perpl returns `typed_data` with a `mac` over it, and both go back on the enrol call. A
decode-and-re-encode round trip would reorder the object's keys, because Swift
dictionaries have no order, and any mac computed over the serialised form would then be
checked against bytes the server never produced. The Node spike survived this only
because JavaScript happens to preserve key order through a parse. So the object is
spliced back out of the response verbatim by a byte scanner, and a test asserts the
echoed bytes are a literal slice of what arrived.

The transport moved out of `DeskPerpl` on 13 September. `DeskNet` holds the HTTP and
websocket channels, because the Perpl gateway and the Monad node need the same two
things from them — TLS enforced, redirects refused — and a second copy is a second place
to get that wrong. `DeskChain` and `DeskPerpl` both depend on it; `DeskMoney` still
depends on nothing, so it still cannot reach the network.
                             Pays the argument, not msg.sender
  TransactionSender.swift    nonce, fees, sign, send raw, await receipt

Core/Perpl
  PerplCanonical.swift       the canonical strings and their signatures
  PerplREST.swift            signed GET and POST
  PerplEnrolment.swift       payload then enroll
  PerplSocket.swift          sign in, subscribe, order, cancel, reconnect, resync
  PerplModels.swift          message shapes, market context, order and position
  RequestCounter.swift       NEW. strictly increasing `rq`, seeded from `account.lfr`

Core/Domain
  DeskStore.swift            the observable state the screens read
  Freshness.swift            NEW. the four states and the per-field staleness rule
  SnapshotCache.swift        last good answer per account, ported

Features
  SignIn/  Fund/  Market/  Position/  Account/

DesignSystem                 ported from Recourse, see 03-screen-designs.md
```

## Who owns the truth

The rule that prevents two numbers disagreeing on one screen.

| Fact | Authority | Never |
|---|---|---|
| Market ids, decimals, fees, margin fractions | `GET /pub/context`, read at launch | Hardcoded. They differ between testnet and mainnet |
| Account id, collateral, `fw`, `lfr` | Wallet snapshot `mt: 19`, then `mt: 21` | Read from chain per frame |
| Position, entry, size, funding sums | `mt: 26` then `mt: 27` | Computed from fills |
| Mark price | `mt: 9` market state | The last trade |
| Order outcome | `mt: 24`, first non-failure status | `mt: 3`, which only means forwarded |
| MON and AUSD balances | Monad RPC, polled | Inferred from transactions |

`mt: 3` deserves its own line because it is the trap. `code: 0` means *accepted for
forwarding*, not posted and not filled. A non-zero code means no `mt: 24` will follow,
so that is the only case where the ticket may fail fast.

Built as `OrderTracker` on 13 September, because the distinction is too easy to lose in a
view model. Its phases are `sent`, `forwarded`, `rejected`, `settled` and `expired`, and
only `settled` answers `hasReachedTheBook` — so a screen cannot claim a position exists
off the back of an `mt: 3`. Three rules the tests pin: a terminal phase never walks
backwards, because the socket reports out of order and more than once; an `mt: 24`
settles even an order already written off as rejected, because the venue is the authority
on its own book and not our state machine; and anything still unsettled once the head
block passes its `lb` is `expired` rather than pending forever, which is the difference
between a sentence and a spinner that never ends.

## The socket

The market makes this the most stateful part of the app, and the constraints are hard.

- **Idle timeout is 10 seconds on testnet, 5 on mainnet, and it applies to the sign-in
  frame.** Send `mt: 29` as the first frame on open, before anything else.
- **Four connections per wallet address**, shared with any browser session on the same
  wallet. One connection, reused; never one per screen.
- **60 requests per minute on testnet.** Ping every 30 seconds on trading; do not ping
  market-data at all, where the budget is 10 per minute and 16 subscriptions.
- **Route by `mt`, never by `sid`.** The funding stream answers its subscription with
  the market-state `sid` and then sends frames under a different one.
- **Resync on every reconnect.** Seed `lastSn` from the wallet snapshot, require each
  heartbeat to be `lastSn + 1`, and force a reconnect on a gap. A silently reconnected
  book is worse than a disconnected one.
- **Gate freshness on the message's own timestamp, never on socket state.** A socket
  can be open and stalled, which is the failure this rule exists to catch.

Close codes carry meaning worth surfacing: `1008` is rate or idle, `1011` is an unknown
market or an account the wallet does not own, `1013` is back-pressure, `1001` is a
server restart and should reconnect immediately without backoff.

## The chain

Three Monad properties change the transaction code, and all three were verified on
chain rather than read.

**Gas limit is the bill.** Monad charges the limit, not the usage. The multiplier is
`1.075`, which is Monad's own published constant. web3swift's default 1.5x to 2x
multiplier is an eighty-six percent overcharge, so `GasPolicy` exists specifically to
stop a library default reaching a user. When `estimateGas` reverts, surface the revert;
never substitute a large limit.

**The fee floor is 100 gwei.** Anything below is dropped at the mempool as `FeeTooLow`.
Set priority to 2 gwei and `maxFeePerGas` to `max(200 gwei, 2 x base + priority)`. The
cap is a ceiling rather than a charge, so headroom costs nothing.

**`pending` equals `latest` for nonces.** An in-flight transaction does not bump the
count, and the opening sequence sends three back to back, so `NonceRegistry` tracks
them locally. Replacement needs no minimum bump, but bump anyway to win races.

Two timing facts: finality is two blocks, about 600ms, so a receipt is enough for the
interface and `finalized` is only needed before something irreversible. And after an
address receives MON it must wait about 1.2 seconds before spending it, because
consensus validates balances against lagged state. That lands exactly on the faucet to
first transaction path, so the Fund screen waits there deliberately.

## The signing session

Unchanged in principle, refined in two places.

`SigningSession` is the only object that sees PRF output. It holds the Ed25519 seed,
constructs a signing key per use, and overwrites on expiry, on an explicit end, or when
the app leaves the foreground. On iOS the PRF output arrives as a `CryptoKit`
`SymmetricKey` rather than `Data`, which suits this better than a raw buffer.

The wallet key is never held. A contract call derives it from a fresh PRF ceremony,
signs, and overwrites. The extra Face ID prompt is the point: moving collateral should
not feel like placing an order.

**A key is never handed out, only lent.** Built on 13 September, and the design turns on
one thing found while building it: `PerplCredentials` originally held a `PerplSigner`,
which holds the seed's `SecureBytes`. A client that retains those keeps the trading key
alive for as long as it holds credentials, so ending the session — or backgrounding the
app — would have zeroed nothing, and the product document's own acceptance criterion
("backgrounding the app zeroes the key, provable by the next order asking for Face ID")
would simply have been false, with every test still green.

So credentials carry the API token and a **signing function**, never a key. The function
comes from the session, borrows the key for the length of one signature, and throws once
the session has ended. No key material crosses into `DeskPerpl` at all. The acceptance
criterion is now a test: open a session, sign, background, and watch the next signed call
fail because there is nothing left to sign with.

The deadline is monotonic rather than wall-clock. A wall clock can be wound backwards
from Settings, and a session that can be extended that way is not a session.

**Two windows, not one.** The session window is fifteen minutes and governs whether an
order needs a fresh ceremony. The order window is much shorter and governs whether the
estimate on screen is still the estimate being signed for; Apple Pay uses sixty seconds
for the same reason and re-asks for intent after it. An estimate that has aged past the
order window is re-priced before it is sent.

Be honest in the comments about the limit. Swift and CryptoKit copy bytes where they
please, so overwriting one buffer narrows the window rather than closing it. The
property that holds is that nothing is written to disk and nothing survives the
session, and that is the only property the Account screen claims.

The keychain holds two non-secrets: the passkey credential id, and Perpl's opaque
`api_key`. Neither can move money — withdrawals are contract calls the wallet signs,
and Perpl's API key scopes explicitly cannot authorise a transfer out.

## Errors, and the sentences they become

A rejected order says why in the exchange's own words. That requires a map, written
once, rather than a string interpolation at the call site.

| Source | Example | The sentence |
|---|---|---|
| `sr: 34` forwarding not allowed | after createAccount without step 3 | "This desk has not enabled trading yet." Offers the step |
| `sr: 32` request id too low | reconnect without reseeding `rq` | Silent. Reseed from `lfr` and retry once |
| `sr: 13` crosses book | a post-only limit that would take | "That price would fill immediately." |
| `fr: 8` negative PnL cap | `mnp` exceeded on fill | "The fill would cost more than the position can cover." |
| Faucet `0x20e5bc67` | global 60s cooldown | "Someone else just used the faucet. Try again in a minute." |
| Faucet `0x0949dab9` | recipient holds >= 100,000 AUSD | "This address already has plenty of test dollars." |
| Faucet `0x5274afe7` | `SafeERC20FailedOperation(address)`, OpenZeppelin's wrapper for any failed ERC-20 call. Confirmed with `cast sig` on 13 September; an empty faucet is the likely cause but never the only one | "The faucet could not send the test dollars." Names the alternative |
| Close code 1008 | idle or rate | Silent reconnect; surfaces only after retries fail |

## Tests

The rule stands: no signature reaches a server before a test pins it. Research added
five cases that would each have shipped a wrong number.

- **Derivation**, against Mera's vector. Already written.
- **Canonical strings**, generated by the Node script and pasted in.
- **EIP-712**, both the enrolment digest and AUSD's permit domain. The AUSD case asserts
  `DOMAIN_SEPARATOR()` against a locally computed separator built from the name
  `"Agora Dollar"`, because the token's `name()` returns `"AUSD"` and deriving the
  domain from it fails every signature.
- **Margin decoding**, asserting `maintenance_margin > initial_margin` for every market
  in `pub/context`. That inequality only holds in the correct reading, so it catches the
  percent-versus-divisor misreading on any market at any time.
- **Scaling**, both directions, on a market where `price_decimals + size_decimals != 6`,
  because the natural shortcut is exactly ten times wrong there.
- **Message decoding**, captured frames for every type the app reads.
- **Session**, key gone after expiry, after an explicit end, after backgrounding.

Live tests against Perpl testnet stay behind an environment variable, so the normal
suite never depends on a third party being up.

## What this corrects in `01-technical-spec.md`

| That document says | Correct |
|---|---|
| iOS 18 minimum | **iOS 18.4 minimum.** 18.0 to 18.3 return wrong PRF values, which means a different address |
| Two contract calls ever | **Three.** `allowOrderForwarding` is mandatory and `createAccount` does not set it |
| `Exchange.withdraw` | `withdrawCollateral` |
| `getAccountByAddr` returns a `u32` | Returns a struct, and reverts when no account exists |
| ERC-2612 might remove the approve | It cannot. The Exchange has no permit-aware entry point. Permit stays as the foundation of the ERC-3009 relayer, which is version two |
| `testnet.monadexplorer.com` | Retired. Use Etherscan V2 multichain, `chainid=10143` |
| Funding roughly hourly | 2,580 seconds. 43 minutes |
