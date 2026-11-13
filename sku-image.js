/* LUXURY WRIST BRAND ERP — SKU product photo thumbnails (Mohit 13 Nov 2026).
   A small square photo next to the SKU name in SKU lists (Order Review, SKU search), like a
   marketplace listing. Photo = sku_master.image_url; no photo = a soft box with the first letters.
   LWBSkuImg.load(rows)  -> remember photos from SKU Master rows ({sku_name, image_url})
   LWBSkuImg.html(name)  -> "<span class='sku-th'>…</span>" (tap = big photo)
   LWBSkuImg.url(name)   -> photo URL or "" */
(function(){
  const map=new Map();
  const key=s=>String(s||"").trim().toUpperCase().replace(/\s+/g," ");
  const esc=s=>String(s==null?"":s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  function load(rows){(rows||[]).forEach(r=>{const u=r&&(r.image_url||r.photo_url);if(r&&r.sku_name&&u)map.set(key(r.sku_name),String(u));});}
  function url(name){return map.get(key(name))||"";}
  function initials(name){
    const w=key(name).replace(/^\d+\s*(ML|L|LTR|GM|KG)\s*/,"").split(" ").filter(x=>/[A-Z]/.test(x)&&!/^MRP$/.test(x));
    if(!w.length)return "";
    return ((w[0]||"?")[0]+((w[1]||"")[0]||"")).replace(/[^A-Z]/g,"")||"?";
  }
  function html(name,cls){
    const u=url(name),t=esc(name||"");
    return u
      ? `<span class="sku-th ${cls||""}" role="button" tabindex="0" title="${t}" data-sku-img="${esc(u)}"><img src="${esc(u)}" alt="" loading="lazy" decoding="async" onerror="this.parentNode.classList.add('none');this.remove()"></span>`
      : `<span class="sku-th none ${cls||""}" title="No photo yet" aria-hidden="true">${esc(initials(name))}</span>`;
  }
  function zoom(src,title){
    let box=document.getElementById("skuImgZoom");
    if(!box){
      box=document.createElement("div");box.id="skuImgZoom";box.className="sku-zoom";
      box.innerHTML='<figure><button type="button" aria-label="Close">✕</button><img alt=""><figcaption></figcaption></figure>';
      box.addEventListener("click",e=>{if(e.target===box||e.target.closest("button"))box.classList.remove("show");});
      document.addEventListener("keydown",e=>{if(e.key==="Escape"&&box.classList.contains("show")){e.stopPropagation();box.classList.remove("show");}},true);
      document.body.appendChild(box);
    }
    box.querySelector("img").src=src;box.querySelector("figcaption").textContent=title||"";box.classList.add("show");
  }
  document.addEventListener("click",e=>{const th=e.target.closest&&e.target.closest(".sku-th[data-sku-img]");if(th){e.preventDefault();e.stopPropagation();zoom(th.dataset.skuImg,th.title);}},true);
  document.addEventListener("keydown",e=>{const th=e.target.closest&&e.target.closest(".sku-th[data-sku-img]");if(th&&(e.key==="Enter"||e.key===" ")){e.preventDefault();zoom(th.dataset.skuImg,th.title);}});
  const css=`.sku-th{flex:0 0 auto;width:40px;height:40px;border:1px solid #dfe5ec;border-radius:6px;background:#fff;display:inline-flex;align-items:center;justify-content:center;overflow:hidden;cursor:zoom-in}
.sku-th img{width:100%;height:100%;object-fit:contain;display:block}
.sku-th.none{cursor:default;background:#f3f5f8;color:#8995a3;font:700 12px/1 system-ui,Arial,sans-serif;letter-spacing:.5px;border-style:dashed}
.sku-th.sm{width:30px;height:30px;border-radius:5px;font-size:10px}
.sku-zoom{position:fixed;inset:0;z-index:5000;background:#0b1320c7;display:none;align-items:center;justify-content:center;padding:16px}
.sku-zoom.show{display:flex}
.sku-zoom figure{position:relative;margin:0;background:#fff;border-radius:12px;padding:14px;max-width:min(420px,100%);text-align:center}
.sku-zoom img{max-width:100%;max-height:60vh;object-fit:contain;display:block;margin:0 auto}
.sku-zoom figcaption{margin-top:8px;font:700 14px system-ui,Arial,sans-serif;color:#14253a}
.sku-zoom button{position:absolute;top:6px;right:6px;width:32px;height:32px;border:0;border-radius:50%;background:#eef1f5;font-size:15px;cursor:pointer}`;
  const st=document.createElement("style");st.textContent=css;(document.head||document.documentElement).appendChild(st);
  window.LWBSkuImg={load,url,html,zoom};
})();
