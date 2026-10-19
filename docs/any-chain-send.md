# Send anywhere: AUSD out of Desk to any address on any chain, gasless

Status: built 19 Oct 2026 (contract, API, copyd worker, app), not yet deployed. Deploy order at the end. The ask: a Desk user types an address (or a
@tag), picks an amount, and the money arrives on whatever chain that address lives on, in a
stablecoin, without the user holding gas anywhere or knowing which chain they are on. FOMO is
the reference: USDC on Solana in, Monad out, no gas, no chain picker.

## What is true today, measured tonight

**Relay already routes every leg we need, with real liquidity.** Quotes for 20 AUSD from the
Desk wallet on Monad (Relay public `/quote`, no key):

| Route | Arrives | Fee | Time |
|---|---|---|---|
| Monad AUSD → Solana USDC | 19.96 USDC | $0.03 | ~1 s |
| Monad AUSD → Base USDC | 19.97 USDC | $0.02 | ~2 s |
| Monad AUSD → Ethereum AUSD | 19.97 AUSD | $0.03 | ~5 s |
| Monad AUSD → Avalanche AUSD | 19.94 AUSD | $0.06 | ~1 s |
| Monad AUSD → Solana AUSD | 19.57 AUSD | $0.32 | ~1 s (thin: avoid, send USDC on Solana) |
| Solana USDC → Monad AUSD (the deposit direction) | 19.97 AUSD | $0.03 | ~1 s |
| Base USDC → Monad AUSD | 19.97 AUSD | $0.02 | ~1 s |

Relay lists Monad (143) and Solana (792703809) among 60 chains, knows AUSD on Monad, Ethereum,
Avalanche, Polygon, Katana, Mantle and Solana, and already carries `RELAY_API_KEY` in our
Vercel production env from the gasless-sale work.

**AUSD on Monad supports EIP-2612 `permit`** (`DOMAIN_SEPARATOR`, `PERMIT_TYPEHASH`, `nonces`,
name "AUSD", version "1", 6 decimals). So an AUSD move can be authorised by a signature alone;
somebody else can submit the transaction and pay the gas.

**AUSD is one supply across chains** (Agora on LayerZero OFT since 13 Nov 2025, Monad first):
1:1, zero slippage between Monad, Ethereum, Base, Arbitrum, Avalanche, Polygon, Mantle,
Katana, Immutable, and natively on Solana (`AUSD1jCc…UEB9`). Agora's own bridge contract on
Monad is `0x9CaB7Ede13dc56652E44D2404E969C212f22689b`.

**Circle CCTP V2 lists Monad** (standard transfer; Fast Transfer only as a destination) and
Solana (Fast Transfer source, ~8 s). Relevant only for USDC in and out; Desk's unit is AUSD, so
a swap is needed anyway, and Relay's solver does the swap and the bridge in one step.

**Relay's gasless flows**, from their docs: permit flow (EIP-3009 or Permit2; USDC is "fully
gasless", other ERC-20s need a one-time on-chain approval to Permit2), ERC-4337 flow, and
EIP-7702 flow (our Calibur `originGasOverhead: 80000` path). The 4337 and 7702 flows submit
through `POST /execute`, which the gasless-execution page says is for Enterprise partners; our
key was issued for exactly that, and the gasless sale has never been proven end to end with
it (see [[gasless-sales]] memory). Solana origin is gasless through a sponsor fee payer.

**Monad's reserve rule** (docs/spot-copy.md): a Calibur-delegated EOA cannot push its MON below
10 MON by value transfer. Gas is exempt, AUSD transfers are exempt. So delegation on Monad is
fine for AUSD sends, and spot-copy users are already delegated.

## Why the user cannot just "send" today

Sending AUSD from Monad to anywhere else is two Monad transactions (approve the Relay router,
then deposit). Both need MON for gas. A Desk user signed in with a passkey has AUSD and, after
a sale or a swap, often zero MON. The deposit direction is already fine: Relay accepts any
chain in and Crossmint covers cards.

## Three ways to make the outbound leg gasless, ranked

### 1. Desk pays the gas on Monad, through our own relayer and a permit (recommended first)

What the user signs: one EIP-712 message, with Face ID, exactly as a send is signed today.
Two parts inside it:
- an AUSD `permit` giving a Desk forwarder contract an allowance for the amount, with a short
  deadline;
- a Desk "send intent": recipient, destination chain, destination token, minimum out, expiry.

What Desk does: the API (Vercel, fra1) asks Relay for a quote with `user` = the forwarder
contract and `refundTo` = the user's wallet (Relay accepts a contract as the depositor; checked
tonight, the quote comes back with the router calls addressed to it). Desk's relayer key, the
same KMS key that already pays all spot-copy gas on Monad (`0x287A…196b`, funded with 40 MON),
calls `Forwarder.send(permit, intent, relayCalls)`. The contract pulls the AUSD with
`transferFrom`, and either:
- recipient on Monad: transfers it straight to them (same-chain sends become gasless too), or
- recipient elsewhere: approves the Relay router and makes the deposit, with the quote's
  `recipient` set to the final address on the final chain.

Relay's solver fills on the destination in a few seconds. Fees come out of the amount, shown
to the user before they sign, as "You send 20.00 · They get 19.96 USDC on Solana". Gas on
Monad costs Desk about $0.00005 per send.

