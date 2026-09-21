(function () {
  "use strict";

  var overall = document.querySelector("[data-overall]");
  var meta = document.querySelector("[data-meta]");
  var rows = document.querySelectorAll("[data-check]");
  if (!overall || !rows.length) return;

  var WORDS = { pass: "Operational", warn: "Degraded", fail: "Down", unknown: "Unknown" };

  function pill(text, tone) {
    var el = document.createElement("span");
    el.className = "page-pill is-" + tone;
    el.textContent = text;
    return el;
  }

  function age(seconds) {
    if (seconds == null) return "never";
    if (seconds < 90) return seconds + " s ago";
    if (seconds < 5400) return Math.round(seconds / 60) + " min ago";
    return (seconds / 3600).toFixed(1) + " h ago";
  }

  function value(check) {
    if (check.observedUnit === "s") return age(check.observedValue);
    var text = check.observedValue == null ? "—" : check.observedValue + " ms";
    if (check.block) text += " · block " + check.block.toLocaleString("en-US");
    return text;
  }

  function render(report, httpStatus) {
    var status = report && report.status ? report.status : "fail";
    overall.textContent = "";
    overall.appendChild(pill(WORDS[status] || status, status));
    var parts = ["Updated " + new Date().toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", second: "2-digit" })];
    if (report && report.releaseId) parts.push("release " + report.releaseId);
    if (httpStatus) parts.push("HTTP " + httpStatus);
    meta.textContent = parts.join(" · ");
    Array.prototype.forEach.call(rows, function (row) {
      var entry = report && report.checks && report.checks[row.getAttribute("data-check")];
      var check = entry && entry[0];
      var badge = row.querySelector("[data-badge]");
      var tone = check ? check.status : "unknown";
      badge.className = "page-pill is-" + tone;
      badge.textContent = tone;
      row.querySelector("[data-value]").textContent = check ? value(check) : "—";
    });
  }

  function poll() {
    fetch("/api/v1/health", { headers: { accept: "application/health+json, application/json" }, cache: "no-store" }).then(function (response) {
      return response.json().then(function (body) { render(body, response.status); });
    }).catch(function () {
      overall.textContent = "";
      overall.appendChild(pill("Unreachable", "fail"));
      meta.textContent = "The health endpoint did not answer. Trying again in 30 seconds.";
    });
  }

  poll();
  setInterval(poll, 30000);
})();
