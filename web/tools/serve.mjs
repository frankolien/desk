// Serves public/ on 8790 with /api/* proxied to production, so the live ticker,
// figures and trader slider render locally without the functions' env.
//   node web/tools/serve.mjs
import http from "node:http";
import { readFile } from "node:fs/promises";
import { dirname, extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "public");
const UPSTREAM = process.env.DESK_API ?? "https://web-lovat-nine-49.vercel.app";
const PORT = Number(process.env.PORT ?? 8790);
const types = {
  ".html": "text/html; charset=utf-8", ".css": "text/css", ".js": "text/javascript", ".mjs": "text/javascript",
  ".mp4": "video/mp4", ".webp": "image/webp", ".png": "image/png", ".jpg": "image/jpeg", ".svg": "image/svg+xml",
  ".woff2": "font/woff2", ".json": "application/json", ".txt": "text/plain", ".xml": "application/xml",
};

http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  if (url.pathname.startsWith("/api/")) {
    try {
      const upstream = await fetch(UPSTREAM + url.pathname + url.search, { headers: { accept: "application/json" } });
      res.writeHead(upstream.status, { "content-type": upstream.headers.get("content-type") ?? "application/json" });
      res.end(Buffer.from(await upstream.arrayBuffer()));
    } catch (error) {
      res.writeHead(502, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: String(error) }));
    }
    return;
  }
  let path = normalize(url.pathname);
  if (path === "/") path = "/index.html";
  try {
    const body = await readFile(join(ROOT, path));
    res.writeHead(200, { "content-type": types[extname(path)] ?? "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("not found");
  }
}).listen(PORT, () => console.log(`Desk site on http://127.0.0.1:${PORT}/ (api → ${UPSTREAM})`));
