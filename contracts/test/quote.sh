#!/bin/sh
# A live 0x AllowanceHolder transaction from Desk's production quote endpoint, for the fork
# tests: quote.sh <taker> buy <token> <ausd>  |  quote.sh <taker> sell <token> <amount>
set -eu
base="${DESK_API:-https://web-lovat-nine-49.vercel.app}/api/swap-quote?view=swap&user=$1&token=$3&amount=$4&symbol=T"
case "$2" in
  buy) url="$base&sell=AUSD" ;;
  sell) url="$base&sell=TOKEN&buy=AUSD" ;;
esac
curl -sf "$url" | python3 -c 'import json,sys; print(json.load(sys.stdin)["transaction"]["data"])'
