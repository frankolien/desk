/* Two behaviours, no framework: the nav gains a hairline once the page moves, and
   sections arrive rather than appear. Both go quiet under prefers-reduced-motion. */

(function () {
  "use strict";

  var nav = document.getElementById("nav");
  if (nav) {
    var stick = function () { nav.classList.toggle("is-stuck", window.scrollY > 8); };
    stick();
    window.addEventListener("scroll", stick, { passive: true });
  }

  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
  var items = Array.prototype.slice.call(document.querySelectorAll(".reveal"));

  if (reduced.matches || !("IntersectionObserver" in window)) {
    items.forEach(function (el) { el.classList.add("in"); });
    return;
  }

  var seen = new WeakMap();

  var observer = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (!entry.isIntersecting) return;
      var el = entry.target;
      observer.unobserve(el);

      // Siblings that come into view together are staggered by their position in the
      // group, so a row of cards lands left to right instead of all at once.
      var parent = el.parentElement;
      var index = seen.get(parent) || 0;
      seen.set(parent, index + 1);
      el.style.transitionDelay = Math.min(index, 5) * 70 + "ms";
      el.classList.add("in");
    });
  }, { rootMargin: "0px 0px -60px 0px", threshold: 0 });

  items.forEach(function (el) { observer.observe(el); });
})();
