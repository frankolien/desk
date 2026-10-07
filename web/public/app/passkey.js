// The passkey ceremony in a browser. The relying party is the phone's, so the same passkey
// opens the same account here; trydesk.trade may use it because the relying party publishes
// /.well-known/webauthn naming this origin (WebAuthn related origins). A browser without that
// support says so, and the sign-in can be finished on the relying party's own origin instead.
import { PRF_SALT } from "./keys.js";

const PRODUCTION_RP_ID = "desk-trading-opia.vercel.app";
/// localhost stands in for the relying party on a developer's machine, where no browser
/// would accept the production one; nothing made there can be used anywhere else.
export const RP_ID = location.hostname === "localhost" || location.hostname === "127.0.0.1" ? location.hostname : PRODUCTION_RP_ID;
export const RP_ORIGIN = `https://${PRODUCTION_RP_ID}`;

export class PasskeyError extends Error {
  constructor(code, message, cause) { super(message); this.code = code; this.cause = cause; }
}

export const passkeysAvailable = () => typeof PublicKeyCredential !== "undefined" && Boolean(navigator.credentials?.get);
export const onRelyingPartyOrigin = () => location.hostname === PRODUCTION_RP_ID;

const challenge = () => crypto.getRandomValues(new Uint8Array(32));
const prfExtension = { prf: { eval: { first: PRF_SALT } } };

function prfOutput(credential) {
  const first = credential?.getClientExtensionResults?.().prf?.results?.first;
  return first ? new Uint8Array(first) : null;
}

function translate(error) {
  if (error instanceof PasskeyError) return error;
  const name = error?.name ?? "";
  if (name === "NotAllowedError") return new PasskeyError("cancelled", "The passkey prompt was dismissed.", error);
  if (name === "SecurityError") return new PasskeyError("origin", "This browser will not use Desk's passkey from this address.", error);
  if (name === "InvalidStateError") return new PasskeyError("exists", "A passkey for Desk already exists on this device. Sign in with it instead.", error);
  if (name === "NotSupportedError") return new PasskeyError("unsupported", "This browser cannot create passkeys.", error);
  return new PasskeyError("failed", "The passkey step didn't finish.", error);
}

/// Picks any Desk passkey on this device or a nearby phone and evaluates its PRF.
export async function signInWithPasskey() {
  if (!passkeysAvailable()) throw new PasskeyError("unsupported", "This browser has no passkeys.");
  let credential;
  try {
    credential = await navigator.credentials.get({
      publicKey: { challenge: challenge(), rpId: RP_ID, userVerification: "required", allowCredentials: [], extensions: prfExtension },
    });
  } catch (error) { throw translate(error); }
  const prf = prfOutput(credential);
  if (!prf) throw new PasskeyError("prf", "This passkey did not return the secret Desk derives your keys from. On iPhone it needs iOS 18.4 or later.");
  return { prf, credentialId: credential.id };
}

/// Makes a Desk passkey here. The PRF is evaluated at creation where the platform allows and
/// by one sign-in straight after where it does not, so the account exists before this returns.
export async function createPasskey(label = "Desk") {
  if (!passkeysAvailable()) throw new PasskeyError("unsupported", "This browser has no passkeys.");
  let credential;
  try {
    credential = await navigator.credentials.create({
      publicKey: {
        challenge: challenge(),
        rp: { id: RP_ID, name: "Desk" },
        user: { id: crypto.getRandomValues(new Uint8Array(16)), name: label, displayName: label },
        pubKeyCredParams: [{ type: "public-key", alg: -7 }, { type: "public-key", alg: -257 }],
        authenticatorSelection: { residentKey: "required", userVerification: "required" },
        extensions: prfExtension,
      },
    });
  } catch (error) { throw translate(error); }
  let prf = prfOutput(credential);
  if (!prf) {
    if (credential.getClientExtensionResults?.().prf?.enabled === false) {
      throw new PasskeyError("prf", "This passkey cannot hold the secret Desk needs. Use a device with a newer passkey manager.");
    }
    let again;
    try {
      again = await navigator.credentials.get({
        publicKey: { challenge: challenge(), rpId: RP_ID, userVerification: "required", allowCredentials: [{ type: "public-key", id: credential.rawId }], extensions: prfExtension },
      });
    } catch (error) { throw translate(error); }
    prf = prfOutput(again);
    if (!prf) throw new PasskeyError("prf", "This passkey did not return the secret Desk derives your keys from.");
  }
  return { prf, credentialId: credential.id };
}