Why first: it works for every Desk user tonight, delegated or not, needs no Relay enterprise
feature, uses a signing flow the app already has, and the money never sits with Desk. The
forwarder is a small contract: one function, no storage, no admin, the intent checked
against the permit, the Relay router address and the calldata's recipient pinned so the
relayer cannot redirect anything. Fork-test it like `DeskCopyHook`.

Cost of trust: the user trusts Desk to submit (it can decline, never redirect). Same as the
server copy today.

### 2. Relay's own gasless path with our 7702 delegation

Spot-copy users already run Calibur on Monad. For them, the app can sign a Calibur
`SignedBatchedCall` over Relay's approve + deposit (the exact mechanism of the gasless sale)
and Desk, not Relay, can be the submitter paying gas, because a batched call signed by the
account can be broadcast by anyone. That removes the forwarder contract and the permit, but
only for delegated wallets, and delegating every wallet just to send money is a bigger step
than a send deserves. Keep this as the path for wallets that are already delegated once the
forwarder exists; it is the same server code with a different signature.

Relay's `/execute` with origin fees in the output, the way the gasless sale is wired, is the
same idea with Relay's relayer instead of ours. It depends on the key's entitlement, which is
unproven. Not the foundation.

### 3. Deposit-address sends

Relay can give a one-off deposit address on Monad for a quote (`useDepositAddress`, checked
tonight); anything sent to it is forwarded to the recipient's chain. It is the right tool for
*receiving* from exchanges and wallets we do not control (a "Deposit from anywhere" address
in Fund), not for sending: the user still needs gas to move AUSD to that address.

## The product, in one screen

The Send sheet already asks who and how much. Add nothing visible for the common case:

- The To field accepts a Monad address, a Solana address, a .nad / ENS name or a @tag. The
  chain is inferred from the address format and the name service; Solana addresses are base58.
- When the address is on another chain, one muted line under the amount: "Arrives as USDC on
  Solana · they get $19.96 · about 5 s". Stablecoin choice per chain: AUSD where Agora issues
  it natively (Ethereum, Base, Arbitrum, Avalanche, Polygon), USDC on Solana (the AUSD pool
  there is thin), USDC elsewhere.
- Face ID signs. The receipt says "Sent $20 to @frank · USDC on Solana", with the Relay
  request id behind a "Track" row that polls `GET /intents/status` until filled.
- Money kept in Perpl ("trading") moves to the wallet first, as Withdraw does today, then goes.

Guards: minimum $1 after fees, maximum per send and per day on the forwarder (set in the
intent, enforced on chain), a 2-minute deadline on the permit, refuse when the quote's impact
is worse than 1%, refuse Solana AUSD and route to USDC.

## Receiving from anywhere (the other half of FOMO)

Fund already takes Relay from any chain and Crossmint for cards. Two cheap additions:
- a standing Relay deposit address per user for Solana USDC and for EVM USDC, shown in Fund
  as "Send USDC from any wallet to this address; it lands as AUSD on your Desk"; Relay charges
  about $0.03 and lands in seconds (Solana USDC → Monad AUSD measured at 19.97 out of 20);
- Circle's CCTP V2 Fast Transfer for USDC from Solana if we ever want Circle's rail instead
  of a solver; Monad is a destination, ~8 s, native USDC, then a swap to AUSD.

## Deploying what is built

1. `bash web/copyd/send-setup.sh` deploys DeskSend from the spot copy key at the pinned address
   `0x41FA5ca5b73fb6ea8E3CA219f8f2BC8CE35fa04E` (CREATE2, salt zero). The build must match the
   fork-tested bytecode; the script refuses if the address would differ.
2. `cd web && vercel deploy --prod --yes` for the `send`, `send-submit` and `send-status` views.
3. `bash web/copyd/deploy.sh` for the worker that submits queued sends.
Then one real send from a phone with a few dollars of AUSD, to a Monad address first, then to
Solana.

## Build order, as built

1. Forwarder contract in `contracts/`: `send(permit, intent, calls)`; fork tests on Monad
   against the live AUSD and Relay router; deploy with the spot-copy key.
2. API: `/api/send` folded into an existing function (the twelve-function cap): quote (Relay,
   contract as user, refund to wallet), prepare (typed data for the app), submit (verify
   signature, simulate, relayer sends), status (Relay intents).
3. App: Send sheet accepts any-chain addresses, shows the arrival line, signs the one message,
   receipt with tracking. SendSheet already has the recipient and amount model.
4. Fund: the deposit addresses.
5. Later: 7702 path for delegated wallets; Agora's own OFT bridge for AUSD-to-AUSD moves if
   it ever beats Relay on fee (today Relay's $0.03 is already below any LayerZero gas).

## Sources

- Relay quotes and currency list: `api.relay.link/quote`, `/currencies/v2`, `/chains`, 19 Oct 2026.
- Relay gasless swaps and execution: docs.relay.link/features/gasless-swaps, /features/gasless-execution, /references/api/execute.
- AUSD permit probe: eth_call on `0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a`, rpc.monad.xyz.
- Agora: agora.finance/blog/ausd-now-borderless-onchain; docs.agora.finance/developer/contract-deployments.
- Circle: developers.circle.com/cctp/cctp-supported-blockchains.
- FOMO: Relay case study and reviews (Relay as the engine, 4337 paymaster for in-app gas; external sends not confirmed gasless).
