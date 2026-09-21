(function () {
  "use strict";

  const FALLBACK = "https://web-lovat-nine-49.vercel.app";
  const PUBLIC = "https://trydesk.trade";
  const OWN = /^(trydesk\.trade|.*\.vercel\.app|localhost|127\.0\.0\.1)$/;
  const BASE = /^https?:$/.test(location.protocol) && OWN.test(location.hostname) ? "" : FALLBACK;
  const SHOWN = ["X-RateLimit-Limit", "X-RateLimit-Remaining", "X-RateLimit-Reset", "Retry-After", "Content-Type", "Cache-Control"];
  const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
  const OLD_ANCHORS = {
    about: "introduction", endpoints: "map", limits: "access", try: "quickstart", "ep-index": "map", "ep-top": "traders-top",
    "ep-history": "traders-history", "ep-identity": "identity", "ep-wallets": "wallets", "ep-signals": "signals", "ep-health": "health", "ep-stats": "stats",
  };

  const $ = (sel, root) => (root || document).querySelector(sel);
  const $$ = (sel, root) => Array.prototype.slice.call((root || document).querySelectorAll(sel));

  function el(tag, attrs, children) {
    const node = document.createElement(tag);
    Object.keys(attrs || {}).forEach((key) => {
      if (key === "class") node.className = attrs[key];
      else if (key === "text") node.textContent = attrs[key];
      else node.setAttribute(key, attrs[key]);
    });
    (children || []).forEach((child) => node.appendChild(typeof child === "string" ? document.createTextNode(child) : child));
    return node;
  }

  /* JSON colouring: keys, strings, numbers, booleans and null become spans. */

  const TOKEN = /("(?:[^"\\]|\\.)*")(\s*:)?|\b(?:true|false)\b|\bnull\b|-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b/g;

  function colorJson(text) {
    const frag = document.createDocumentFragment();
    let last = 0;
    text.replace(TOKEN, (match, str, colon, offset) => {
      if (offset > last) frag.appendChild(document.createTextNode(text.slice(last, offset)));
      let cls;
      if (str) cls = colon ? "j-k" : "j-s";
      else if (match === "null") cls = "j-z";
      else if (match === "true" || match === "false") cls = "j-b";
      else cls = "j-n";
      if (str && colon) {
        frag.appendChild(el("span", { class: cls, text: str }));
        frag.appendChild(document.createTextNode(colon));
      } else {
        frag.appendChild(el("span", { class: cls, text: match }));
      }
      last = offset + match.length;
      return match;
    });
    if (last < text.length) frag.appendChild(document.createTextNode(text.slice(last)));
    return frag;
  }

  function paint(code, text) {
    code.textContent = "";
    code.appendChild(colorJson(text));
  }

  $$("pre code.lang-json").forEach((code) => {
    code.dataset.raw = code.textContent;
    paint(code, code.textContent);
  });

  /* Tabs: buttons with role=tab inside a role=tablist; panels found by aria-controls. */

  function select(tab) {
    const list = tab.parentNode;
    $$("[role=tab]", list).forEach((other) => {
      const on = other === tab;
      other.setAttribute("aria-selected", on ? "true" : "false");
      other.tabIndex = on ? 0 : -1;
      const panel = document.getElementById(other.getAttribute("aria-controls"));
      if (panel) panel.hidden = !on;
    });
    list.dispatchEvent(new CustomEvent("tabchange", { bubbles: true, detail: { tab } }));
  }

  function wireTabs(list) {
    list.addEventListener("click", (event) => {
      const tab = event.target.closest("[role=tab]");
      if (tab && list.contains(tab)) select(tab);
    });
    list.addEventListener("keydown", (event) => {
      const tabs = $$("[role=tab]", list);
      const index = tabs.indexOf(document.activeElement);
      if (index < 0) return;
      const next = { ArrowRight: index + 1, ArrowLeft: index - 1, Home: 0, End: tabs.length - 1 }[event.key];
      if (next === undefined) return;
      event.preventDefault();
      const tab = tabs[(next + tabs.length) % tabs.length];
      tab.focus();
      select(tab);
    });
  }

  $$("[data-tabs] .docs-tablist").forEach(wireTabs);

  /* Copy buttons. */

  function copyText(text, button) {
    const done = () => {
      const label = button.textContent;
      button.textContent = "Copied";
      button.classList.add("is-done");
      setTimeout(() => { button.textContent = label; button.classList.remove("is-done"); }, 1400);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, () => fallbackCopy(text, done));
    } else {
      fallbackCopy(text, done);
    }
  }

  function fallbackCopy(text, done) {
    const area = el("textarea", { style: "position:fixed;opacity:0", "aria-hidden": "true" });
    area.value = text;
    document.body.appendChild(area);
    area.select();
    try { document.execCommand("copy"); done(); } catch (e) { /* nothing to do */ }
    area.remove();
  }

  /* Code samples, generated from the example URL so all four agree with it. */

  function samples(url, envelope, accept) {
    const parsed = new URL(url);
    const params = Array.from(parsed.searchParams.entries());
    const bare = parsed.origin + parsed.pathname;
    const pyParams = params.length ? `    params={${params.map(([k, v]) => `"${k}": "${v}"`).join(", ")}},\n` : "";
    return {
      cURL: `curl "${url}" \\\n  -H "Accept: ${accept}"`,
      JavaScript: envelope
        ? `const res = await fetch("${url}", {\n  headers: { Accept: "${accept}" },\n});\nconst body = await res.json();\nif (!res.ok) throw new Error(\`\${body.code}: \${body.detail}\`);\n\nconst { data, meta } = body;\nconsole.log(meta.asOf, data);`
        : `const res = await fetch("${url}", {\n  headers: { Accept: "${accept}" },\n});\nconst report = await res.json();\n// 200 on pass or warn, 503 on fail; the body is the same shape either way.\nconsole.log(res.status, report.status, report.checks);`,
      Swift: envelope
        ? `import Foundation\n\n// Inside an async context.\nlet url = URL(string: "${url}")!\nvar request = URLRequest(url: url)\nrequest.setValue("${accept}", forHTTPHeaderField: "Accept")\n\nlet (body, response) = try await URLSession.shared.data(for: request)\nlet status = (response as! HTTPURLResponse).statusCode\nlet json = try JSONSerialization.jsonObject(with: body) as! [String: Any]\nguard status == 200, let data = json["data"] else {\n    throw NSError(domain: "DeskAPI", code: status, userInfo: json)\n}\nprint(data)`
        : `import Foundation\n\n// Inside an async context.\nlet url = URL(string: "${url}")!\nvar request = URLRequest(url: url)\nrequest.setValue("${accept}", forHTTPHeaderField: "Accept")\n\nlet (body, response) = try await URLSession.shared.data(for: request)\nlet status = (response as! HTTPURLResponse).statusCode\nlet report = try JSONSerialization.jsonObject(with: body) as! [String: Any]\nprint(status, report["status"] ?? "unknown")`,
      Python: envelope
        ? `import requests\n\nr = requests.get(\n    "${bare}",\n${pyParams}    headers={"Accept": "${accept}"},\n    timeout=30,\n)\nbody = r.json()\nif not r.ok:\n    raise RuntimeError(f"{body['code']}: {body['detail']}")\n\nprint(body["meta"]["asOf"], body["data"])`
        : `import requests\n\nr = requests.get(\n    "${bare}",\n    headers={"Accept": "${accept}"},\n    timeout=30,\n)\nreport = r.json()\nprint(r.status_code, report["status"], report["checks"])`,
    };
  }

  $$("[data-code]").forEach((panel, index) => {
    const code = samples(panel.dataset.url, panel.dataset.envelope !== "false", panel.dataset.accept || "application/json");
    const pre = $("pre", panel);
    const codeEl = $("code", pre);
    const list = el("div", { class: "docs-tablist", role: "tablist", "aria-label": "Language" });
    const langs = Object.keys(code);
    langs.forEach((lang, i) => {
      const id = `code-${index}-${i}`;
      pre.id = pre.id || `code-pre-${index}`;
      list.appendChild(el("button", { type: "button", role: "tab", class: "docs-tab", id, "aria-selected": i === 0 ? "true" : "false", tabindex: i === 0 ? "0" : "-1", "aria-controls": pre.id, "data-lang": lang, text: lang }));
    });
    const copy = el("button", { type: "button", class: "docs-copy", text: "Copy" });
    list.appendChild(el("span", { class: "docs-tablist-end" }, [copy]));
    let current = langs[0];
    const show = (lang) => { current = lang; codeEl.textContent = code[lang]; };
    list.addEventListener("tabchange", (event) => show(event.detail.tab.dataset.lang));
    wireTabs(list);
    copy.addEventListener("click", () => copyText(code[current], copy));
    panel.insertBefore(list, pre);
    $(".docs-code-head", panel).remove();
    show(current);
  });

  /* Try it: one inline panel per endpoint, built from the parameter rows. */

  function pill(text, tone) {
    return el("span", { class: "page-pill" + (tone ? " is-" + tone : ""), text });
  }

  function buildTry(section) {
    const route = section.dataset.route;
    const accept = section.dataset.accept || "application/json";
    const panel = $("[data-try-panel]", section);
    const params = $$(".docs-param[data-param]", section);
    const form = el("form", { class: "docs-try-form", novalidate: "" });
    const fields = [];

    if (params.length) {
      const grid = el("div", { class: "docs-try-grid" });
      params.forEach((row) => {
        const d = row.dataset;
        let input;
        if (d.enum) {
          input = el("select", { class: "page-select", name: d.param });
          d.enum.split(",").forEach((value) => {
            const option = el("option", { value, text: value });
            if (value === d.example) option.selected = true;
            input.appendChild(option);
          });
        } else {
          input = el("input", { class: "page-input", name: d.param, type: d.type === "integer" ? "number" : "text", value: d.example, autocomplete: "off", spellcheck: "false" });
          if (d.min) input.min = d.min;
          if (d.max) input.max = d.max;
          if (d.type === "address") input.placeholder = "0x…";
        }
        const label = el("label", { class: "page-field" + (d.type === "address" ? " is-wide" : "") }, [
          el("span", { text: `${d.param} · ${d.in}` }), input,
        ]);
        grid.appendChild(label);
        fields.push({ input, where: d.in, name: d.param, type: d.type });
      });
      form.appendChild(grid);
    }

    const run = el("button", { class: "site-btn site-btn-ink", type: "submit", text: "Run" });
    const copyCurl = el("button", { class: "site-btn site-btn-ghost", type: "button", text: "Copy as cURL" });
    const urlEl = el("div", { class: "page-try-url", "aria-live": "polite" });
    const statusEl = el("div", { class: "page-try-status", "aria-live": "polite" });
    const headersEl = el("ul", { class: "page-headers" });
    const output = el("pre", { class: "page-output", hidden: "" });
    const outCode = el("code");
    output.appendChild(outCode);
    form.appendChild(el("div", { class: "docs-try-actions" }, [run, copyCurl]));
    form.appendChild(urlEl);
    form.appendChild(statusEl);
    form.appendChild(headersEl);
    form.appendChild(output);
    form.appendChild(el("p", { class: "docs-try-help", text: `Runs from your browser against ${BASE || location.origin} and counts against your own rate limit.` }));
    panel.appendChild(form);

    function path() {
      let out = route;
      const query = [];
      fields.forEach((field) => {
        const value = field.input.value.trim();
        if (field.where === "path") out = out.replace(`{${field.name}}`, encodeURIComponent(value));
        else if (value) query.push(`${encodeURIComponent(field.name)}=${encodeURIComponent(value)}`);
      });
      return out + (query.length ? "?" + query.join("&") : "");
    }
    function refresh() { urlEl.textContent = "GET " + path(); }
    function invalid() {
      const bad = fields.find((field) => field.type === "address" && !ADDRESS.test(field.input.value.trim()));
      if (bad) { bad.input.focus(); return "Enter an address: 0x and 40 hex characters"; }
      return null;
    }

    form.addEventListener("input", refresh);
    form.addEventListener("change", refresh);
    copyCurl.addEventListener("click", () => copyText(`curl "${PUBLIC}${path()}" -H "Accept: ${accept}"`, copyCurl));
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      const problem = invalid();
      statusEl.textContent = "";
      headersEl.textContent = "";
      if (problem) { statusEl.appendChild(pill(problem, "fail")); return; }
      run.disabled = true;
      statusEl.textContent = "Running…";
      const started = performance.now();
      fetch(BASE + path(), { headers: { accept }, cache: "no-store" }).then((response) => response.text().then((text) => {
        const ms = Math.round(performance.now() - started);
        const tone = response.status < 300 ? "pass" : response.status === 429 ? "warn" : "fail";
        statusEl.textContent = "";
        statusEl.appendChild(pill("HTTP " + response.status, tone));
        statusEl.appendChild(document.createTextNode(ms + " ms"));
        SHOWN.forEach((name) => {
          const value = response.headers.get(name);
          if (value === null) return;
          headersEl.appendChild(el("li", {}, [el("b", { text: name + ": " }), value]));
        });
        let pretty = text;
        try { pretty = JSON.stringify(JSON.parse(text), null, 2); } catch (e) { /* shown raw */ }
        paint(outCode, pretty);
        output.hidden = false;
      })).catch((error) => {
        statusEl.textContent = "";
        statusEl.appendChild(pill("Request failed: " + error.message, "fail"));
      }).then(() => { run.disabled = false; });
    });
    refresh();
    return form;
  }

  $$("[data-endpoint]").forEach((section) => {
    const toggle = $("[data-try-toggle]", section);
    const panel = $("[data-try-panel]", section);
    if (!toggle || !panel) return;
    toggle.addEventListener("click", () => {
      const open = toggle.getAttribute("aria-expanded") !== "true";
      if (open && !panel.firstChild) buildTry(section);
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
      panel.hidden = !open;
      if (open) { const first = $("input, select, button", panel); if (first) first.focus(); }
    });
  });

  /* Sidebar: search, active section, status pill. */

  const search = $("[data-search]");
  const nav = $("[data-nav]");
  if (search && nav) {
    const isMac = /Mac|iPhone|iPad/.test(navigator.platform);
    const key = $("[data-search-key]");
    if (key) key.textContent = isMac ? "⌘K" : "Ctrl K";
    const links = $$("a[href^='#']", nav).map((a) => ({ a, li: a.parentNode, text: (a.textContent + " " + (a.dataset.keywords || "")).toLowerCase() }));
    const groups = $$("[data-group]", nav);
    const empty = $("[data-nav-empty]", nav);
    function filter() {
      const q = search.value.trim().toLowerCase();
      let shown = 0;
      links.forEach((link) => { const on = !q || link.text.indexOf(q) >= 0; link.li.hidden = !on; if (on) shown += 1; });
      groups.forEach((group) => { group.hidden = $$("li", group).every((li) => li.hidden); });
      if (empty) empty.hidden = shown > 0;
    }
    search.addEventListener("input", filter);
    search.addEventListener("keydown", (event) => {
      if (event.key === "Escape") { search.value = ""; filter(); search.blur(); }
      if (event.key === "Enter") {
        const first = links.find((link) => !link.li.hidden);
        if (first) { event.preventDefault(); first.a.click(); }
      }
    });
    document.addEventListener("keydown", (event) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") { event.preventDefault(); search.focus(); search.select(); }
    });

    const sections = $$(".docs-section[id]");
    let ticking = false;
    function highlight() {
      ticking = false;
      let current = sections[0];
      sections.forEach((section) => { if (section.getBoundingClientRect().top <= 140) current = section; });
      links.forEach((link) => link.a.classList.toggle("is-active", current && link.a.getAttribute("href") === "#" + current.id));
    }
    window.addEventListener("scroll", () => { if (!ticking) { ticking = true; requestAnimationFrame(highlight); } }, { passive: true });
    highlight();
  }

  const statusPill = $("[data-api-status]");
  if (statusPill) {
    const release = $("[data-api-release]");
    fetch(BASE + "/api/v1/health", { headers: { accept: "application/health+json, application/json" }, cache: "no-store" })
      .then((response) => response.json().then((report) => {
        const tone = ["pass", "warn", "fail"].indexOf(report.status) >= 0 ? report.status : "unknown";
        statusPill.className = "page-pill is-" + tone;
        statusPill.textContent = { pass: "All systems normal", warn: "Degraded", fail: "Outage" }[tone] || "Unknown";
        if (release) release.textContent = (report.releaseId ? "release " + report.releaseId + " · " : "") + "checked " + new Date(report.time || Date.now()).toUTCString().slice(17, 25) + " UTC";
      }))
      .catch(() => { statusPill.className = "page-pill is-unknown"; statusPill.textContent = "Status unavailable"; });
  }

  /* Response schema toggle: a typed skeleton derived from openapi.json for every 200 example. */

  function schemaSkeleton(doc) {
    const deref = (schema) => (schema && schema.$ref ? deref(schema.$ref.replace(/^#\//, "").split("/").reduce((node, key) => node && node[key], doc)) : schema);
    function render(schema, indent) {
      schema = deref(schema);
      if (!schema) return "any";
      if (schema.allOf) {
        schema = schema.allOf.map(deref).reduce((merged, part) => ({
          type: part.type || merged.type, properties: Object.assign({}, merged.properties, part.properties),
        }), { type: "object", properties: {} });
      }
      if (schema.const !== undefined) return JSON.stringify(schema.const);
      if (schema.enum) return schema.enum.map((v) => JSON.stringify(v)).join(" | ");
      const alts = schema.oneOf || schema.anyOf;
      if (alts) return alts.map((alt) => render(alt, indent)).join(" | ");
      const types = [].concat(schema.type || (schema.properties ? "object" : "any"));
      const pad = "  ".repeat(indent + 1);
      const out = types.map((type) => {
        if (type === "object") {
          const props = schema.properties || {};
          const keys = Object.keys(props);
          const extra = schema.additionalProperties && typeof schema.additionalProperties === "object" ? [`${pad}"<key>": ${render(schema.additionalProperties, indent + 1)}`] : [];
          if (!keys.length && !extra.length) return "object";
          return "{\n" + keys.map((key) => `${pad}"${key}": ${render(props[key], indent + 1)}`).concat(extra).join(",\n") + "\n" + "  ".repeat(indent) + "}";
        }
        if (type === "array") return "[\n" + pad + render(schema.items, indent + 1) + "\n" + "  ".repeat(indent) + "]";
        return type + (schema.format ? ` <${schema.format}>` : "");
      });
      return out.join(" | ");
    }
    return render;
  }

  fetch((BASE || "") + "/openapi.json", { headers: { accept: "application/json" } }).then((response) => response.json()).then((doc) => {
    const render = schemaSkeleton(doc);
    $$("[data-endpoint][data-openapi]").forEach((section) => {
      const op = doc.paths && doc.paths[section.dataset.openapi] && doc.paths[section.dataset.openapi].get;
      const ok = op && op.responses && op.responses["200"] && op.responses["200"].content;
      const media = ok && Object.keys(ok)[0];
      const schema = media && ok[media].schema;
      const code = $("[data-status='200'] code[data-example]", section);
      const end = $("[data-tablist-end]", section);
      if (!schema || !code || !end) return;
      const skeleton = render(schema, 0);
      const toggle = el("button", { type: "button", class: "docs-toggle", "aria-pressed": "false", text: "Schema" });
      toggle.addEventListener("click", () => {
        const on = toggle.getAttribute("aria-pressed") !== "true";
        toggle.setAttribute("aria-pressed", on ? "true" : "false");
        paint(code, on ? skeleton : code.dataset.raw);
      });
      end.appendChild(toggle);
      end.parentNode.addEventListener("tabchange", (event) => { toggle.hidden = event.detail.tab.getAttribute("aria-controls").indexOf("-200") < 0; });
    });
  }).catch(() => { /* the examples stand on their own */ });

  /* Old anchors from the previous page keep working. */

  function redirectHash() {
    const id = location.hash.slice(1);
    if (OLD_ANCHORS[id]) location.replace("#" + OLD_ANCHORS[id]);
  }
  window.addEventListener("hashchange", redirectHash);
  redirectHash();
})();
