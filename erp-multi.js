/* LUXURY WRIST BRAND ERP — multi-pick filter with tick boxes (Mohit, 17 Nov 2026).
   "Pick 3 of my 5 salesmen" on a filter: a button that opens a list with a search box and a
   tick box per item. Nothing ticked = All. Every tick applies at once (onChange).
   LWBMulti.mount(el, {all:"All", onChange}) -> {get() Set, set(values), items(list [{v, t}]), label()}
   el = an empty <div>; it becomes the button. The popup closes on Esc / tap outside. */
(function(){
  if(window.LWBMulti)return;
  const D=document;
  const css=`
.lwb-ms{position:relative;min-width:0}
.lwb-ms-btn{display:flex;align-items:center;gap:6px;width:100%;height:36px;border:1.5px solid var(--erp-line,#d5dde8);border-radius:6px;padding:0 8px 0 10px;background:#fff;color:var(--erp-ink,#172b48);font:inherit;font-size:14px;cursor:pointer;text-align:left;min-width:0}
.lwb-ms-btn span{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.lwb-ms-btn b{flex:0 0 auto;background:var(--erp-red,#002f37);color:#fff;border-radius:9px;padding:0 6px;font-size:11px;line-height:17px}
.lwb-ms-btn::after{content:"▾";flex:0 0 auto;font-size:12px;color:#6b7280}
.lwb-ms-btn.on{border-color:var(--erp-red,#002f37)}
.lwb-ms-pop{position:fixed;z-index:2147483000;display:flex;flex-direction:column;background:#fff;color:#111827;border:1px solid #c9a227;border-radius:10px;box-shadow:0 10px 30px rgba(0,0,0,.22);overflow:hidden;font:14px/1.3 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
.lwb-ms-pop input[type=search]{flex:0 0 auto;height:38px;border:0;border-bottom:1px solid #e5e7eb;padding:0 10px;font:inherit;font-size:16px;background:#fffbea;outline:none;min-width:0}
.lwb-ms-bar{display:flex;gap:6px;align-items:center;padding:6px 8px;border-bottom:1px solid #e5e7eb;font-size:12.5px;color:#6b7280}
.lwb-ms-bar button{border:1px solid #d5dde8;background:#fff;border-radius:6px;padding:3px 9px;font:inherit;font-size:12.5px;font-weight:600;cursor:pointer;color:#172b48}
.lwb-ms-bar span{margin-left:auto}
.lwb-ms-pop ul{list-style:none;margin:0;padding:4px 0;overflow-y:auto;overscroll-behavior:contain}
.lwb-ms-pop li label{display:flex;align-items:center;gap:8px;padding:7px 10px;cursor:pointer}
.lwb-ms-pop li label:hover{background:#fef3c7}
.lwb-ms-pop li input{width:16px;height:16px;margin:0;flex:0 0 auto;accent-color:#002f37}
.lwb-ms-pop li.none{padding:8px 10px;color:#6b7280;font-style:italic}`;
  let styled=false,open=null;
  const esc=s=>String(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const norm=s=>String(s||"").toLowerCase().replace(/\s+/g," ").trim();
  function close(){if(!open)return;open.pop.remove();open.btn.setAttribute("aria-expanded","false");open=null}
  D.addEventListener("mousedown",e=>{if(open&&!open.pop.contains(e.target)&&!open.btn.contains(e.target))close()},true);
  D.addEventListener("keydown",e=>{if(e.key==="Escape"&&open){e.stopPropagation();const b=open.btn;close();b.focus()}},true);
  window.addEventListener("resize",close);

  function mount(host,o){
    o=o||{};
    if(!styled){styled=true;const s=D.createElement("style");s.textContent=css;D.head.appendChild(s)}
    let list=[],sel=new Set();
    host.classList.add("lwb-ms");
    const btn=D.createElement("button");btn.type="button";btn.className="lwb-ms-btn";btn.setAttribute("aria-haspopup","listbox");btn.setAttribute("aria-expanded","false");
    if(host.id){btn.id=host.id+"Btn"}
    host.appendChild(btn);
    const label=()=>{if(!sel.size)return o.all||"All";const f=list.filter(x=>sel.has(x.v));return f.length===1?f[0].t:f.length+" selected"};
    const paint=()=>{btn.innerHTML="<span>"+esc(label())+"</span>";btn.classList.toggle("on",sel.size>0);btn.title=sel.size?list.filter(x=>sel.has(x.v)).map(x=>x.t).join(", "):(o.all||"All")};
    const fire=()=>{paint();o.onChange&&o.onChange(new Set(sel))};
    function show(){
      close();
      const pop=D.createElement("div");pop.className="lwb-ms-pop";pop.setAttribute("role","listbox");pop.setAttribute("aria-multiselectable","true");
      pop.innerHTML='<input type="search" placeholder="Type to search..." autocomplete="off"><div class="lwb-ms-bar"><button type="button" data-a="all">Tick shown</button><button type="button" data-a="clear">Clear (All)</button><span></span></div><ul></ul>';
      D.body.appendChild(pop);open={pop,btn};btn.setAttribute("aria-expanded","true");
      const q=pop.querySelector("input"),ul=pop.querySelector("ul"),cnt=pop.querySelector(".lwb-ms-bar span");
      const shown=()=>{const w=norm(q.value).split(" ").filter(Boolean);return list.filter(x=>w.every(t=>norm(x.t).includes(t)))};
      const draw=()=>{const s=shown();ul.innerHTML=s.length?s.slice(0,400).map(x=>'<li><label><input type="checkbox" value="'+esc(x.v)+'"'+(sel.has(x.v)?" checked":"")+">"+esc(x.t)+"</label></li>").join(""):'<li class="none">Nothing found</li>';cnt.textContent=sel.size?sel.size+" ticked":"All"};
      ul.addEventListener("change",e=>{const c=e.target;if(c.type!=="checkbox")return;if(c.checked)sel.add(c.value);else sel.delete(c.value);cnt.textContent=sel.size?sel.size+" ticked":"All";fire()});
      pop.querySelector(".lwb-ms-bar").addEventListener("click",e=>{const a=e.target.closest("[data-a]");if(!a)return;if(a.dataset.a==="all")for(const x of shown())sel.add(x.v);else sel.clear();draw();fire()});
      q.addEventListener("input",draw);
      q.addEventListener("keydown",e=>{if(e.key==="Enter"){e.preventDefault();const s=shown();if(s.length===1){sel.has(s[0].v)?sel.delete(s[0].v):sel.add(s[0].v);draw();fire()}}});
      draw();
      const r=btn.getBoundingClientRect(),vw=innerWidth,vh=innerHeight,w=Math.min(vw-16,Math.max(r.width,280));
      const left=Math.max(8,Math.min(r.left,vw-w-8)),below=vh-r.bottom-8,above=r.top-8,up=below<260&&above>below;
      pop.style.width=w+"px";pop.style.left=left+"px";
      const h=Math.min(380,up?above:below);pop.style.maxHeight=h+"px";
      if(up)pop.style.bottom=(vh-r.top+4)+"px";else pop.style.top=(r.bottom+4)+"px";
      q.focus({preventScroll:true});
    }
    btn.addEventListener("click",()=>{if(open&&open.btn===btn)close();else show()});
    paint();
    return {get:()=>new Set(sel),set(v){sel=new Set([...(v||[])].map(String));paint()},
      items(l){list=l||[];const ok=new Set(list.map(x=>x.v));for(const v of [...sel])if(!ok.has(v))sel.delete(v);paint()},label,
      names:()=>list.filter(x=>sel.has(x.v)).map(x=>x.t)};
  }
  window.LWBMulti={mount};
})();
