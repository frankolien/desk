# contracts

`DeskCopyHook` — the on-chain fence around Desk's spot copy key. Design: `docs/spot-copy.md`.

```sh
cd contracts
forge install foundry-rs/forge-std --no-git   # once
forge test                                    # forks Monad mainnet; fetches live 0x quotes (ffi)
```

The hook must be deployed at an address whose low five bits are `11110` (Calibur reads the
callbacks from them), so deployment goes through the CREATE2 factory with a mined salt:
`script/deploy.sh`.
