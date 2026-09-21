(function () {
  "use strict";

  var form = document.querySelector("[data-try]");
  if (!form) return;

  var ROUTES = {
    index: "/api/v1",
    top: "/api/v1/traders/top?limit=5",
    history: "/api/v1/traders/{address}/history",
    identity: "/api/v1/identity/{address}",
    wallet: "/api/v1/wallets/{address}",
    signals: "/api/v1/tokens/signals?window=6h",
    health: "/api/v1/health",
    stats: "/api/v1/stats",
  };
  var SHOWN = ["X-RateLimit-Limit", "X-RateLimit-Remaining", "X-RateLimit-Reset", "Retry-After", "Content-Type", "Cache-Control"];

  var endpoint = form.querySelector("[name=endpoint]");
  var address = form.querySelector("[name=address]");
  var run = form.querySelector("[data-run]");
  var urlEl = form.querySelector("[data-url]");
  var statusEl = form.querySelector("[data-status]");
  var headersEl = form.querySelector("[data-headers]");
  var output = form.querySelector("[data-output]");

  function needsAddress() { return ROUTES[endpoint.value].indexOf("{address}") >= 0; }
  function url() { return ROUTES[endpoint.value].replace("{address}", address.value.trim()); }
  function refresh() {
    address.disabled = !needsAddress();
    urlEl.textContent = "GET " + url();
  }

  function pill(text, tone) {
    var el = document.createElement("span");
    el.className = "page-pill" + (tone ? " is-" + tone : "");
    el.textContent = text;
    return el;
  }

  function render(response, body, ms) {
    var tone = response.status < 300 ? "pass" : response.status === 429 ? "warn" : "fail";
    statusEl.textContent = "";
    statusEl.appendChild(pill("HTTP " + response.status, tone));
    statusEl.appendChild(document.createTextNode(ms + " ms"));
    headersEl.textContent = "";
    SHOWN.forEach(function (name) {
      var value = response.headers.get(name);
      if (value === null) return;
      var li = document.createElement("li");
      var b = document.createElement("b");
      b.textContent = name + ": ";
      li.appendChild(b);
      li.appendChild(document.createTextNode(value));
      headersEl.appendChild(li);
    });
    output.textContent = typeof body === "string" ? body : JSON.stringify(body, null, 2);
    output.hidden = false;
  }

  form.addEventListener("submit", function (event) {
    event.preventDefault();
    if (needsAddress() && !/^0x[0-9a-fA-F]{40}$/.test(address.value.trim())) {
      statusEl.textContent = "";
      statusEl.appendChild(pill("Enter an address: 0x and 40 hex characters", "fail"));
      return;
    }
    run.disabled = true;
    statusEl.textContent = "Running…";
    var started = performance.now();
    fetch(url(), { headers: { accept: "application/json" }, cache: "no-store" }).then(function (response) {
      return response.text().then(function (text) {
        var body;
        try { body = JSON.parse(text); } catch (e) { body = text; }
        render(response, body, Math.round(performance.now() - started));
      });
    }).catch(function (error) {
      statusEl.textContent = "";
      statusEl.appendChild(pill("Request failed: " + error.message, "fail"));
    }).then(function () { run.disabled = false; });
  });

  endpoint.addEventListener("change", refresh);
  address.addEventListener("input", refresh);
  refresh();
})();
