/// Position events off the exchange, as a hint to read a trader now rather than at the next
/// sweep: the same five topics the app subscribes to. No event parameter is indexed, so the
/// account id is the second word of the data. Event contents are never trusted beyond that; the
/// book read off the contract decides what happened.
export const EXCHANGE = "0x34B6552d57a35a1D042CcAe1951BD1C370112a6F";
export const TOPICS = [
  "0x04cc3d2fc73a9dca30eba1d05eca80b1b1216350243580027046f434fed4db18", // PositionOpenedV2
  "0x599b5f439ed4daf1f28ae8638e5439d3982e8001fb26dd8f70021b38672eb26f", // PositionClosed
  "0x6fc9c0ea1c0531654320ba06740c802447dbdef7c26cf749c4f12553cdd958a9", // PositionLiquidated
  "0x99a74f70c224396b9ba5fcd5a6e5f480db23e7a25a2b16a8c133ec2efb3e646c", // PositionIncreasedV2
  "0xcd4a9f7ae1cc250eaa0be6bdb30d07efaf0faafb4ff0e76d8fe09a8373e43f85", // PositionDecreased
];

export const subscription = (exchange = EXCHANGE, id = 1) =>
  JSON.stringify({ jsonrpc: "2.0", id, method: "eth_subscribe", params: ["logs", { address: exchange, topics: [TOPICS] }] });

/// The account id in a log frame, or null for anything else.
export function accountInFrame(text) {
  let frame;
  try { frame = JSON.parse(text); } catch { return null; }
  const log = frame?.params?.result;
  const topic = log?.topics?.[0]?.toLowerCase();
  if (!topic || !TOPICS.includes(topic) || typeof log.data !== "string") return null;
  const digits = log.data.startsWith("0x") ? log.data.slice(2) : log.data;
  if (digits.length < 128) return null;
  const word = digits.slice(64, 128);
  if (!/^0{48}[0-9a-fA-F]{16}$/.test(word)) return null;
  return BigInt(`0x${word.slice(48)}`).toString();
}

/// Keeps one subscription open, reconnecting with 1 s doubling to 30 s. `onAccount` receives
/// every account id that moved; the engine decides whether it is anyone's trader.
export function watchPositions({ url = process.env.MONAD_WS || "wss://rpc.monad.xyz", onAccount, onState = () => {}, WebSocketImpl = globalThis.WebSocket, logger = console }) {
  let socket = null;
  let delay = 1_000;
  let stopped = false;
  let timer = null;

  function connect() {
    if (stopped) return;
    try { socket = new WebSocketImpl(url); } catch (error) { logger.warn?.(`copyd: watcher ${error.message}`); return retry(); }
    socket.addEventListener("open", () => { socket.send(subscription()); });
    socket.addEventListener("message", (event) => {
      const text = typeof event.data === "string" ? event.data : String(event.data);
      if (text.includes('"id":1') && text.includes("result")) { delay = 1_000; onState(true); return; }
      const account = accountInFrame(text);
      if (account) onAccount(account);
    });
    socket.addEventListener("close", () => { onState(false); socket = null; retry(); });
    socket.addEventListener("error", () => { try { socket?.close(); } catch {} });
  }
  function retry() {
    if (stopped) return;
    clearTimeout(timer);
    timer = setTimeout(connect, delay);
    delay = Math.min(delay * 2, 30_000);
  }
  connect();
  return { stop() { stopped = true; clearTimeout(timer); try { socket?.close(); } catch {} } };
}
