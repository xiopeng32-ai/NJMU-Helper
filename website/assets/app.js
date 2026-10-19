
(function(){
  "use strict";

  /* ===== 站点配置：只需改这一处 ===== */
  var CONFIG = {
    // 开源仓库地址（Fork 完成后替换为你的地址）
    repo: "https://github.com/OWNER/NJMU-Helper",
    owner: "OWNER"
  };

  /* 注入仓库地址 */
  ["repoBtn","repoBtn2","repoBtn3"].forEach(function(id){
    var el = document.getElementById(id);
    if(el) el.href = CONFIG.repo;
  });
  var contrib = document.getElementById("contribLink");
  if(contrib) contrib.href = CONFIG.repo + "/blob/main/CONTRIBUTING.md";
  var clog = document.getElementById("changelogLink");
  if(clog) clog.href = CONFIG.repo + "/blob/main/CHANGELOG.md";
  var ownerEl = document.getElementById("repoOwner");
  if(ownerEl) ownerEl.textContent = CONFIG.owner;

  /* ===== 导航滚动态 ===== */
  var nav = document.getElementById("nav");
  var onScroll = function(){
    if(window.scrollY > 24) nav.classList.add("scrolled");
    else nav.classList.remove("scrolled");
  };
  window.addEventListener("scroll", onScroll, {passive:true});
  onScroll();

  /* ===== 移动端菜单 ===== */
  var toggle = document.getElementById("navToggle");
  var links = document.getElementById("navLinks");
  if(toggle){
    toggle.addEventListener("click", function(){
      links.classList.toggle("open");
    });
    links.addEventListener("click", function(e){
      if(e.target.tagName === "A") links.classList.remove("open");
    });
  }

  /* ===== 滚动进入动画 ===== */
  var reveals = document.querySelectorAll(".reveal");
  if("IntersectionObserver" in window){
    var io = new IntersectionObserver(function(entries){
      entries.forEach(function(en){
        if(en.isIntersecting){
          en.target.classList.add("in");
          io.unobserve(en.target);
        }
      });
    }, {rootMargin:"0px 0px -8% 0px", threshold:0.08});
    reveals.forEach(function(el){ io.observe(el); });
  } else {
    reveals.forEach(function(el){ el.classList.add("in"); });
  }

  /* ===== 卡片光斑跟随 ===== */
  document.querySelectorAll(".card").forEach(function(card){
    card.addEventListener("pointermove", function(e){
      var r = card.getBoundingClientRect();
      card.style.setProperty("--mx", (e.clientX - r.left) + "px");
      card.style.setProperty("--my", (e.clientY - r.top) + "px");
    });
  });

  /* ===== 复制命令 ===== */
  var copyBtn = document.getElementById("copyBtn");
  var termBody = document.getElementById("termBody");
  if(copyBtn && termBody){
    copyBtn.addEventListener("click", function(){
      var text = [
        "git clone " + CONFIG.repo + ".git",
        "cd NJMU-Helper",
        "hvigorw --mode module -p product=default assembleHap --no-daemon"
      ].join("\n");
      var done = function(){
        copyBtn.textContent = "已复制";
        setTimeout(function(){ copyBtn.textContent = "复制"; }, 1600);
      };
      if(navigator.clipboard && navigator.clipboard.writeText){
        navigator.clipboard.writeText(text).then(done).catch(done);
      } else {
        var ta = document.createElement("textarea");
        ta.value = text; document.body.appendChild(ta); ta.select();
        try{ document.execCommand("copy"); }catch(e){}
        document.body.removeChild(ta); done();
      }
    });
  }

})();
