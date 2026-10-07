// The browser's cryptography, bundled once into public/app/vendor/desk-crypto.js. The page has
// no build step, so this is the one vendored artefact beside the chart library:
//
//   NODE_PATH=<a node_modules holding viem, @scure and @noble> \
//   npx esbuild web/tools/crypto-entry.mjs --bundle --format=esm --platform=browser --minify \
//     --outfile=web/public/app/vendor/desk-crypto.js
export { sha256, sha512 } from "@noble/hashes/sha2";
export { hmac } from "@noble/hashes/hmac";
export { keccak_256 } from "@noble/hashes/sha3";
export { ed25519 } from "@noble/curves/ed25519";
export { HDKey } from "@scure/bip32";
export { entropyToMnemonic, mnemonicToSeedSync } from "@scure/bip39";
export { wordlist } from "@scure/bip39/wordlists/english";
export { base64urlnopad, hex } from "@scure/base";
export { privateKeyToAccount } from "viem/accounts";
export { createPublicClient, http, encodeFunctionData, decodeFunctionResult, parseAbi, hashTypedData, formatUnits, parseUnits } from "viem";
