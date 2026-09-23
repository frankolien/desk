/* Desk — trydesk.trade
   Everything here is progressive: the page reads correctly with none of it. The live
   figures come from the same API the app reads, and every moving part stops under
   prefers-reduced-motion. */

(function () {
  "use strict";

  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
  var $ = function (sel, root) { return (root || document).querySelector(sel); };
  var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };

  function restart(el) { el.style.animation = "none"; void el.offsetWidth; el.style.animation = ""; }
  function play(video) {
    if (!video || reduced.matches) return;
    var p = video.play();
    if (p && p.catch) p.catch(function () {});
  }

  /* ── Reveal ── */
  var revealed = $$(".site-reveal");
  if ("IntersectionObserver" in window && revealed.length) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); } });
    }, { threshold: 0, rootMargin: "0px 0px -60px 0px" });
    revealed.forEach(function (el) { io.observe(el); });
  } else {
    revealed.forEach(function (el) { el.classList.add("in"); });
  }

  /* ── Recordings that play only while on screen ── */
  var scrollVideos = $$("[data-scroll-video]");
  if ("IntersectionObserver" in window && scrollVideos.length) {
    var vio = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) play(e.target); else e.target.pause();
      });
    }, { threshold: 0.35 });
    scrollVideos.forEach(function (v) { vio.observe(v); });
  }
  reduced.addEventListener("change", function () {
    $$("video").forEach(function (v) { if (reduced.matches) v.pause(); });
  });

  /* ── Hero: three statements, three recordings, one card that changes colour ──
     Scrolling inside the hero steps the slides — down to the next, up to the one
     before — and only past the last one does the page scroll. A wheel or a swipe
     is claimed only while the page is at the very top, so there is no way to be
     stuck: scroll up from anywhere lower and the page moves as usual. */
  var heroEl = $(".site-hero");
  var hero = $("[data-hero]");
  if (hero && heroEl) {
    var ROTATE = 7000;
    var slides = $$(".site-hero-slide", hero);
    var phones = $$("[data-hero-phone]", hero);
    var nums = $$(".site-hero-num", heroEl);
    var hi = 0, ht = null, lock = 0;

    function heroShow(next, focus) {
      hi = Math.max(0, Math.min(slides.length - 1, next));
      heroEl.setAttribute("data-tone", slides[hi].getAttribute("data-tone"));
      slides.forEach(function (s, i) {
        var on = i === hi;
        s.hidden = !on;
        s.classList.toggle("is-active", on);
        if (on) restart(s);
      });
      phones.forEach(function (p, i) {
        var on = i === hi;
        p.classList.toggle("is-active", on);
        var v = $("video", p);
        if (on) { if (v) { v.currentTime = 0; play(v); } } else if (v) { v.pause(); }
      });
      nums.forEach(function (n, i) {
        var on = i === hi;
        n.classList.toggle("is-active", on);
        n.setAttribute("aria-selected", on ? "true" : "false");
        n.tabIndex = on ? 0 : -1;
      });
      if (focus) nums[hi].focus();
    }
    function heroSchedule() {
      if (ht) clearInterval(ht);
      if (reduced.matches) return;
      ht = setInterval(function () { heroShow((hi + 1) % slides.length, false); }, ROTATE);
    }
    function step(dir) {
      var now = Date.now();
      if (now - lock < 900) return true;
      var next = hi + dir;
      if (next < 0 || next >= slides.length) return false;
      lock = now;
      heroShow(next, false);
      heroSchedule();
      return true;
    }
    function atTop() { return window.scrollY < 4 && !reduced.matches; }

    window.addEventListener("wheel", function (ev) {
      if (!atTop() || Math.abs(ev.deltaY) < 8) return;
      var dir = ev.deltaY > 0 ? 1 : -1;
      if (dir > 0 && hi === slides.length - 1) return;
      if (dir < 0 && hi === 0) return;
      ev.preventDefault();
      step(dir);
    }, { passive: false });

    var touchY = null;
    window.addEventListener("touchstart", function (ev) { touchY = ev.touches[0].clientY; }, { passive: true });
    window.addEventListener("touchmove", function (ev) {
      if (touchY == null || !atTop()) return;
      var dy = touchY - ev.touches[0].clientY;
      if (Math.abs(dy) < 30) return;
      var dir = dy > 0 ? 1 : -1;
      if ((dir > 0 && hi === slides.length - 1) || (dir < 0 && hi === 0)) { touchY = null; return; }
      ev.preventDefault();
      touchY = null;
      step(dir);
    }, { passive: false });

    nums.forEach(function (n, i) { n.addEventListener("click", function () { heroShow(i, false); heroSchedule(); }); });
    $(".site-hero-rail", heroEl).addEventListener("keydown", function (ev) {
      var n;
      if (ev.key === "ArrowDown" || ev.key === "ArrowRight") n = hi + 1;
      else if (ev.key === "ArrowUp" || ev.key === "ArrowLeft") n = hi - 1;
      else return;
      ev.preventDefault(); heroShow((n + slides.length) % slides.length, true); heroSchedule();
    });
    document.addEventListener("visibilitychange", function () {
      if (document.hidden) { if (ht) clearInterval(ht); } else heroSchedule();
    });
    reduced.addEventListener("change", heroSchedule);
    heroShow(0, false);
    heroSchedule();
  }

  /* ── Security carousel ── */
  var car = $("[data-carousel]");
  if (car) {
    var cslides = [
      { title: "No server can trade for anyone.", text: "Including ours. The signing key exists only in the app’s memory, only while it is open and unlocked. Ours pushes notifications and reads public chain data — nothing it holds could move your money." },
      { title: "Rounding goes against you.", text: "Every figure rounds in the direction that costs you rather than the one that flatters you, and the arithmetic lives in a module that cannot reach the network by construction." },
      { title: "Unreadable is never empty.", text: "A position book that cannot be read is never treated as an empty one, because that would announce closes that never happened." }
    ];
    var cbars = $$(".site-carousel-bar", car);
    var visuals = $$(".site-security-visual", car);
    var panel = $(".site-carousel-slide", car);
    var ctitle = $("h2", panel), ctext = $("p", panel);
    var ci = 0, ct = null;
    function carShow(next, focus) {
      ci = (next + cslides.length) % cslides.length;
      cbars.forEach(function (b, i) {
        var on = i === ci;
        b.classList.toggle("is-active", on);
        b.setAttribute("aria-selected", on ? "true" : "false");
        b.tabIndex = on ? 0 : -1;
        if (on) restart($(".site-carousel-fill", b));
      });
      visuals.forEach(function (v, i) { var on = i === ci; v.hidden = !on; if (on) restart(v); });
      ctitle.textContent = cslides[ci].title;
      ctext.textContent = cslides[ci].text;
      panel.setAttribute("aria-labelledby", "sec-tab-" + ci);
      restart(ctitle); restart(ctext);
      if (focus) cbars[ci].focus();
    }
    function carSchedule() {
      if (ct) clearInterval(ct);
      if (reduced.matches) return;
      ct = setInterval(function () { carShow(ci + 1, false); }, 6000);
    }
    cbars.forEach(function (b, i) { b.addEventListener("click", function () { carShow(i, false); carSchedule(); }); });
    $(".site-carousel-bars", car).addEventListener("keydown", function (ev) {
      var n;
      if (ev.key === "ArrowRight") n = ci + 1; else if (ev.key === "ArrowLeft") n = ci - 1; else return;
      ev.preventDefault(); carShow(n, true); carSchedule();
    });
    reduced.addEventListener("change", carSchedule);
    carShow(0, false);
    carSchedule();
  }

  /* ── Slider: drag with the mouse, snap with the wheel, arrows to page ── */
  var slider = $("[data-slider]");
  if (slider) {
    var down = false, startX = 0, startLeft = 0, moved = false;
    slider.addEventListener("pointerdown", function (e) {
      if (e.pointerType !== "mouse") return;
      down = true; moved = false; startX = e.clientX; startLeft = slider.scrollLeft;
      slider.setPointerCapture(e.pointerId);
    });
    slider.addEventListener("pointermove", function (e) {
      if (!down) return;
      var dx = e.clientX - startX;
      if (Math.abs(dx) > 4) { moved = true; slider.classList.add("is-dragging"); }
      slider.scrollLeft = startLeft - dx;
    });
    function up() { if (!down) return; down = false; slider.classList.remove("is-dragging"); }
    slider.addEventListener("pointerup", up);
    slider.addEventListener("pointercancel", up);
    slider.addEventListener("click", function (e) { if (moved) { e.preventDefault(); moved = false; } }, true);
    $$("[data-slide]").forEach(function (b) {
      b.addEventListener("click", function () {
        var card = $(".site-trader", slider);
        var step = card ? card.getBoundingClientRect().width + 16 : 316;
        slider.scrollBy({ left: step * 2 * Number(b.getAttribute("data-slide")), behavior: reduced.matches ? "auto" : "smooth" });
      });
    });
  }

  /* ── Live figures ── */
  function money(n) {
    if (n >= 1e9) return "$" + (n / 1e9).toFixed(2) + "B";
    if (n >= 1e6) return "$" + (n / 1e6).toFixed(2) + "M";
    if (n >= 1e3) return "$" + (n / 1e3).toFixed(1) + "K";
    return "$" + n.toFixed(0);
  }
  function commas(n) { return String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ","); }
  function shortAddr(a) { return a ? a.slice(0, 6) + "…" + a.slice(-4) : "—"; }
  function hue(a) { var h = 0; for (var i = 2; i < a.length; i++) h = (h * 31 + a.charCodeAt(i)) >>> 0; return h % 360; }

  // Counts up on first sight, then holds. Truncates rather than rounds on the way, so
  // the figure never shows a number higher than the one it lands on.
  function countUp(el, target, format) {
    if (reduced.matches || !("requestAnimationFrame" in window)) { el.textContent = format(target); return; }
    var t0 = null, D = 1300, done = false;
    function land() { if (!done) { done = true; el.textContent = format(target); } }
    function frame(t) {
      if (done) return;
      if (!t0) t0 = t;
      var k = Math.min(1, (t - t0) / D);
      var e = 1 - Math.pow(1 - k, 3);
      el.textContent = format(Math.floor(target * e));
      if (k < 1) requestAnimationFrame(frame); else land();
    }
    requestAnimationFrame(frame);
    // A background tab or a throttled frame loop must still land on the figure.
    setTimeout(land, D + 400);
  }

  function renderTicker(markets) {
    var track = $(".site-ticker-track");
    if (!track || !markets.length) return;
    var items = markets.map(function (m) {
      var share = m.longShareBps == null ? null : Math.round(m.longShareBps / 100);
      var lean = share == null ? "" : (share >= 50
        ? '<span class="is-long">' + share + "% long</span>"
        : '<span class="is-short">' + (100 - share) + "% short</span>");
      var oi = Number(m.longValue) + Number(m.shortValue);
      return '<span class="site-ticker-item"><span class="site-dot"></span><b>' + m.market + "</b>" +
        '<span class="site-muted">' + m.traders + " traders</span>" + lean +
        '<span class="site-muted">' + money(oi) + " open</span></span>";
    }).join("");
    track.innerHTML = items + items;
    // Speed follows length: roughly 90 px a second, whatever the market count.
    $(".site-ticker").style.setProperty("--duration", Math.max(30, Math.round(track.scrollWidth / 2 / 90)) + "s");
  }

  function renderStats(markets) {
    var positions = 0, oi = 0;
    markets.forEach(function (m) { positions += m.traders; oi += Number(m.longValue) + Number(m.shortValue); });
    var targets = { positions: positions, oi: oi, markets: markets.length };
    var formats = { positions: commas, oi: money, markets: commas };
    var cells = $$("[data-count]");
    var note = $("[data-stats-note]");
    if (note) note.textContent = "Summed across " + markets.length + " markets, read live from Perpl’s exchange contract on Monad.";
    function fire(el) { var k = el.getAttribute("data-count"); countUp(el, targets[k], formats[k]); }
    if ("IntersectionObserver" in window) {
      var sio = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) { if (e.isIntersecting) { fire(e.target); sio.unobserve(e.target); } });
      }, { threshold: 0.4 });
      cells.forEach(function (el) { sio.observe(el); });
    } else cells.forEach(fire);
  }

  function renderTraders(traders) {
    var s = $("[data-slider]");
    if (!s) return;
    if (!traders.length) { s.innerHTML = '<div class="site-trader is-empty">The leaderboard is empty right now.</div>'; return; }
    s.innerHTML = traders.slice(0, 12).map(function (t, i) {
      var pnl = Number(t.pnl);
      var pos = (t.positions || []).slice(0, 3).map(function (p) {
        return '<span class="site-chip"><span class="site-side is-' + p.side + '"></span>' +
          (p.side === "long" ? "Long" : "Short") + " " + p.market + " " + Number(p.leverage).toFixed(p.leverage % 1 ? 1 : 0) + "×</span>";
      }).join("");
      var h = hue(t.address || t.accountId || "");
      return '<article class="site-trader">' +
        '<div class="site-trader-head"><span class="site-avatar" style="--a:' + (h * 2 % 360) + 'deg;--c1:hsl(' + h + ' 70% 55%);--c2:hsl(' + ((h + 60) % 360) + ' 80% 45%)"></span>' +
        '<span class="site-trader-addr">' + shortAddr(t.address) + "</span>" +
        '<span class="site-trader-rank">#' + (i + 1) + "</span></div>" +
        '<div class="site-trader-pnl ' + (pnl < 0 ? "is-down" : "is-up") + '">' + (pnl < 0 ? "−" : "+") + "$" + commas(Math.abs(pnl)) + "</div>" +
        '<p class="site-trader-l">unrealised, across ' + (t.positions || []).length + (t.positions && t.positions.length === 1 ? " position" : " positions") + "</p>" +
        '<div class="site-trader-pos">' + pos + "</div></article>";
    }).join("");
  }

  function fetchJSON(url) {
    return fetch(url, { headers: { accept: "application/json" } }).then(function (r) {
      if (!r.ok) throw new Error(String(r.status));
      return r.json();
    });
  }

  fetchJSON("/api/traders?view=crowd").then(function (d) {
    var markets = (d && d.markets) || [];
    renderTicker(markets);
    renderStats(markets);
  }).catch(function () {
    var note = $("[data-stats-note]");
    if (note) note.textContent = "Perpl isn’t answering right now. The figures return when it does.";
  });

  fetchJSON("/api/traders").then(function (d) {
    renderTraders((d && d.traders) || []);
  }).catch(function () {
    renderTraders([]);
  });

  /* ── Waitlist ── */
  var waitlist = $("#waitlist");
  if (waitlist) {
    var note = $("[data-waitlist-note]");
    var input = $("input", waitlist);
    var submit = $("button", waitlist);
    waitlist.addEventListener("submit", function (e) {
      e.preventDefault();
      var email = (input.value || "").trim();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) { note.textContent = "That doesn\u2019t look like an email address."; input.focus(); return; }
      submit.disabled = true;
      note.textContent = "";
      fetch("/api/alerts", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: "waitlist", email: email }) })
        .then(function (r) { return r.json().then(function (b) { return { ok: r.ok, body: b }; }); })
        .then(function (r) {
          if (!r.ok) throw new Error(r.body && r.body.error);
          waitlist.hidden = true;
          note.classList.add("is-done");
          note.textContent = r.body.already ? "You\u2019re already on the list." : "You\u2019re on the list. The invite comes to " + email + ".";
        })
        .catch(function (err) {
          submit.disabled = false;
          note.textContent = (err && err.message) || "That didn\u2019t go through. Try again.";
        });
    });
  }
})();
