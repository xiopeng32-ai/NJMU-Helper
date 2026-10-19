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

  /* ---------- 8. 交互预览（点击 / 滑动 / 自动巡览） ---------- */
  var demo = doc.getElementById("demo");
  if (demo) {
    var stage = $("[data-stage]", demo);
    var modeCfg = {
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
    var dotsBox = $("[data-dots]", demo);
    var autoBtn = $("[data-auto]", demo);
    var current = "phone";
    var index = { phone: 0, tablet: 0 };

    var itemsOf = function (mode) {
      return modeCfg[mode].list ? $$("button[data-src]", modeCfg[mode].list) : [];
    };

    var setShot = function (mode, src, alt, dir) {
      var img = modeCfg[mode].img;
      if (!img || !src) return;
      var paint = function () {
        img.src = src;
        img.alt = alt || "";
        img.classList.remove("shot-in-r", "shot-in-l");
        void img.offsetWidth;
        if (dir) img.classList.add(dir > 0 ? "shot-in-r" : "shot-in-l");
      };
      if (img.getAttribute("src") === src) return;
      var pre = new Image();
      pre.onload = paint;
      pre.onerror = paint;
      pre.src = src;
    };

    var paintDots = function (mode) {
      if (!dotsBox) return;
      dotsBox.innerHTML = "";
      itemsOf(mode).forEach(function (b, i) {
        var d = doc.createElement("button");
        d.type = "button";
        d.setAttribute("aria-label", b.getAttribute("data-title") || ("第 " + (i + 1) + " 屏"));
        d.addEventListener("click", function () {
          go(mode, i, i > index[mode] ? 1 : -1);
        });
        dotsBox.appendChild(d);
      });
    };

    var syncDots = function (mode) {
      if (!dotsBox) return;
      $$("button", dotsBox).forEach(function (d, i) {
        d.classList.toggle("is-on", i === index[mode]);
      });
    };

    var render = function (mode, i, dir) {
      var list = itemsOf(mode);
      if (!list.length) return;
      index[mode] = (i + list.length) % list.length;
      var btn = list[index[mode]];
      list.forEach(function (b) { b.classList.toggle("is-on", b === btn); });
      setShot(mode, btn.getAttribute("data-src"), btn.getAttribute("data-alt"), dir);
      if (capNum) capNum.textContent = btn.getAttribute("data-num") || "";
      if (capTitle) capTitle.textContent = btn.getAttribute("data-title") || "";
      if (capDesc) capDesc.textContent = btn.getAttribute("data-desc") || "";
      if (mode === "phone") {
        $$(".dock-item", demo).forEach(function (d) {
          d.classList.toggle("is-on", Number(d.getAttribute("data-jump")) === index.phone);
        });
      }
      syncDots(mode);
    };

    var go = function (mode, i, dir) {
      if (mode !== current) setMode(mode);
      render(mode, i, dir);
      kickAuto();
    };

    var step = function (dir) {
      render(current, index[current] + dir, dir);
      kickAuto();
    };

    function setMode(mode) {
      if (!modeCfg[mode] || !modeCfg[mode].list) return;
      current = mode;
      $$("[data-mode]", demo).forEach(function (b) {
        b.classList.toggle("is-on", b.getAttribute("data-mode") === mode);
      });
      Object.keys(modeCfg).forEach(function (k) {
        if (modeCfg[k].pane) modeCfg[k].pane.classList.toggle("is-on", k === mode);
        if (modeCfg[k].list) modeCfg[k].list.classList.toggle("is-on", k === mode);
      });
      paintDots(mode);
      render(mode, index[mode], 0);
    }

    /* 模式切换 */
    $$("[data-mode]", demo).forEach(function (b) {
      b.addEventListener("click", function () { setMode(b.getAttribute("data-mode")); kickAuto(); });
    });

    /* 右侧列表 */
    Object.keys(modeCfg).forEach(function (mode) {
      if (!modeCfg[mode].list) return;
      $$("button[data-src]", modeCfg[mode].list).forEach(function (b, i) {
        b.addEventListener("click", function () { go(mode, i, i > index[mode] ? 1 : -1); });
      });
    });

    /* 模拟底部导航 */
    $$(".dock-item", demo).forEach(function (d) {
      d.addEventListener("click", function () {
        if (current !== "phone") setMode("phone");
        render("phone", Number(d.getAttribute("data-jump")), 1);
        kickAuto();
      });
    });

    /* 左右浮标 */
    $$("[data-step]", demo).forEach(function (b) {
      b.addEventListener("click", function () {
        step(Number(b.getAttribute("data-step")) || 1);
      });
    });

    /* 键盘 */
    demo.addEventListener("keydown", function (e) {
      if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
      step(e.key === "ArrowRight" ? 1 : -1);
      e.preventDefault();
    });

    /* 点击涟漪 */
    var ripple = function (e, body) {
      if (!body || reduce) return;
      var r = body.getBoundingClientRect();
      var s = doc.createElement("span");
      s.className = "tap-ripple";
      s.style.left = (e.clientX - r.left) + "px";
      s.style.top = (e.clientY - r.top) + "px";
      body.appendChild(s);
      setTimeout(function () { if (s.parentNode) s.parentNode.removeChild(s); }, 720);
    };

    /* 拖拽 / 滑动 */
    var drag = null;
    stage.addEventListener("pointerdown", function (e) {
      if (e.target.closest(".phone-dock, .stage-nav")) return;
      if (e.pointerType === "mouse" && e.button !== 0) return;
      drag = { x: e.clientX, y: e.clientY, dx: 0, t: Date.now(), id: e.pointerId, moved: false };
      try { stage.setPointerCapture(e.pointerId); } catch (err) { }
    });

    stage.addEventListener("pointermove", function (e) {
      if (!drag || e.pointerId !== drag.id) return;
      var dx = e.clientX - drag.x, dy = e.clientY - drag.y;
      if (!drag.moved && Math.abs(dx) > 9 && Math.abs(dx) > Math.abs(dy)) {
        drag.moved = true;
        stage.classList.add("is-drag");
      }
      if (!drag.moved) return;
      drag.dx = dx;
      var body = $(".dev.is-on .dev-body", stage);
      if (body) body.style.transform = "translateX(" + (dx * 0.3).toFixed(1) + "px)";
    });

    var endDrag = function (e) {
      if (!drag) return;
      var dx = drag.dx, moved = drag.moved, dt = Date.now() - drag.t;
      var body = $(".dev.is-on .dev-body", stage);
      stage.classList.remove("is-drag");
      if (body) body.style.transform = "";
      drag = null;
      if (moved && Math.abs(dx) > 46) { step(dx < 0 ? 1 : -1); return; }
      if (!moved && dt < 520 && body && !e.target.closest("button")) {
        ripple(e, body);
        step(1);
      }
    };
    stage.addEventListener("pointerup", endDrag);
    stage.addEventListener("pointercancel", function () {
      stage.classList.remove("is-drag");
      var body = $(".dev.is-on .dev-body", stage);
      if (body) body.style.transform = "";
      drag = null;
    });

    /* 自动巡览 */
    var autoOn = false, autoTimer = null, AUTO_MS = 3400;
    var stopAuto = function () {
      autoOn = false;
      if (autoTimer) { clearInterval(autoTimer); autoTimer = null; }
      if (autoBtn) {
        autoBtn.classList.remove("is-on");
        autoBtn.setAttribute("aria-pressed", "false");
        var t = $("span", autoBtn);
        if (t) t.textContent = "自动巡览";
      }
    };
    var startAuto = function () {
      autoOn = true;
      if (autoBtn) {
        autoBtn.classList.add("is-on");
        autoBtn.setAttribute("aria-pressed", "true");
        var t = $("span", autoBtn);
        if (t) t.textContent = "暂停巡览";
      }
      if (autoTimer) clearInterval(autoTimer);
      autoTimer = setInterval(function () {
        if (doc.hidden) return;
        render(current, index[current] + 1, 1);
      }, AUTO_MS);
    };
    function kickAuto() {
      if (autoOn) startAuto();
    }
    if (autoBtn) {
      autoBtn.addEventListener("click", function () {
        if (autoOn) stopAuto(); else startAuto();
      });
    }
    doc.addEventListener("visibilitychange", function () {
      if (doc.hidden && autoTimer) { clearInterval(autoTimer); autoTimer = null; }
      else if (autoOn && !autoTimer) startAuto();
    });

    /* 初始化 */
    paintDots("phone");
    render("phone", 0, 0);
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
      '<figure><img alt=""><figcaption></figcaption></figure>' +
      '<span class="lb-hint"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M8 12h8M5 9l-3 3 3 3M19 9l3 3-3 3"/></svg>左右拖拽或按 ← → 翻页，Esc 关闭</span>';
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
      /* 预取相邻 */
      var nx = new Image();
      nx.src = zooms[(cur + 1) % zooms.length].getAttribute("data-zoom");
      var pv = new Image();
      pv.src = zooms[(cur - 1 + zooms.length) % zooms.length].getAttribute("data-zoom");
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

    /* 拖拽 / 滑动翻页 */
    var lbDrag = null, justDragged = false;
    lb.addEventListener("pointerdown", function (e) {
      if (e.target.closest("button")) return;
      if (e.pointerType === "mouse" && e.button !== 0) return;
      lbDrag = { x: e.clientX, y: e.clientY, dx: 0, id: e.pointerId, moved: false };
      justDragged = false;
      try { lb.setPointerCapture(e.pointerId); } catch (err) { }
    });
    lb.addEventListener("pointermove", function (e) {
      if (!lbDrag || e.pointerId !== lbDrag.id) return;
      var dx = e.clientX - lbDrag.x, dy = e.clientY - lbDrag.y;
      if (!lbDrag.moved && Math.abs(dx) > 9 && Math.abs(dx) > Math.abs(dy)) {
        lbDrag.moved = true;
        lb.classList.add("is-drag");
      }
      if (!lbDrag.moved) return;
      lbDrag.dx = dx;
      lbImg.style.transform = "translateX(" + (dx * 0.55).toFixed(1) + "px)";
      lbImg.style.opacity = String(Math.max(0.35, 1 - Math.abs(dx) / 620));
    });
    var lbEnd = function () {
      if (!lbDrag) return;
      var dx = lbDrag.dx, moved = lbDrag.moved;
      lb.classList.remove("is-drag");
      lbImg.style.transform = "";
      lbImg.style.opacity = "";
      lbDrag = null;
      if (moved) {
        justDragged = true;
        if (Math.abs(dx) > 58) show(cur + (dx < 0 ? 1 : -1));
      }
    };
    lb.addEventListener("pointerup", lbEnd);
    lb.addEventListener("pointercancel", lbEnd);

    lb.addEventListener("click", function (e) {
      if (justDragged) { justDragged = false; return; }
      if (e.target === lb) close();
    });

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
    var bento = $(".bento");

    var apply = function (f) {
      if (bento) bento.classList.toggle("is-filtered", f !== "all");
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

  /* ---------- 14. 页面离场过渡 ---------- */
  if (!reduce) {
    doc.addEventListener("click", function (e) {
      if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return;
      var a = e.target.closest ? e.target.closest("a") : null;
      if (!a || a.target === "_blank" || a.hasAttribute("download")) return;
      var href = a.getAttribute("href");
      if (!href || !/^[\w./-]+\.html(\?[^#]*)?(#.*)?$/.test(href)) return;
      e.preventDefault();
      doc.body.classList.add("is-leaving");
      setTimeout(function () { window.location.href = href; }, 190);
    });
  }

  /* ---------- 15. 首屏完成 ---------- */
  window.requestAnimationFrame(function () {
    doc.body.classList.add("ready");
    scrollFrame();
  });
})();
