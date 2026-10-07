/// Desk's service worker receives push and opens the app when a notification is clicked.
/// It never handles a fetch, so nothing is cached or rewritten.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch { data = { title: "Desk", body: event.data ? event.data.text() : "" }; }
  const title = typeof data.title === "string" && data.title ? data.title : "Desk";
  const options = {
    body: typeof data.body === "string" ? data.body : "",
    icon: "/brand/apple-touch-icon.png",
    badge: "/brand/mark-d.png",
    data: { url: typeof data.url === "string" ? data.url : "/app" },
  };
  if (typeof data.tag === "string" && data.tag) { options.tag = data.tag; options.renotify = true; }
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = new URL(event.notification.data?.url || "/app", self.location.origin).href;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const open = windows.find((client) => client.url.startsWith(`${self.location.origin}/app`));
    if (open) {
      await open.focus();
      open.postMessage({ type: "navigate", url });
      return;
    }
    await self.clients.openWindow(url);
  })());
});

self.addEventListener("pushsubscriptionchange", (event) => {
  event.waitUntil(self.clients.matchAll({ type: "window" }).then((windows) => {
    for (const client of windows) client.postMessage({ type: "resubscribe" });
  }));
});
