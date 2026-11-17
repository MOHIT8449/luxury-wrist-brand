/* LUXURY WRIST BRAND ERP — Excel-style column filter / sort on report tables (Mohit, 17 Nov 2026).
   Each column head gets a ▾ button. It opens a small popup:
     text column  -> sort A-Z / Z-A, search + tick boxes of the values (nothing ticked = all)
     number       -> sort low / high, Min and Max
     date (ISO)   -> sort old / new, From and To
   On phone (table head hidden) the same buttons show as a row of column chips above the table.
   const cf=LWBCol.create({onChange})
   cf.apply(key, head, rows, {split:[i]}) -> rows filtered + sorted (rows = [{data:[...]}]; split = values joined by ", ")
   cf.th(key, head, i) -> html for the ▾ button inside a <th>
   cf.chips(key, head) -> html of the phone chip row ("" when there is nothing to show)
   cf.count(key) / cf.clear(key)
   Clicks on [data-cf] are handled by cf itself (document listener). */
(function(){
  if(window.LWBCol)return;
  const D=document;
  const css=`
.lwb-cf{border:0;background:transparent;cursor:pointer;color:inherit;opacity:.55;font-size:10px;padding:2px 3px;margin-left:2px;border-radius:4px;line-height:1;vertical-align:middle}
.lwb-cf:hover{opacity:1;background:rgba(0,0,0,.07)}
.lwb-cf.on{opacity:1;background:var(--erp-red,#002f37);color:#fff}
th .lwb-cf{font-weight:700}
.lwb-cf-chips{display:none}
@media(max-width:640px){
 .lwb-cf-chips{display:flex;gap:5px;overflow-x:auto;padding:6px 10px;border-bottom:1px solid var(--erp-line,#e5e7eb);scrollbar-width:none}
 .lwb-cf-chips::-webkit-scrollbar{display:none}
 .lwb-cf-chips .lwb-cf{flex:0 0 auto;opacity:1;border:1px solid var(--erp-line,#d5dde8);background:#fff;font-size:12px;padding:4px 9px;border-radius:14px;font-weight:600;color:var(--erp-ink,#172b48);white-space:nowrap}
 .lwb-cf-chips .lwb-cf.on{background:var(--erp-red,#002f37);border-color:var(--erp-red,#002f37);color:#fff}
 .lwb-cf-chips .lwb-cf-x{color:#b91c1c;border-color:#fca5a5}
}
.lwb-cf-pop{position:fixed;z-index:2147483000;display:flex;flex-direction:column;background:#fff;color:#111827;border:1px solid #c9a227;border-radius:10px;box-shadow:0 10px 30px rgba(0,0,0,.22);overflow:hidden;font:14px/1.3 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;text-transform:none;letter-spacing:0;font-weight:400}
.lwb-cf-pop h4{margin:0;padding:8px 10px 6px;font-size:13px;font-weight:700;color:#172b48;border-bottom:1px solid #e5e7eb}
.lwb-cf-row{display:flex;gap:6px;align-items:center;padding:6px 8px;border-bottom:1px solid #e5e7eb;font-size:12.5px;color:#6b7280;flex-wrap:wrap}
.lwb-cf-row button{border:1px solid #d5dde8;background:#fff;border-radius:6px;padding:4px 9px;font:inherit;font-size:12.5px;font-weight:600;cursor:pointer;color:#172b48}
.lwb-cf-row button.on{background:#002f37;border-color:#002f37;color:#fff}
.lwb-cf-row .sp{margin-left:auto}
.lwb-cf-row label{display:flex;flex-direction:column;gap:2px;flex:1 1 0;min-width:0;font-size:11.5px;font-weight:600}
.lwb-cf-row label input{height:32px;border:1.5px solid #d5dde8;border-radius:6px;padding:0 6px;font:inherit;font-size:14px;min-width:0;width:100%}
.lwb-cf-pop input[type=search]{flex:0 0 auto;height:36px;border:0;border-bottom:1px solid #e5e7eb;padding:0 10px;font:inherit;font-size:16px;background:#fffbea;outline:none;min-width:0}
.lwb-cf-pop ul{list-style:none;margin:0;padding:4px 0;overflow-y:auto;overscroll-behavior:contain;flex:1 1 auto}
.lwb-cf-pop li label{display:flex;align-items:center;gap:8px;padding:6px 10px;cursor:pointer}
.lwb-cf-pop li label:hover{background:#fef3c7}
.lwb-cf-pop li label small{margin-left:auto;color:#9ca3af;font-size:11.5px}
.lwb-cf-pop li input{width:16px;height:16px;margin:0;flex:0 0 auto;accent-color:#002f37}
.lwb-cf-pop li.none{padding:8px 10px;color:#6b7280;font-style:italic}`;
  const esc=s=>String(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const norm=s=>String(s??"").toLowerCase().replace(/\s+/g," ").trim();
  const isNum=v=>typeof v==="number"&&Number.isFinite(v);
  const isDate=v=>typeof v==="string"&&/^\d{4}-\d{2}-\d{2}/.test(v);
  const empty=v=>v==null||v==="";
  let styled=false,open=null;
  function close(){if(!open)return;open.pop.remove();open=null}
  D.addEventListener("mousedown",e=>{if(open&&!open.pop.contains(e.target)&&!e.target.closest("[data-cf]"))close()},true);
  D.addEventListener("keydown",e=>{if(e.key==="Escape"&&open){e.stopPropagation();close()}},true);
  window.addEventListener("resize",()=>{if(open&&!open.pop.contains(D.activeElement))close()});

  function create(o){
    o=o||{};
    if(!styled){styled=true;const s=D.createElement("style");s.textContent=css;D.head.appendChild(s)}
    const state={};      // key -> {f:{col:{...}}, sort:{col,dir}}
    const seen={};       // key -> {head, rows, split}
    const st=k=>state[k]||(state[k]={f:{},sort:null});
    const typeOf=(rows,i)=>{let n=0,d=0,t=0;for(const r of rows){const v=r.data[i];if(empty(v))continue;if(isNum(v))n++;else if(isDate(v))d++;else t++}return t?"text":d&&!n?"date":n?"num":"text"};
    const vals=(v,split)=>split?String(v??"").split(", ").map(x=>x.trim()).filter(Boolean):[String(v??"").trim()||"(blank)"];
    function pass(r,col,f,split){
      const v=r.data[col];
      if(f.set){const vs=vals(v,split);return vs.some(x=>f.set.has(x))}
      if(f.min!=null||f.max!=null){
        if(empty(v))return false;
        const x=f.t==="date"?String(v).slice(0,10):Number(v);
        if(f.min!=null&&x<f.min)return false;if(f.max!=null&&x>f.max)return false;
      }
      return true;
    }
    function apply(key,head,rows,opt){
      const s=st(key),split=new Set((opt&&opt.split)||[]);
      seen[key]={head,rows,split};
      // drop filters for columns this view does not have (e.g. head changed)
      for(const c of Object.keys(s.f))if(!head.includes(c))delete s.f[c];
      if(s.sort&&!head.includes(s.sort.col))s.sort=null;
      let out=rows;
      for(const [name,f] of Object.entries(s.f)){const i=head.indexOf(name);if(i<0)continue;out=out.filter(r=>pass(r,i,f,split.has(i)))}
      if(s.sort){const i=head.indexOf(s.sort.col);if(i>=0){const dir=s.sort.dir;out=out.slice().sort((a,b)=>{
        const x=a.data[i],y=b.data[i];if(empty(x)&&empty(y))return 0;if(empty(x))return 1;if(empty(y))return -1;
        return (isNum(x)&&isNum(y)?x-y:String(x).localeCompare(String(y),undefined,{numeric:true}))*dir})}}
      return out;
    }
    const on=(key,h)=>!!(state[key]&&(state[key].f[h]||(state[key].sort&&state[key].sort.col===h)));
    function th(key,head,i){
      const h=head[i],s=state[key],ar=s&&s.sort&&s.sort.col===h?(s.sort.dir>0?"▲":"▼"):"▾";
      return '<button type="button" class="lwb-cf'+(on(key,h)?" on":"")+'" data-cf="'+i+'" data-cfk="'+esc(key)+'" title="Filter / sort '+esc(h)+'" aria-label="Filter / sort '+esc(h)+'">'+ar+"</button>";
    }
    function chips(key,head){
      const n=count(key);
      return '<div class="lwb-cf-chips">'+head.map((h,i)=>'<button type="button" class="lwb-cf'+(on(key,h)?" on":"")+'" data-cf="'+i+'" data-cfk="'+esc(key)+'">'+esc(h)+" ▾</button>").join("")+
        (n?'<button type="button" class="lwb-cf lwb-cf-x" data-cf="x" data-cfk="'+esc(key)+'">✕ Clear '+n+"</button>":"")+"</div>";
    }
    const count=key=>{const s=state[key];return s?Object.keys(s.f).length+(s.sort?1:0):0};
    function clear(key){delete state[key];close();o.onChange&&o.onChange()}
    const fire=()=>{o.onChange&&o.onChange()};

    function show(btn,key,i){
      close();
      const sv=seen[key];if(!sv)return;
      const h=sv.head[i],s=st(key),split=sv.split.has(i),t=split?"text":typeOf(sv.rows,i),f=s.f[h]||{};
      const pop=D.createElement("div");pop.className="lwb-cf-pop";
      const sortTxt=t==="num"?["↑ Low to high","↓ High to low"]:t==="date"?["↑ Oldest first","↓ Newest first"]:["↑ A to Z","↓ Z to A"];
      const sd=s.sort&&s.sort.col===h?s.sort.dir:0;
      let body='<h4>'+esc(h)+'</h4><div class="lwb-cf-row"><button type="button" data-s="1"'+(sd>0?' class="on"':"")+">"+sortTxt[0]+'</button><button type="button" data-s="-1"'+(sd<0?' class="on"':"")+">"+sortTxt[1]+'</button><button type="button" class="sp" data-c="1">Clear</button></div>';
      if(t==="text")body+='<input type="search" placeholder="Type to search..." autocomplete="off"><div class="lwb-cf-row"><button type="button" data-a="all">Tick shown</button><button type="button" data-a="none">All (untick)</button><span class="sp"></span></div><ul></ul>';
      else{const it=t==="date"?"date":"number",mv=x=>x==null?"":esc(x);
        body+='<div class="lwb-cf-row"><label>'+(t==="date"?"From":"Min")+'<input type="'+it+'" data-r="min" value="'+mv(f.min)+'"'+(it==="number"?' inputmode="decimal"':"")+'></label><label>'+(t==="date"?"To":"Max")+'<input type="'+it+'" data-r="max" value="'+mv(f.max)+'"'+(it==="number"?' inputmode="decimal"':"")+"></label></div>"}
      pop.innerHTML=body;D.body.appendChild(pop);open={pop,btn};
      pop.addEventListener("click",e=>{
        const b=e.target.closest("button");if(!b)return;
        if(b.dataset.s){const d=Number(b.dataset.s);s.sort=sd===d?null:{col:h,dir:d};close();fire();return}
        if(b.dataset.c){delete s.f[h];if(s.sort&&s.sort.col===h)s.sort=null;close();fire();return}
      });
      if(t==="text"){
        const cnt=new Map();for(const r of sv.rows)for(const x of vals(r.data[i],split))cnt.set(x,(cnt.get(x)||0)+1);
        const list=[...cnt].sort((a,b)=>split?b[1]-a[1]:a[0].localeCompare(b[0],undefined,{numeric:true}));
        const sel=new Set(f.set||[]);
        const q=pop.querySelector("input"),ul=pop.querySelector("ul"),lab=pop.querySelector(".lwb-cf-row:last-of-type .sp");
        const shown=()=>{const w=norm(q.value).split(" ").filter(Boolean);return list.filter(([x])=>w.every(t=>norm(x).includes(t)))};
        const save=()=>{if(sel.size)s.f[h]={set:new Set(sel)};else delete s.f[h];lab.textContent=sel.size?sel.size+" ticked":"All";fire()};
        const draw=()=>{const sh=shown();ul.innerHTML=sh.length?sh.slice(0,400).map(([x,n])=>'<li><label><input type="checkbox" value="'+esc(x)+'"'+(sel.has(x)?" checked":"")+">"+esc(x)+"<small>"+n+"</small></label></li>").join(""):'<li class="none">Nothing found</li>';lab.textContent=sel.size?sel.size+" ticked":"All"};
        ul.addEventListener("change",e=>{const c=e.target;if(c.type!=="checkbox")return;c.checked?sel.add(c.value):sel.delete(c.value);save()});
        pop.querySelector("[data-a=all]").onclick=()=>{for(const [x] of shown())sel.add(x);draw();save()};
        pop.querySelector("[data-a=none]").onclick=()=>{sel.clear();draw();save()};
        q.addEventListener("input",draw);draw();
      }else{
        const rd=()=>{const g=n=>{const x=pop.querySelector('[data-r="'+n+'"]').value;return x===""?null:t==="date"?x:Number(x)};const mn=g("min"),mx=g("max");if(mn==null&&mx==null)delete s.f[h];else s.f[h]={t,min:mn,max:mx};fire()};
        pop.querySelectorAll("[data-r]").forEach(x=>x.addEventListener("change",rd));
      }
      const r=btn.getBoundingClientRect(),vw=innerWidth,vh=innerHeight,w=Math.min(vw-16,280);
      const left=Math.max(8,Math.min(r.left,vw-w-8)),below=vh-r.bottom-8,above=r.top-8,up=below<240&&above>below;
      pop.style.width=w+"px";pop.style.left=left+"px";pop.style.maxHeight=Math.min(400,up?above:below)+"px";
      if(up)pop.style.bottom=(vh-r.top+4)+"px";else pop.style.top=(r.bottom+4)+"px";
      const fi=pop.querySelector("input");if(fi&&!("ontouchstart" in window))fi.focus({preventScroll:true});
    }
    D.addEventListener("click",e=>{
      const b=e.target.closest("[data-cf]");if(!b||!seen[b.dataset.cfk])return;
      e.preventDefault();e.stopPropagation();
      if(b.dataset.cf==="x"){clear(b.dataset.cfk);return}
      if(open&&open.btn===b){close();return}
      show(b,b.dataset.cfk,Number(b.dataset.cf));
    },true);
    return {apply,th,chips,count,clear,close};
  }
  window.LWBCol={create};
})();
