# Desk over MCP

Desk answers ChatGPT, Claude and any other MCP client at `https://trydesk.trade/mcp`:
thirteen read-only tools over Desk's public data, and one card the `show_` tools render.
The submission package for OpenAI's plugin directory is in `plugin/`.

## Shape

- **Where it runs.** Inside the v1 function. `vercel.json` rewrites `/mcp` to
  `/api/v1?path=mcp`, and v1 imports `api/_mcp.mjs` only on that route. No new
  Vercel function.
- **SDK.** `@modelcontextprotocol/server` 2.x, through `createMcpHandler`: a fresh
  server per request, stateless, serving 2025-era clients and the 2026-07-28
  protocol from the same factory.
- **Data.** `api/_mcp-data.mjs` reads Desk's own public API over HTTPS, so assistant
  traffic shares the edge cache and the last-good Redis answers instead of hitting
  OKX on every call. `MCP_API_BASE` points it elsewhere.
- **Tools.** Data tools (`search_tokens`, `get_trending_tokens`, `get_token`,
  `get_token_candles`, `get_wallet`, `get_smart_money`, `get_top_perp_traders`,
  `get_perp_trader_stats`, `get_perp_markets`) return answers with no UI. Render
  tools (`show_wallet_card`, `show_token_card`, `show_top_perp_traders_card`,
  `show_smart_money_card`) return the same data plus the card. Every tool is
  `readOnlyHint: true`, `destructiveHint: false`, `openWorldHint: true`.
- **Card.** `web/mcp/card.html`, one page for all four kinds, MCP Apps bridge first
  and `window.openai` as a fallback. Every value is set as text.

## Decisions worth keeping

- **Spam is left out of wallet totals.** One batched price check per wallet drops
  holdings with no pool and no volume, or worth more than twenty times their pool,
  and lists them under `leftOut`. Without it, airdropped spam made Vitalik's wallet
  read $240M.
- **Images come from eight hosts only** (`IMAGE_HOSTS`): the tools drop every other
  URL, and the same list is the card's CSP, so what the card loads and what it
  declares never differ.
- **`ui.domain` is not set.** Claude validates it against a hash of the exact
  connector URL and refuses to render on a mismatch. ChatGPT gets its dedicated
  origin from `openai/widgetDomain` instead.
- **One colour scheme at a time.** With `color-scheme: light dark`, Chrome followed
  the device and painted a light-themed card on black.
- **Height is reported straight after rendering**, from the body, not from an
  animation frame a hidden frame isn't promised.

## Limits

`/mcp` takes 600 requests a minute per address (ChatGPT and Claude call from shared
ranges). Wallet reads take 20 a minute per ChatGPT user, keyed by its anonymous
`openai/subject`, or per address without one.

## Testing

- `web/test/mcp.test.mjs` runs the handshake, annotations, the card's CSP, every
  tool, failures, the per-user limit, the Node adapter and the v1 route against a
  fixture API.
- The card was checked in headless Chrome inside a stand-in host with the strictest
  CSP it must live under: all four kinds, light and dark, 343 and 680 px wide, and
  each interaction's bridge message.

## Submitting to OpenAI

1. Verify the publishing identity in the OpenAI Platform dashboard
   (Settings, Organization, General).
2. In the plugin portal, start the MCP connection. It shows a challenge token: set it
   as `OPENAI_APPS_CHALLENGE` in Vercel production and redeploy, so
   `/.well-known/openai-apps-challenge` serves it.
3. Record the demo video and put its URL in `plugin/plugin.json` under
   `review.demo_recording_url`.
4. `sh plugin/pack.sh` builds the ZIP. Upload it, connect the server, scan the tools,
   and submit.
