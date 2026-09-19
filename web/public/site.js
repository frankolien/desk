/* The security carousel, ported from Recourse's SecurityCarousel without React.
   The first slide is in the HTML, so the section reads correctly before this runs
   and if it never does. */

(function () {
  "use strict";

  // A looping capture is decoration, so it stops when the viewer has asked for less
  // motion. The poster stays, which is the screen the video opens on anyway.
  var motion = window.matchMedia("(prefers-reduced-motion: reduce)");
  Array.prototype.forEach.call(document.querySelectorAll(".site-phone-video"), function (video) {
    function apply() {
      if (motion.matches) { video.removeAttribute("autoplay"); video.pause(); }
      else if (video.paused) { var play = video.play(); if (play) play.catch(function () {}); }
    }
    motion.addEventListener("change", apply);
    apply();
  });

  var root = document.querySelector("[data-carousel]");
  if (!root) return;

  var slides = [
    {
      title: "No server can trade for anyone.",
      text: "Including ours. The signing key exists only in the app’s memory, only while it is open and unlocked. Ours pushes notifications and reads public chain data — nothing it holds could move your money.",
    },
    {
      title: "Rounding goes against you.",
      text: "Every figure rounds in the direction that costs you rather than the one that flatters you, and the arithmetic lives in a module that cannot reach the network by construction.",
    },
    {
      title: "Unreadable is never empty.",
      text: "A position book that cannot be read is never treated as an empty one, because that would announce closes that never happened.",
    },
  ];

  var ROTATE_MS = 6000;
  var bars = Array.prototype.slice.call(root.querySelectorAll(".site-carousel-bar"));
  var visuals = Array.prototype.slice.call(document.querySelectorAll(".site-security-visual"));
  var panel = root.querySelector(".site-carousel-slide");
  var title = panel.querySelector("h2");
  var text = panel.querySelector("p");
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
  var index = 0;
  var timer = null;

  function render(next, moveFocus) {
    index = (next + slides.length) % slides.length;

    bars.forEach(function (bar, i) {
      var active = i === index;
      bar.classList.toggle("is-active", active);
      bar.setAttribute("aria-selected", active ? "true" : "false");
      bar.tabIndex = active ? 0 : -1;
      // Restarting the fill means replacing the node: an animation does not replay
      // just because the class came back.
      if (active) {
        var track = bar.querySelector(".site-carousel-track");
        var fill = track.querySelector(".site-carousel-fill");
        track.replaceChild(fill.cloneNode(false), fill);
      }
    });

    // The visual is the slide's, not decoration beside it: the bar, the words and
    // the picture move together or the three bars mean nothing.
    visuals.forEach(function (visual, i) {
      var show = i === index;
      if (show && visual.hidden) visual.style.animation = "none";
      visual.hidden = !show;
      if (show) { void visual.offsetWidth; visual.style.animation = ""; }
    });

    title.textContent = slides[index].title;
    text.textContent = slides[index].text;
    panel.setAttribute("aria-labelledby", "sec-tab-" + index);

    // Re-running the fade needs the same trick as the fill.
    [title, text].forEach(function (el) {
      el.style.animation = "none";
      void el.offsetWidth;
      el.style.animation = "";
    });

    if (moveFocus) bars[index].focus();
  }

  function schedule() {
    if (timer) window.clearInterval(timer);
    if (reduced.matches) return;
    timer = window.setInterval(function () { render(index + 1, false); }, ROTATE_MS);
  }

  bars.forEach(function (bar, i) {
    bar.addEventListener("click", function () { render(i, false); schedule(); });
  });

  root.querySelector(".site-carousel-bars").addEventListener("keydown", function (event) {
    var next;
    if (event.key === "ArrowRight") next = index + 1;
    else if (event.key === "ArrowLeft") next = index - 1;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = slides.length - 1;
    else return;
    event.preventDefault();
    render(next, true);
    schedule();
  });

  reduced.addEventListener("change", schedule);
  render(0, false);
  schedule();
})();
