# The relying party

This exists for one file: `/.well-known/apple-app-site-association`.

Apple fetches it directly and **will not follow a redirect**, while a browser follows
one silently — so a file that looks correct when checked by hand can still fail on
device. `vercel.json` pins the content type and switches off `cleanUrls` and
`trailingSlash`, both of which introduce redirects.

The `apps` entry is `TEAMID.bundleid`. Changing either side of that string breaks the
association, and the app's `webcredentials:` entitlement must name this exact domain.

The domain is **desk-trading-opia.vercel.app**, a stable alias on the team's `web`
project. The earlier `desk-trading.vercel.app` deployment belongs to another Vercel
account and cannot be updated by this project.

Deployment Protection must stay off. With it on, Vercel answers 302 to an SSO page, and
that is the redirect Apple refuses to follow while a browser follows it silently.

Verify with `tools/check-relying-party.sh` before creating the first passkey — with no
arguments it also compares the two copies of the domain in the repository. Every passkey
binds to this domain permanently.

## Server-side market credentials

The functions under `api/` read credentials only from Vercel environment variables. Never
embed them in the iOS target or expose them through a public-prefixed variable.

- `OKX_API_KEY`, `OKX_SECRET_KEY`, and `OKX_PASSPHRASE` power discovery, market data,
  Solana quotes, and the primary spot-quote route.
- `ZEROX_API_KEY` enables the 0x Swap API v2 fallback for supported EVM chains.

`api/swap-quote` returns a `provider` field (`okx` or `0x`) so production failures can be
traced without exposing either credential.

## Testnet faucet

`api/faucet` sends a Desk wallet 0.1 test MON when it holds under 0.05, and claims
10,000 test AUSD from Agora's faucet on its behalf when it holds under 100. The paying
wallet's key is `FAUCET_PRIVATE_KEY`, set only in Vercel; it must never be a key that
holds anything on mainnet. `MONAD_TESTNET_RPC` optionally overrides the public RPC.

Create the key without it ever being printed or written to disk. Only the address is
shown, on stderr:

```sh
node -e "import('viem/accounts').then(({generatePrivateKey,privateKeyToAccount})=>{const k=generatePrivateKey();process.stdout.write(k);console.error('Faucet address:',privateKeyToAccount(k).address)})" \
  | vercel env add FAUCET_PRIVATE_KEY production
```

Then send testnet MON to that address and redeploy. Each funded wallet costs about 0.13
MON (the drip plus the AUSD claim's gas); the function keeps 0.05 back for gas and reports
`faucet-empty` below that, and the app falls back to Monad's own faucet.
