---
name: research-with-desk
description: Research a crypto token, a wallet or a perpetuals trader with Desk's read-only market tools, Monad first. Use when the person asks what a token is doing or whether it looks risky, what a wallet holds or how it trades, who leads Perpl, or what smart-money wallets are buying.
---

Use Desk's tools to answer questions about tokens, wallets and traders with live figures. The person's own instructions come first: if they ask for a specific tool, chain, format or level of detail, do that.

## Tokens

1. If you only have a name or symbol, call `search_tokens`. When several tokens share the symbol, prefer the one on the chain the person named, otherwise the one with the most liquidity, and say which one you picked by chain and contract.
2. Call `get_token` for figures and Desk's risk check. It also shows the person a card with the price chart, so keep the reply short and lead with what they asked.
3. For price action over days or weeks, call `get_token_candles` with `4H` or `1D`.
4. Report Desk's risk level and its reasons as Desk states them. Thin liquidity and concentrated holders are facts about the market, not predictions.

## Wallets

1. Call `get_wallet` with the address or the name exactly as given (vitalik.eth, name.nad, a Solana address). It also shows the person a card of the wallet.
2. If `leftOut` is not empty, say that those tokens were left out of the total because they have no real market, and name them.
3. If `monadTrading.status` is `indexing`, say the Monad trading record is still being read and that asking again in a minute gives the full record.
4. Open positions on Perpl appear under `perps`. For a trader's past record on Perpl, call `get_perp_trader_stats`.

## Perpetuals and smart money

- `get_top_perp_traders` ranks Perpl's traders by open profit right now. That is a snapshot, not a track record: pair it with `get_perp_trader_stats` before describing anyone as a good trader.
- `get_perp_markets` gives mark price, funding and leverage. Funding is quoted per interval; give the interval with the rate.
- `get_smart_money` lists recent trades by wallets with a winning 30-day record. Past results don't predict the next trade.

## Always

- Use only figures the tools returned. Don't estimate a price, a balance or a profit the tools didn't give. Mention when the data is from (`asOf`) if it's more than a few minutes old.
- Desk only reads. If the person asks to buy, sell, transfer or sign, say Desk's tools can't do that, and offer the token's or wallet's `url` so they can open it in Desk's app themselves.
- Don't tell the person what to buy, sell or hold. Describe what the data shows and let them decide.
- If a tool answers with an error, repeat its sentence plainly and suggest the next step it implies, such as checking an address or trying again shortly.
