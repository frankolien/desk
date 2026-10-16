/// A copier's trading key, made inside AWS KMS and never exported. KMS signs each request
/// (Ed25519, PureEdDSA over the raw message) and logs every signature to CloudTrail; nothing in
/// Desk, the server included, can read the private half. One key per enrolment, never reused:
/// Perpl will not re-enrol a revoked key.
///
/// The client is injected so tests run without AWS; production passes a KMSClient built from the
/// engine's IAM role, whose policy allows Sign only on `alias/desk-copy/*`.
const SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

export const KEY_SPEC = "ECC_NIST_EDWARDS25519";
export const SIGNING_ALGORITHM = "ED25519_SHA_512";

export async function kmsCommands() {
  return import("@aws-sdk/client-kms");
}

/// The 32-byte public key out of KMS's DER SubjectPublicKeyInfo, refused if it is not Ed25519.
export function ed25519FromSpki(der) {
  const bytes = Buffer.from(der);
  if (bytes.length !== SPKI_PREFIX.length + 32 || !bytes.subarray(0, SPKI_PREFIX.length).equals(SPKI_PREFIX)) {
    throw new Error("KMS returned a public key that is not Ed25519");
  }
  return bytes.subarray(SPKI_PREFIX.length);
}

export const aliasFor = ({ network, address, generation }) =>
  `alias/desk-copy/${network}/${address.toLowerCase()}/${generation}`;

/// A signer over an existing KMS key, the same shape as `localSigner`.
export async function kmsSigner({ client, keyId, commands }) {
  const { GetPublicKeyCommand, SignCommand } = commands ?? await kmsCommands();
  const info = await client.send(new GetPublicKeyCommand({ KeyId: keyId }));
  if (info.KeySpec && info.KeySpec !== KEY_SPEC) throw new Error(`KMS key is ${info.KeySpec}, not ${KEY_SPEC}`);
  const publicKey = ed25519FromSpki(info.PublicKey);
  return {
    kind: "kms",
    keyId: info.KeyId ?? keyId,
    publicKey,
    async sign(message) {
      const answer = await client.send(new SignCommand({
        KeyId: keyId, Message: Buffer.from(message), MessageType: "RAW", SigningAlgorithm: SIGNING_ALGORITHM,
      }));
      return Buffer.from(answer.Signature);
    },
  };
}

/// A new key for one enrolment, tagged with whose it is. Returns its signer.
export async function createKey({ client, network, address, generation, commands }) {
  const c = commands ?? await kmsCommands();
  const created = await client.send(new c.CreateKeyCommand({
    KeySpec: KEY_SPEC, KeyUsage: "SIGN_VERIFY",
    Description: `Desk Auto-Copy trading key for ${address} on ${network}, enrolment ${generation}`,
    Tags: [
      { TagKey: "desk:purpose", TagValue: "auto-copy" },
      { TagKey: "desk:network", TagValue: network },
      { TagKey: "desk:account", TagValue: address.toLowerCase() },
      { TagKey: "desk:stage", TagValue: "pending" },
    ],
  }));
  const keyId = created.KeyMetadata.KeyId;
  try {
    await client.send(new c.CreateAliasCommand({ AliasName: aliasFor({ network, address, generation }), TargetKeyId: keyId }));
  } catch (error) {
    // A key without its name would be found by nobody and billed every month.
    await retireKey({ client, keyId, commands: c }).catch(() => {});
    throw error;
  }
  return kmsSigner({ client, keyId, commands: c });
}

/// A key starts `pending`: only the API may sign with it, and only to prove possession to Perpl.
/// Once Perpl has registered it, it becomes `enrolled`, and only copyd may sign with it. IAM lets
/// the API make that change one way and nobody reverse it (web/copyd/iam/).
export async function markEnrolled({ client, keyId, commands }) {
  const c = commands ?? await kmsCommands();
  await client.send(new c.TagResourceCommand({ KeyId: keyId, Tags: [{ TagKey: "desk:stage", TagValue: "enrolled" }] }));
}

/// Off at once, gone after the shortest wait KMS allows. A disabled key cannot sign, so this is
/// the server's half of turning Auto-Copy off; the other half is revoking the key at Perpl.
export async function retireKey({ client, keyId, commands }) {
  const c = commands ?? await kmsCommands();
  await client.send(new c.DisableKeyCommand({ KeyId: keyId }));
  await client.send(new c.ScheduleKeyDeletionCommand({ KeyId: keyId, PendingWindowInDays: 7 }));
}
