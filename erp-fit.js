/* LUXURY WRIST BRAND ERP — auto-fit to screen.
   On laptop / desktop screens the whole page is drawn smaller (like browser zoom 80-90%),
   so tables, filters and buttons fit without the user zooming out by hand.
   Phones and small tablets (under 1100px wide) are not changed.
   Load it in <head> (not defer) so the page never flashes at full size.
   Opt out on a page: <html data-nofit>.

   CSS zoom draws vh / vw units 20% short (100vh = 80% of the screen). This file
   rewrites them in the page's stylesheets to calc(Nvh * var(--lwb-vz)), where
   --lwb-vz = 1 / zoom, so full-height popups and side panels still fill the screen.
   Scripts that place popups from getBoundingClientRect() use LWBFit.z() to convert. */
(function(){
  "use strict";
  var D=document,H=D.documentElement;
  if(window.LWBFit||H.hasAttribute("data-nofit"))return;

  var css=
    "@media screen and (min-width:1100px){:root{--lwb-vz:1.1111}html{zoom:.9}"+
    /* the smaller drawing leaves room: let page bodies use the full width (was 1200-1450px) */
    "html body.erp .erp-main>:is(main,.container,.wrap,.page){max-width:none}}"+
    "@media screen and (min-width:1280px){:root{--lwb-vz:1.17647}html{zoom:.85}}"+
    "@media screen and (min-width:1700px){:root{--lwb-vz:1.25}html{zoom:.8}}";
  var st=D.createElement("style");st.id="lwb-fit";st.textContent=css;
  (D.head||H).appendChild(st);

  function z(){var v=parseFloat(getComputedStyle(H).zoom);return v>0?v:1}
  window.LWBFit={
    z:z,
    /* element box in page (CSS px) units, for placing fixed popups */
    rect:function(el){var r=el.getBoundingClientRect(),k=z();
      return {left:r.left/k,top:r.top/k,right:r.right/k,bottom:r.bottom/k,width:r.width/k,height:r.height/k}},
    vw:function(){return (H.clientWidth||innerWidth)/z()},
    vh:function(){return innerHeight/z()}
  };

  var UNIT=/(^|[^\w.-])(-?\d*\.?\d+)((?:d|s|l)?(?:vh|vw|vmin|vmax))\b/g;
  function fixVal(v){
    if(!v||v.indexOf("--lwb-vz")>=0||!/\d(?:d|s|l)?v(?:h|w|min|max)\b/.test(v))return null;
    return v.replace(UNIT,function(m,pre,n,u){return pre+"calc("+n+u+" * var(--lwb-vz, 1))"});
  }
  function fixStyle(s){
    for(var i=0;i<s.length;i++){
      var p=s[i],v=s.getPropertyValue(p),nv=fixVal(v);
      if(nv)try{s.setProperty(p,nv,s.getPropertyPriority(p))}catch(e){}
    }
  }
  function fixRules(rules){
    for(var i=0;i<rules.length;i++){
      var r=rules[i];
      if(r.style)fixStyle(r.style);
      if(r.cssRules)fixRules(r.cssRules);
    }
  }
  var done=typeof WeakSet==="function"?new WeakSet():null;
  function fixSheets(){
    var list=D.styleSheets;
    for(var i=0;i<list.length;i++){
      var sh=list[i];
      if(done&&done.has(sh))continue;
      var rules;try{rules=sh.cssRules}catch(e){continue} /* other-site font sheets */
      if(!rules)continue;
      fixRules(rules);if(done)done.add(sh);
    }
  }
  function fixInline(root){
    if(!root||!root.querySelectorAll)return;
    if(root.getAttribute&&root.getAttribute("style"))fixStyle(root.style);
    var els=root.querySelectorAll("[style*='vh'],[style*='vw'],[style*='vmin'],[style*='vmax']");
    for(var i=0;i<els.length;i++)fixStyle(els[i].style);
  }

  var queued=false;
  function run(){queued=false;fixSheets()}
  function soon(){if(!queued){queued=true;(window.requestAnimationFrame||setTimeout)(run)}}

  fixSheets();
  new MutationObserver(function(muts){
    var sheet=false;
    for(var i=0;i<muts.length;i++){
      var a=muts[i].addedNodes;
      for(var j=0;j<a.length;j++){
        var n=a[j];if(n.nodeType!==1)continue;
        if(n.tagName==="STYLE"||n.tagName==="LINK")sheet=true;
        else{fixInline(n);if(n.querySelector&&n.querySelector("style,link"))sheet=true}
      }
    }
    if(sheet)soon();
  }).observe(H,{childList:true,subtree:true});
  D.addEventListener("DOMContentLoaded",function(){fixSheets();fixInline(D.body)});
  window.addEventListener("load",fixSheets);
  /* a <link> sheet loads after it is added */
  D.addEventListener("load",function(e){if(e.target&&e.target.tagName==="LINK")fixSheets()},true);
})();
