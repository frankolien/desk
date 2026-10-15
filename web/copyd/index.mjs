/// copyd: the server's copy engine as a process. Runs next to the worker on Railway, in an EU
/// region (Perpl refuses US addresses), from the same image:  node copyd/index.mjs
///
/// Env: KV_REST_API_URL / KV_REST_API_TOKEN (required), MONAD_MAINNET_RPC, MONAD_WS,
/// COPYD_SWEEP_MS (30000), DESK_API and CRON_SECRET (to retire abandoned keys and to send
/// notifications through the API, which holds the APNs key). Live copies additionally need
/// COPYD_AWS_ACCESS_KEY_ID / COPYD_AWS_SECRET_ACCESS_KEY (desk-copyd's), COPY_AWS_REGION and
/// COPY_TOKEN_KEY; without them, or with COPY_HALT set, copyd runs shadow copies only.
import { redisStore } from "../api/_store.mjs";
import { chainReader, openMarkets } from "../api/traders.mjs";
import { createEngine } from "./engine.mjs";
import { createLease } from "./lease.mjs";
import { createRunner } from "./runner.mjs";
import { createNotifier, apiSender } from "./notify.mjs";
import { readTrader } from "./books.mjs";
import { watchPositions } from "./watcher.mjs";
import { createExecutor } from "./executor.mjs";

const SWEEP_MS = Number(process.env.COPYD_SWEEP_MS || 30_000);
const PENDING_SWEEP_MS = 10 * 60_000;

const store = redisStore();
if (!store) { console.error("copyd: KV_REST_API_URL and KV_REST_API_TOKEN are required"); process.exit(1); }

const chain = chainReader();
// Notifications go out through Desk's API, which holds the APNs key; copyd keeps none.
const notify = process.env.DESK_API && process.env.CRON_SECRET
  ? createNotifier({ send: apiSender({ base: process.env.DESK_API, secret: process.env.CRON_SECRET }) })
  : async () => ({ skipped: "notifications not configured" });

/// Live copies need desk-copyd's own AWS credentials (it may only Sign with Desk keys) and the
/// key that opens Perpl tokens. Without them, live rules are skipped and shadow copies run.
function liveKms() {
  const { COPYD_AWS_ACCESS_KEY_ID: accessKeyId, COPYD_AWS_SECRET_ACCESS_KEY: secretAccessKey, COPY_TOKEN_KEY } = process.env;
  if (!accessKeyId || !secretAccessKey || !COPY_TOKEN_KEY || process.env.COPY_HALT) return null;
  let client = null;
  return {
    async send(command) {
      if (!client) {
        const { KMSClient } = await import("@aws-sdk/client-kms");
        client = new KMSClient({ region: process.env.COPY_AWS_REGION || "eu-north-1", credentials: { accessKeyId, secretAccessKey } });
      }
      return client.send(command);
    },
  };
}

// Three beats' grace: a holder that misses two still holds; one that stops is replaced.
const lease = createLease({ store, ttlMs: SWEEP_MS * 3 });
let runner = null;
const kms = liveKms();
const executor = kms
  ? createExecutor({ store, kms, tokenKey: process.env.COPY_TOKEN_KEY, mayAct: () => runner?.mayAct() ?? false })
  : null;
const engine = createEngine({
  store, notify, executor,
  markets: () => openMarkets(),
  readTrader: async (address) => readTrader(chain, await openMarkets(), address),
});
executor?.attach(engine);
runner = createRunner({ engine, lease, store });

const watcher = watchPositions({
  onAccount: (accountId) => { runner.onAccount(accountId); },
  onState: (up) => console.log(`copyd: position events ${up ? "streaming" : "lost; the sweep covers the gap"}`),
});

let stopping = false;

/// Keys prepared for an enrolment nobody finished are retired by the API (only desk-copy-api
/// may retire keys); copyd asks it to look every ten minutes.
const pendingTimer = process.env.DESK_API && process.env.CRON_SECRET
  ? setInterval(() => {
    if (stopping || !lease.holds()) return;
    fetch(`${process.env.DESK_API}/api/copy/sweep`, { method: "POST", headers: { authorization: `Bearer ${process.env.CRON_SECRET}`, "content-type": "text/plain" } })
      .then((r) => r.json()).then((r) => { if (r.retired) console.log(`copyd: retired ${r.retired} abandoned key(s)`); })
      .catch((error) => console.warn(`copyd: pending sweep: ${error.message}`));
  }, PENDING_SWEEP_MS)
  : null;

async function loop() {
  while (!stopping) {
    const started = Date.now();
    try {
      const result = await runner.tick();
      if (!result.swept) console.log(`copyd: idle (${result.reason})`);
    } catch (error) {
      console.error(`copyd: tick: ${error.message}`);
    }
    await new Promise((resolve) => setTimeout(resolve, Math.max(1_000, SWEEP_MS - (Date.now() - started))));
  }
}

async function shutdown(signal) {
  if (stopping) return;
  stopping = true;
  console.log(`copyd: ${signal}, stopping`);
  watcher.stop();
  clearInterval(pendingTimer);
  await runner.idle();
  executor?.stop();
  await lease.release().catch(() => {});
  process.exit(0);
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

console.log(`copyd: lease ${lease.id}, sweeping every ${SWEEP_MS} ms, live copies ${executor ? "on" : "off (shadow only)"}`);
loop();
