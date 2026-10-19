/* ==========================================================================
   南医助手 · NJMU-Helper  站点脚本
   纯原生，无依赖。所有动效在 prefers-reduced-motion 下自动降级。
   ========================================================================== */
(function () {
  "use strict";

  var CONFIG = {
    repo: "https://github.com/xiopeng32-ai/NJMU-Helper",
    owner: "xiopeng32-ai",
    download: "https://www.sydxky.cn/detail.php?id=1034",
    hap: "https://github.com/xiopeng32-ai/NJMU-Helper/releases/download/v2.0.3/NJMU-Helper-2.0.3.hap"
  };

  var doc = document;
  var root = doc.documentElement;
  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var fine = window.matchMedia && window.matchMedia("(pointer: fine)").matches;
  var $ = function (s, c) { return (c || doc).querySelector(s); };
  var $$ = function (s, c) { return Array.prototype.slice.call((c || doc).querySelectorAll(s)); };
  var clamp = function (v, a, b) { return v < a ? a : (v > b ? b : v); };

  /* ---------- 1. 仓库地址注入 ---------- */
  ["repoBtn", "repoBtn2", "repoBtn3"].forEach(function (id) {
    var el = doc.getElementById(id);
    if (el) el.href = CONFIG.repo;
  });
  var contrib = doc.getElementById("contribLink");
  if (contrib) contrib.href = CONFIG.repo + "/blob/main/CONTRIBUTING.md";
  var contrib2 = doc.getElementById("contribLink2");
  if (contrib2) contrib2.href = CONFIG.repo + "/blob/main/CONTRIBUTING.md";
  var clog = doc.getElementById("changelogLink");
  if (clog) clog.href = CONFIG.repo + "/blob/main/CHANGELOG.md";
  var ownerEl = doc.getElementById("repoOwner");
  if (ownerEl) ownerEl.textContent = CONFIG.owner;

  /* ---------- 2. 滚动驱动（进度条 / 导航 / 返回顶部 / 时间轴） ---------- */
  var nav = doc.getElementById("nav");
  var bar = doc.getElementById("progress");
  var toTop = doc.getElementById("toTop");
  var ring = toTop ? $(".ring circle", toTop) : null;
  var CIRC = 138.2;
  var lastY = window.pageYOffset || 0;
  var ticking = false;

  function scrollFrame() {
    var y = window.pageYOffset;
    var vh = window.innerHeight;
    var max = Math.max(1, root.scrollHeight - vh);
    var p = clamp(y / max, 0, 1);

    if (bar) bar.style.width = (p * 100).toFixed(2) + "%";

    if (nav) {
      if (y > 24) nav.classList.add("scrolled");
      else nav.classList.remove("scrolled");

      var links = doc.getElementById("navLinks");
      var menuOpen = links && links.classList.contains("open");
      if (!menuOpen && y > 380 && y > lastY + 4) nav.classList.add("is-hidden");
      else if (y < lastY - 4 || y < 380) nav.classList.remove("is-hidden");
    }

    if (toTop) {
      if (y > 620) toTop.classList.add("show");
      else toTop.classList.remove("show");
      if (ring) ring.style.strokeDashoffset = String(CIRC * (1 - p));
    }

    var tl = doc.getElementById("timeline");
    if (tl) {
      var r = tl.getBoundingClientRect();
      var prog = clamp((vh * 0.62 - r.top) / Math.max(1, r.height), 0, 1);
      tl.style.setProperty("--p", prog.toFixed(3));
    }

    spy(y, vh);
    lastY = y;
    ticking = false;
  }

  function onScroll() {
    if (!ticking) {
      ticking = true;
      window.requestAnimationFrame(scrollFrame);
    }
  }
  window.addEventListener("scroll", onScroll, { passive: true });
  window.addEventListener("resize", onScroll);

  /* ---------- 3. 滚动高亮（子导航 / 隐私目录） ---------- */
  var spyGroups = [];
  $$("[data-spy]").forEach(function (group) {
    var links = $$("a[href^='#']", group);
    var items = links.map(function (a) {
      var el = doc.getElementById(a.getAttribute("href").slice(1));
      return el ? { a: a, el: el } : null;
    }).filter(Boolean);
    if (items.length) spyGroups.push(items);
  });

  function spy(y, vh) {
    spyGroups.forEach(function (items) {
      var active = 0;
      var line = y + vh * 0.34;
      for (var i = 0; i < items.length; i++) {
        if (items[i].el.getBoundingClientRect().top + y <= line) active = i;
      }
      items.forEach(function (it, i) { it.a.classList.toggle("active", i === active); });
    });
  }

  /* ---------- 4. 指针柔光 ---------- */
  if (fine && !reduce) {
    var spot = doc.getElementById("spot");
    if (spot) {
      var tx = window.innerWidth / 2, ty = window.innerHeight / 2;
      var cx = tx, cy = ty, moved = false;

      doc.addEventListener("pointermove", function (e) {
        tx = e.clientX; ty = e.clientY;
        if (!moved) { cx = tx; cy = ty; moved = true; doc.body.classList.add("has-pointer"); }
      }, { passive: true });

      (function loop() {
        cx += (tx - cx) * 0.09;
        cy += (ty - cy) * 0.09;
        spot.style.transform = "translate3d(" + (cx - 280) + "px," + (cy - 280) + "px,0)";
        window.requestAnimationFrame(loop);
      })();
    }
  }

  /* ---------- 5. 进入视口动画 ---------- */
  var rvs = $$(".rv");
  if ("IntersectionObserver" in window && !reduce) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (en.isIntersecting) {
          en.target.classList.add("in");
          io.unobserve(en.target);
        }
      });
    }, { rootMargin: "0px 0px -6% 0px", threshold: 0.06 });
    rvs.forEach(function (el) { io.observe(el); });
  } else {
    rvs.forEach(function (el) { el.classList.add("in"); });
  }

  /* 终端逐行显现 */
  var terms = $$(".terminal");
  if (terms.length) {
    if ("IntersectionObserver" in window && !reduce) {
      var tio = new IntersectionObserver(function (entries) {
        entries.forEach(function (en) {
          if (en.isIntersecting) { en.target.classList.add("in"); tio.unobserve(en.target); }
        });
      }, { threshold: 0.25 });
      terms.forEach(function (t) { tio.observe(t); });
    } else {
      terms.forEach(function (t) { t.classList.add("in"); });
    }
  }

  /* ---------- 6. 数字滚动 ---------- */
  var counters = $$("[data-count]");
  if (counters.length) {
    var run = function (el) {
      var target = parseFloat(el.getAttribute("data-count"));
      var dec = parseInt(el.getAttribute("data-dec") || "0", 10);
      var suffix = el.getAttribute("data-suffix") || "";
      if (reduce) { el.textContent = target.toFixed(dec) + suffix; return; }
      var t0 = 0, dur = 1400;
      var step = function (t) {
        if (!t0) t0 = t;
        var k = clamp((t - t0) / dur, 0, 1);
        var e = 1 - Math.pow(1 - k, 3);
        el.textContent = (target * e).toFixed(dec) + suffix;
        if (k < 1) window.requestAnimationFrame(step);
      };
      window.requestAnimationFrame(step);
    };
    if ("IntersectionObserver" in window) {
      var cio = new IntersectionObserver(function (entries) {
        entries.forEach(function (en) {
          if (en.isIntersecting) { run(en.target); cio.unobserve(en.target); }
        });
      }, { threshold: 0.5 });
      counters.forEach(function (c) { cio.observe(c); });
    } else {
      counters.forEach(run);
    }
  }

  /* ---------- 7. 卡片 3D 倾斜 + 光斑 ---------- */
  if (fine && !reduce) {
    $$("[data-tilt]").forEach(function (el) {
      var max = parseFloat(el.getAttribute("data-tilt")) || 5;
      el.addEventListener("pointermove", function (e) {
        var r = el.getBoundingClientRect();
        var px = (e.clientX - r.left) / r.width - 0.5;
        var py = (e.clientY - r.top) / r.height - 0.5;
        el.style.setProperty("--rx", (-py * max).toFixed(2) + "deg");
        el.style.setProperty("--ry", (px * max).toFixed(2) + "deg");
        el.style.setProperty("--mx", (e.clientX - r.left) + "px");
        el.style.setProperty("--my", (e.clientY - r.top) + "px");
      }, { passive: true });
      el.addEventListener("pointerleave", function () {
        el.style.setProperty("--rx", "0deg");
        el.style.setProperty("--ry", "0deg");
      });
    });

    $$(".card").forEach(function (card) {
      card.addEventListener("pointermove", function (e) {
        var r = card.getBoundingClientRect();
        card.style.setProperty("--mx", (e.clientX - r.left) + "px");
        card.style.setProperty("--my", (e.clientY - r.top) + "px");
      }, { passive: true });
    });
  }

  /* ---------- 8. 交互预览（手机 / 平板） ---------- */
  var demo = doc.getElementById("demo");
  if (demo) {
    var modes = {
      phone: {
        pane: $('[data-pane="phone"]', demo),
        list: $('[data-list="phone"]', demo),
        img: $('[data-img="phone"]', demo)
      },
      tablet: {
        pane: $('[data-pane="tablet"]', demo),
        list: $('[data-list="tablet"]', demo),
        img: $('[data-img="tablet"]', demo)
      }
    };
    var capNum = doc.getElementById("dvNum");
    var capTitle = doc.getElementById("dvTitle");
    var capDesc = doc.getElementById("dvDesc");
    var current = "phone";

    var swapImg = function (imgEl, src, alt) {
      if (!imgEl || imgEl.getAttribute("src") === src) return;
      imgEl.style.opacity = "0.25";
      var pre = new Image();
      pre.onload = function () {
        imgEl.src = src;
        imgEl.alt = alt || "";
        imgEl.style.opacity = "1";
      };
      pre.onerror = function () { imgEl.style.opacity = "1"; };
      pre.src = src;
    };

    var select = function (btn, mode) {
      if (!btn) return;
      $$("button", modes[mode].list).forEach(function (b) { b.classList.toggle("is-on", b === btn); });
      swapImg(modes[mode].img, btn.getAttribute("data-src"), btn.getAttribute("data-alt"));
      if (capNum) capNum.textContent = btn.getAttribute("data-num") || "";
      if (capTitle) capTitle.textContent = btn.getAttribute("data-title") || "";
      if (capDesc) capDesc.textContent = btn.getAttribute("data-desc") || "";
    };

    var setMode = function (mode) {
      if (!modes[mode] || !modes[mode].list) return;
      current = mode;
      $$("[data-mode]", demo).forEach(function (b) {
        b.classList.toggle("is-on", b.getAttribute("data-mode") === mode);
      });
      Object.keys(modes).forEach(function (k) {
        if (modes[k].pane) modes[k].pane.classList.toggle("is-on", k === mode);
        if (modes[k].list) modes[k].list.classList.toggle("is-on", k === mode);
      });
      var btn = $("button.is-on", modes[mode].list) || $("button", modes[mode].list);
      select(btn, mode);
    };

    $$("[data-mode]", demo).forEach(function (b) {
      b.addEventListener("click", function () { setMode(b.getAttribute("data-mode")); });
    });

    Object.keys(modes).forEach(function (mode) {
      if (!modes[mode].list) return;
      $$("button", modes[mode].list).forEach(function (b) {
        b.addEventListener("click", function () {
          if (mode !== current) setMode(mode);
          select(b, mode);
        });
      });
    });

    /* 键盘左右切换当前模式的列表 */
    demo.addEventListener("keydown", function (e) {
      if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
      var list = modes[current].list;
      if (!list) return;
      var btns = $$("button", list);
      var idx = btns.findIndex(function (b) { return b.classList.contains("is-on"); });
      var next = idx + (e.key === "ArrowRight" ? 1 : -1);
      if (next < 0) next = btns.length - 1;
      if (next >= btns.length) next = 0;
      select(btns[next], current);
      btns[next].focus();
      e.preventDefault();
    });
  }

  /* ---------- 9. 图集灯箱 ---------- */
  var zooms = $$("[data-zoom]");
  if (zooms.length) {
    var lb = doc.createElement("div");
    lb.className = "lb";
    lb.setAttribute("role", "dialog");
    lb.setAttribute("aria-modal", "true");
    lb.setAttribute("aria-label", "截图预览");
    lb.innerHTML =
      '<span class="lb-count"></span>' +
      '<button class="lb-close" type="button" aria-label="关闭"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M18 6 6 18M6 6l12 12"/></svg></button>' +
      '<button class="lb-prev" type="button" aria-label="上一张"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m15 18-6-6 6-6"/></svg></button>' +
      '<button class="lb-next" type="button" aria-label="下一张"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m9 18 6-6-6-6"/></svg></button>' +
      '<figure><img alt=""><figcaption></figcaption></figure>';
    doc.body.appendChild(lb);

    var lbImg = $("img", lb);
    var lbCap = $("figcaption", lb);
    var lbCount = $(".lb-count", lb);
    var cur = 0;
    var lastFocus = null;

    var show = function (i) {
      cur = (i + zooms.length) % zooms.length;
      var el = zooms[cur];
      lbImg.src = el.getAttribute("data-zoom");
      lbImg.alt = el.getAttribute("data-cap") || "南医助手截图";
      lbCap.innerHTML = '<span>' + String(cur + 1).padStart(2, "0") + " / " + String(zooms.length).padStart(2, "0") + "</span>" +
        (el.getAttribute("data-cap") || "");
      lbCount.textContent = String(cur + 1).padStart(2, "0") + " / " + String(zooms.length).padStart(2, "0");
      /* 重放动画 */
      lbImg.style.animation = "none";
      void lbImg.offsetWidth;
      lbImg.style.animation = "";
    };

    var open = function (i) {
      lastFocus = doc.activeElement;
      show(i);
      lb.classList.add("is-open");
      doc.body.style.overflow = "hidden";
      $(".lb-close", lb).focus();
    };
    var close = function () {
      lb.classList.remove("is-open");
      doc.body.style.overflow = "";
      if (lastFocus && lastFocus.focus) lastFocus.focus();
    };

    zooms.forEach(function (el, i) {
      el.addEventListener("click", function (e) { e.preventDefault(); open(i); });
      el.addEventListener("keydown", function (e) {
        if (e.key === "Enter" || e.key === " ") { e.preventDefault(); open(i); }
      });
    });

    $(".lb-close", lb).addEventListener("click", close);
    $(".lb-prev", lb).addEventListener("click", function () { show(cur - 1); });
    $(".lb-next", lb).addEventListener("click", function () { show(cur + 1); });
    lb.addEventListener("click", function (e) { if (e.target === lb) close(); });

    doc.addEventListener("keydown", function (e) {
      if (!lb.classList.contains("is-open")) return;
      if (e.key === "Escape") close();
      else if (e.key === "ArrowLeft") show(cur - 1);
      else if (e.key === "ArrowRight") show(cur + 1);
    });
  }

  /* ---------- 10. 功能筛选 ---------- */
  var filterBar = $("[data-filters]");
  if (filterBar) {
    var fBtns = $$("button", filterBar);
    var cards = $$("[data-cat]");

    var apply = function (f) {
      cards.forEach(function (c) {
        var cat = c.getAttribute("data-cat") || "";
        var show = f === "all" || cat.indexOf(f) > -1;
        if (show) {
          c.classList.remove("is-hidden");
          c.classList.remove("pop");
          void c.offsetWidth;
          c.classList.add("pop");
        } else {
          c.classList.add("is-hidden");
        }
      });
    };

    fBtns.forEach(function (b) {
      b.addEventListener("click", function () {
        fBtns.forEach(function (x) { x.classList.toggle("is-on", x === b); });
        apply(b.getAttribute("data-filter"));
        /* 筛选后补触发一次进入动画 */
        cards.forEach(function (c) {
          if (!c.classList.contains("is-hidden")) c.classList.add("in");
        });
      });
    });
  }

  /* ---------- 11. 终端复制 ---------- */
  var copyBtn = doc.getElementById("copyBtn");
  if (copyBtn) {
    var text = [
      "git clone " + CONFIG.repo + ".git",
      "cd NJMU-Helper",
      "hvigorw --mode module -p product=default assembleHap --no-daemon"
    ].join("\n");

    copyBtn.addEventListener("click", function () {
      var done = function () {
        copyBtn.textContent = "已复制";
        setTimeout(function () { copyBtn.textContent = "复制"; }, 1600);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done).catch(done);
      } else {
        var ta = doc.createElement("textarea");
        ta.value = text;
        doc.body.appendChild(ta);
        ta.select();
        try { doc.execCommand("copy"); } catch (e) { }
        doc.body.removeChild(ta);
        done();
      }
    });
  }

  /* ---------- 12. 移动端菜单 ---------- */
  var toggle = doc.getElementById("navToggle");
  var navLinks = doc.getElementById("navLinks");
  if (toggle && navLinks) {
    var closeMenu = function () {
      navLinks.classList.remove("open");
      toggle.classList.remove("is-open");
      toggle.setAttribute("aria-expanded", "false");
    };
    toggle.addEventListener("click", function () {
      var open = navLinks.classList.toggle("open");
      toggle.classList.toggle("is-open", open);
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
    });
    navLinks.addEventListener("click", function (e) {
      if (e.target.tagName === "A") closeMenu();
    });
    doc.addEventListener("click", function (e) {
      if (!navLinks.contains(e.target) && !toggle.contains(e.target)) closeMenu();
    });
    doc.addEventListener("keydown", function (e) { if (e.key === "Escape") closeMenu(); });
  }

  /* ---------- 13. 首屏完成 ---------- */
  window.requestAnimationFrame(function () {
    doc.body.classList.add("ready");
    scrollFrame();
  });
})();
