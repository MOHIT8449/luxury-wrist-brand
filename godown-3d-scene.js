/* LUXURY WRIST BRAND ERP — Godown 3D scene (three.js r128, vendor/three). Built from the site photos:
   steel shed (3 columns per frame), offices, shutters A-E, roads in a C shape, pallet lines from godown-layout.js.
   LWBGodown3D(viewEl, labelsEl) -> {setLanes(fill), go(view)}. Buttons with ids v3d vtop vfront vside vin vlab vpal vshed zin zout zreset. */
window.LWBGodown3D=function(view,labHost){

const dark=matchMedia('(prefers-color-scheme: dark)').matches&&document.documentElement.dataset.theme!=='light'||document.documentElement.dataset.theme==='dark';
const scene=new THREE.Scene();
scene.background=new THREE.Color(dark?0x16191c:0xe9ecef);
const renderer=new THREE.WebGLRenderer({antialias:true});
renderer.setPixelRatio(Math.min(devicePixelRatio,2));
renderer.shadowMap.enabled=true;renderer.shadowMap.type=THREE.PCFSoftShadowMap;
view.appendChild(renderer.domElement);
const lr=new THREE.CSS2DRenderer();lr.domElement.style.position='absolute';lr.domElement.style.inset='0';labHost.appendChild(lr.domElement);
const camera=new THREE.PerspectiveCamera(42,1,1,3000);
const controls=new THREE.OrbitControls(camera,renderer.domElement);
controls.enableDamping=true;controls.maxPolarAngle=Math.PI/2-0.03;controls.minDistance=3;controls.maxDistance=600;
controls.screenSpacePanning=true;

// lights
scene.add(new THREE.HemisphereLight(0xffffff,0x8a7f6a,0.75));
const sun=new THREE.DirectionalLight(0xffffff,0.8);sun.position.set(-90,160,120);sun.castShadow=true;
sun.shadow.mapSize.set(2048,2048);Object.assign(sun.shadow.camera,{left:-120,right:120,top:120,bottom:-120,near:10,far:500});
scene.add(sun);

// coordinates: x 0..117 left->right as sketch, z 0 (front/gates) .. 120 (back)
const X=x=>x-58.5,Z=z=>z-60;
const M=(c,o={})=>new THREE.MeshStandardMaterial(Object.assign({color:c,roughness:.9,metalness:0},o));
function box(x1,x2,z1,z2,y1,y2,mat,cast=true,par=scene){
  const m=new THREE.Mesh(new THREE.BoxGeometry(x2-x1,y2-y1,z2-z1),mat);
  m.position.set(X((x1+x2)/2),(y1+y2)/2,Z((z1+z2)/2));m.castShadow=cast;m.receiveShadow=true;par.add(m);return m;
}
function label(html,x,y,z,cls='lb'){
  const d=document.createElement('div');d.className=cls;d.innerHTML=html;
  const o=new THREE.CSS2DObject(d);o.position.set(X(x),y,Z(z));scene.add(o);return o;
}

// paver texture: zig-zag herringbone
function paverTex(){
  const c=document.createElement('canvas');c.width=c.height=512;const g=c.getContext('2d');
  const u=128;g.fillStyle='#55585c';g.fillRect(0,0,512,512);
  const greys=['#8e9196','#858a90','#979a9e','#7e8389','#9a9c9f'];
  const zig=(x0,y0,x1,y1,nx,ny,a)=>{const p=[];for(let i=0;i<=4;i++){const t=i/4;let x=x0+(x1-x0)*t,y=y0+(y1-y0)*t;if(i&&i<4){const s=i%2?a:-a;x+=nx*s;y+=ny*s}p.push([x,y])}return p};
  let k=0;
  for(let i=-6;i<8;i++)for(let j=-4;j<5;j++){
    const px=i+2*j,py=i-2*j;
    for(const [bx,by,w,h] of [[px,py,2,1],[px,py+1,1,2]]){
      if(bx<4&&bx+w>0&&by<4&&by+h>0){
        const gp=.06,a=.09,x0=bx+gp,y0=by+gp,x1=bx+w-gp,y1=by+h-gp;
        const pts=w>h?zig(x0,y0,x1,y0,0,1,a).concat(zig(x1,y1,x0,y1,0,-1,a)):zig(x0,y1,x0,y0,1,0,a).concat(zig(x1,y0,x1,y1,-1,0,a));
        g.fillStyle=greys[(k++*3+bx+by+20)%5];g.beginPath();pts.forEach(([x,y],n)=>n?g.lineTo(x*u,y*u):g.moveTo(x*u,y*u));g.closePath();g.fill();
      }
    }
  }
  const t=new THREE.CanvasTexture(c);t.wrapS=t.wrapT=THREE.RepeatWrapping;t.anisotropy=renderer.capabilities.getMaxAnisotropy();return t;
}
const pav=paverTex();
function floor(x1,x2,z1,z2,mat,y=0.02){
  const m=new THREE.Mesh(new THREE.PlaneGeometry(x2-x1,z2-z1),mat);m.rotation.x=-Math.PI/2;
  m.position.set(X((x1+x2)/2),y,Z((z1+z2)/2));m.receiveShadow=true;scene.add(m);return m;
}
function paved(x1,x2,z1,z2){
  const t=pav.clone();t.needsUpdate=true;t.repeat.set((x2-x1)/3,(z2-z1)/3);
  return floor(x1,x2,z1,z2,new THREE.MeshStandardMaterial({map:t,roughness:.95}));
}

// ground
floor(-60,180,-95,170,M(dark?0x3b3a33:0xcfc7b4),-0.05);
// road in front
floor(-60,180,-80,-46,M(dark?0x2a2c2e:0x5d6064),-0.03);
label('<b>सड़क / ROAD</b>',58.5,0.5,-63,'lb');

// ---- paved driveways
paved(12,24,0,120);          // left drive
paved(12,117,0,15);          // front yard
paved(96,106,15,120);        // right drive
paved(0,12,60,70);           // passage to Rajnigandha gate
paved(-25,-0.4,-45.6,120);   // 25 ft paved side lane outside Rajnigandha gate
paved(0,117,-45.6,-0.4);      // 45 ft wide paved road in front of the shed (vehicle parking at shutters)

// ---- stock zones
const stockMat=M(dark?0x55605f:0xc9cdc8);
const zoneFill=new THREE.MeshStandardMaterial({color:0x2f8f96,transparent:true,opacity:.05,depthWrite:false});
const edgeMat=new THREE.LineBasicMaterial({color:0x0b5f66});
const yel=M(0xf2c300);
function stock(x1,x2,z1,z2,h,html){
  paved(x1,x2,z1,z2);
  // yellow floor marking
  const w=.5;
  box(x1,x2,z1,z1+w,0.03,0.09,yel,false);box(x1,x2,z2-w,z2,0.03,0.09,yel,false);
  box(x1,x1+w,z1,z2,0.03,0.09,yel,false);box(x2-w,x2,z1,z2,0.03,0.09,yel,false);
  label(html,(x1+x2)/2,h+2,(z1+z2)/2,'lb');
}
stock(24,96,15,120,12,'<b>STOCK SPACE – बीच</b>72 ft × 105 ft<small>7,560 sq ft</small>');
stock(106,117,15,120,12,'<b>STOCK SPACE – दाएँ</b>11 × 105 ft<small>1,155 sq ft</small>');
stock(0,12,70,120,10,'<b>STOCK SPACE – बाएँ</b>12 × 50 ft<small>600 sq ft</small>');
// empty 20 ft
floor(0,12,40,60,M(dark?0x4a4740:0xd8d2c4),0.03);
label('<b>खाली जगह</b>12 × 20 ft',6,2,50);

// ---- offices (left strip, z 0..40)
const offWall=M(0xe3d9c6),roof=M(0xb9b3a7),glass=M(0x7fa3bb,{roughness:.2,metalness:.3}),door=M(0x6b4f3a);
const rooms=[[0,14,'Office-1','Mohit Vaghela'],[14,27,'Office-2','Harsh Golke'],[27,40,'Account Room','']];
for(const [a,b,n,who] of rooms){
  box(0.8,12,a,b,0,10,offWall);
  box(0.4,12.4,a,b,10,10.8,roof);
  box(12,12.15,a+2,a+5.5,0,7.5,door,false);
  box(12,12.15,a+7,b-2,3.5,7,glass,false);
  label('<b>'+n+'</b>'+(who?'<small>'+who+'</small>':''),6,11.2,(a+b)/2,'lb');
}
for(const z of [14,27]) box(0.8,12.1,z-.15,z+.15,10.8,11,M(0x8d877b),false);

// ---- boundary walls
const wall=M(0xd9d1c0),cap=M(0xbdb4a1);
const WH=7,FH=12,T=.75;
function wallX(x1,x2,z,h){box(x1,x2,z-T/2,z+T/2,0,h,wall);box(x1-.1,x2+.1,z-T/2-.1,z+T/2+.1,h,h+.35,cap)}
function wallZ(z1,z2,x,h){box(x-T/2,x+T/2,z1,z2,0,h,wall);box(x-T/2-.1,x+T/2+.1,z1-.1,z2+.1,h,h+.35,cap)}
wallZ(0,60,0,WH);wallZ(70,120,0,WH);      // left wall, gap = Rajnigandha gate
wallZ(0,120,117,WH);                       // right wall
wallX(0,117,120,WH);                       // back wall

// front facade with main gate + shutters
const SW=8,SHH=10;const shut=[['A',53.5],['B',71],['C',89.5],['D',102],['E',111.5]].map(([n,c])=>[n,c-SW/2,c+SW/2]);
const openings=[[12,32]].concat(shut.map(s=>[s[1],s[2]]));
let cur=0;
for(const [a,b] of openings){ if(a>cur) wallX(cur,a,0,FH); cur=b; }
wallX(cur,117,0,FH);
// lintels above shutters
const shutTex=(()=>{const c=document.createElement('canvas');c.width=64;c.height=256;const g=c.getContext('2d');
  for(let y=0;y<256;y+=8){g.fillStyle=(y/8)%2?'#9aa3aa':'#b7bfc5';g.fillRect(0,y,64,8);g.fillStyle='#7b848b';g.fillRect(0,y+7,64,1)}
  const t=new THREE.CanvasTexture(c);t.wrapS=t.wrapT=THREE.RepeatWrapping;return t})();
for(const [n,a,b] of shut){
  box(a,b,-T/2,T/2,SHH,FH,wall);
  const t=shutTex.clone();t.needsUpdate=true;t.repeat.set(1,1.2);
  box(a,b,-.15,.15,0,SHH,new THREE.MeshStandardMaterial({map:t,metalness:.4,roughness:.5}),false);
  box(a-.2,b+.2,-.9,-.3,SHH,SHH+1,M(0x6f777d,{metalness:.4}),false);
  label('<b>SHUTTER-'+n+'</b>8 × 10 ft',(a+b)/2,FH+3,-1,'lb');
}
// gate leaves
const steel=M(0x2f3438,{metalness:.6,roughness:.4});
function gateLeaves(x1,x2,zFix,alongZ){
  const n=Math.round(Math.abs(x2-x1)/0.8);
  for(let i=0;i<=n;i++){const p=x1+(x2-x1)*i/n;
    if(alongZ) box(zFix-.1,zFix+.1,p-.06,p+.06,0,6.5,steel,false); else box(p-.06,p+.06,zFix-.1,zFix+.1,0,6.5,steel,false);}
  if(alongZ){box(zFix-.12,zFix+.12,x1,x2,6.3,6.6,steel,false);box(zFix-.12,zFix+.12,x1,x2,.3,.6,steel,false)}
  else{box(x1,x2,zFix-.12,zFix+.12,6.3,6.6,steel,false);box(x1,x2,zFix-.12,zFix+.12,.3,.6,steel,false)}
}
gateLeaves(12,32,-0.2,false);
box(11.2,12,-.6,.6,0,FH+1,M(0x8d877b));box(32,32.8,-.6,.6,0,FH+1,M(0x8d877b));
label('<b>MAIN GATE</b>मुख्य गेट · 20 ft',22,FH+4,-1,'lb');
gateLeaves(60,70,-0.2,true);
label('<b>रजनीगंधा गेट</b>Rajnigandha Gate · 10 ft',-1,9,65,'lb');

// ---- dimension lines
const dimMat=new THREE.LineBasicMaterial({color:0xe8251a});
function dim(p1,p2,txt,lx,lz){
  const g=new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(X(p1[0]),.3,Z(p1[1])),new THREE.Vector3(X(p2[0]),.3,Z(p2[1]))]);
  scene.add(new THREE.Line(g,dimMat));
  for(const p of [p1,p2]){const s=new THREE.Mesh(new THREE.SphereGeometry(.45,8,8),M(0xe8251a));s.position.set(X(p[0]),.3,Z(p[1]));scene.add(s)}
  label(txt,lx??(p1[0]+p2[0])/2,1.2,lz??(p1[1]+p2[1])/2,'lb');
}
dim([0,-8],[117,-8],'117 FT');
dim([-3,-45.6],[-3,-0.4],'45 FT ROAD',-3,-23);
dim([-25,40],[-0.4,40],'25 FT ROAD',-12.7,37);
dim([124,0],[124,120],'120 FT');
dim([-7,0],[-7,40],'40 FT');dim([-7,40],[-7,60],'20 FT');dim([-7,60],[-7,70],'10 FT');dim([-7,70],[-7,120],'50 FT');
dim([24,126],[96,126],'72 FT');
dim([101,15],[101,120],'105 FT · रास्ता 10 ft',101,68);
label('<b>पेवर ब्लॉक रास्ता</b>Driveway 12 ft',18,1.5,95,'lb');
label('<b>पेवर ब्लॉक यार्ड</b>Front yard 15 ft',64,1.5,8,'lb');


// ---- pallet lines (lanes) 40in x 50in, filled from live stock by setLanes()
const PW=40/12,PL=50/12,PH=0.5,LH=4.5;
const LAYOUT=window.LWBGodownLayout.lanes;
const palGroup=new THREE.Group();scene.add(palGroup);
const markGroup=new THREE.Group();scene.add(markGroup);
const dummy=new THREE.Object3D(),unit=new THREE.BoxGeometry(1,1,1);
function inst(geo,mat,items,par){if(!items.length)return;const im=new THREE.InstancedMesh(geo,mat,items.length);im.castShadow=im.receiveShadow=true;
  items.forEach((t,i)=>{dummy.position.set(t[0],t[1],t[2]);dummy.scale.set(t[3],t[4],t[5]);dummy.updateMatrix();im.setMatrixAt(i,dummy.matrix)});(par||palGroup).add(im)}
// brand colours (base, dark, highlight)
const PAL={TU:['#7a4a3a','#3b2420','#e04030'],SP:['#4f9a4c','#2f6e30','#d8f5c8'],CC:['#3a3434','#1c1818','#d33a2c'],FA:['#e07a2a','#a2501a','#ffe0b8'],
  LI:['#dfe8cf','#a9bb8a','#4aa04a'],MA:['#f0b23a','#b37a1a','#fff1c8'],KI:['#dfe9f0','#a9c3d6','#2f7fd0'],SO:['#e9eef0','#b9c3c8','#2d6a4f'],
  RG:['#f3ede0','#c9b896','#2e7d32'],PK:['#c49a6c','#8a6440','#e9d3b0'],XX:['#b8c0c6','#7d868d','#ffffff']};
const look=window.LWBGodownLayout.look;
function loadTex(lk){const [br,type,nc,nl]=lk,[base,dk,hi]=PAL[br]||PAL.XX;
  const c=document.createElement('canvas');c.width=256;c.height=512;const g=c.getContext('2d');
  g.fillStyle=base;g.fillRect(0,0,256,512);
  if(type==='b'){const h=512/nl,w=256/nc;
    for(let L=0;L<nl;L++){const y0=L*h;for(let i=0;i<nc;i++){const x=i*w;
      g.globalAlpha=.6;g.fillStyle=dk;g.fillRect(x+w*.14,y0+h*.28,w*.72,h*.62);g.fillRect(x+w*.36,y0+h*.12,w*.28,h*.18);
      g.globalAlpha=.95;g.fillStyle=hi;g.fillRect(x+w*.34,y0+h*.05,w*.32,h*.08);
      if(br!=='KI'&&br!=='SO'){g.globalAlpha=.8;g.fillStyle=br==='TU'||br==='CC'?'#c8262a':hi;g.fillRect(x+w*.14,y0+h*.5,w*.72,h*.14)}
      g.globalAlpha=.25;g.fillStyle='#fff';g.fillRect(x+w*.2,y0+h*.32,w*.12,h*.5)}
      g.globalAlpha=1;g.fillStyle=dk;g.fillRect(0,y0+h-4,256,4);}}
  else if(type==='can'){const nlc=10,ncc=16,h=512/nlc,w=256/ncc;
    for(let L=0;L<nlc;L++)for(let i=0;i<ncc;i++){const x=i*w,y=L*h;g.fillStyle=i%2?base:dk;g.fillRect(x+1,y+h*.18,w-2,h*.78);
      g.fillStyle='#c9ccd0';g.fillRect(x+1,y+h*.06,w-2,h*.12);g.fillStyle=hi;g.globalAlpha=.7;g.fillRect(x+w*.3,y+h*.45,w*.4,h*.12);g.globalAlpha=1}}
  else if(type==='tetra'){const nlt=12,nct=9,h=512/nlt,w=256/nct;
    for(let L=0;L<nlt;L++)for(let i=0;i<nct;i++){const x=i*w,y=L*h;g.fillStyle=base;g.fillRect(x+1,y+1,w-2,h-2);g.fillStyle=dk;g.fillRect(x+1,y+h*.65,w-2,h*.33);g.fillStyle=hi;g.fillRect(x+w*.2,y+h*.15,w*.6,h*.3)}}
  else{for(let L=0;L<6;L++)for(let i=0;i<3;i++){const x=i*85,y=L*85;g.fillStyle=(L+i)%2?base:'#b88c5e';g.fillRect(x+2,y+2,81,81);g.fillStyle='#d8c49a';g.fillRect(x+36,y+2,10,81)}}
  g.globalAlpha=.16;g.fillStyle='#fff';for(let i=0;i<9;i++)g.fillRect(0,i*58+((i*37)%20),256,3);
  g.fillRect(40,0,10,512);g.fillRect(190,0,6,512);g.globalAlpha=1;
  const t=new THREE.CanvasTexture(c);t.anisotropy=4;return t}
const texCache=new Map();
function matsFor(lk){const k=lk.join('|');if(!texCache.has(k)){const t=loadTex(lk),[base]=PAL[lk[0]]||PAL.XX;
  const side=new THREE.MeshStandardMaterial({map:t,roughness:.3,metalness:lk[1]==='can'?.3:.05}),top=new THREE.MeshStandardMaterial({color:base,roughness:.35});
  texCache.set(k,[side,side,top,top,side,side])}return texCache.get(k)}
const palM=M(0xc0392b,{roughness:.8});
// painted line code on the floor at the access end of every line (what the staff read)
function floorCode(code,x,z,rot){const c=document.createElement('canvas');c.width=256;c.height=128;const g=c.getContext('2d');
  g.fillStyle='#f2c300';g.fillRect(0,0,256,128);g.fillStyle='#111416';g.fillRect(8,8,240,112);g.fillStyle='#f2c300';
  g.font='bold 76px Inter,Arial,sans-serif';g.textAlign='center';g.textBaseline='middle';g.fillText(code,128,68);
  const m=new THREE.Mesh(new THREE.PlaneGeometry(3.2,1.6),new THREE.MeshBasicMaterial({map:new THREE.CanvasTexture(c)}));
  m.rotation.x=-Math.PI/2;m.rotation.z=rot||0;m.position.set(X(x),0.06,Z(z));markGroup.add(m)}
for(const L of LAYOUT)floorCode(L.code,L.mark.x,L.mark.z,L.mark.rot);
// lane lines on the floor (thin yellow) – outline of every line
{const pts=[];for(const L of LAYOUT){const b=L.box;const y=.05;
  pts.push(v3(b[0],y,b[1]),v3(b[2],y,b[1]),v3(b[2],y,b[1]),v3(b[2],y,b[3]),v3(b[2],y,b[3]),v3(b[0],y,b[3]),v3(b[0],y,b[3]),v3(b[0],y,b[1]))}
 markGroup.add(new THREE.LineSegments(new THREE.BufferGeometry().setFromPoints(pts),new THREE.LineBasicMaterial({color:0xf2c300})))}
function v3(x,y,z){return new THREE.Vector3(X(x),y,Z(z))}
let laneLabels=[];
// fill: {code: {pallets, levels, sku}} ; pallets placed deepest slot first, bottom level first per slot
function setLanes(fill){
  while(palGroup.children.length){const c=palGroup.children.pop();c.geometry&&c.geometry!==unit&&c.geometry.dispose()}
  laneLabels.forEach(o=>{scene.remove(o);o.element.remove()});laneLabels=[];
  const deck=[],run=[],byLook=new Map();
  for(const L of LAYOUT){const f=fill[L.code]||{},lv=Math.max(1,f.levels||2);let left=Math.max(0,Math.floor(f.pallets||0));
    const lk=look(f.sku||'');const key=lk.join('|');
    for(const p of L.slots){if(left<=0)break;const n=Math.min(lv,left);left-=n;
      for(let k=0;k<n;k++){const y0=k*(PH+LH),cx=X(p.x+p.w/2),cz=Z(p.z+p.d/2);
        deck.push([cx,y0+PH-0.06,cz,p.w,0.12,p.d]);
        const along=p.d>=p.w;for(const f2 of [-.42,0,.42])along?run.push([cx+f2*p.w,y0+(PH-0.12)/2,cz,0.35,PH-0.12,p.d]):run.push([cx,y0+(PH-0.12)/2,cz+f2*p.d,p.w,PH-0.12,0.35]);
        if(!byLook.has(key))byLook.set(key,{lk,items:[]});byLook.get(key).items.push([cx,y0+PH+LH/2,cz,p.w-0.12,LH,p.d-0.12]);}}
    if(f.sku||f.pallets){const o=label('<b>'+L.code+'</b>'+(f.sku?esc3(f.sku):'—')+'<small>'+(f.pallets||0)+' / '+L.slots.length*lv+'</small>',L.mark.x,2*(PH+LH)+1,L.mark.z,'lb');laneLabels.push(o)}}
  inst(unit,palM,deck);inst(unit,palM,run);
  for(const {lk,items} of byLook.values())inst(unit,matsFor(lk),items);
}
function esc3(s){return String(s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]))}

// ---- forklift OM DVX30 (approx. dims in ft)
const yellowM=M(0xf2b01e,{roughness:.6}),blackM=M(0x1e2124,{roughness:.6}),tyreM=M(0xd9d9d6,{roughness:.9}),mastM=M(0x2b2e31,{metalness:.5,roughness:.5});
function fbox(g,x1,x2,y1,y2,z1,z2,m){const b=new THREE.Mesh(new THREE.BoxGeometry(x2-x1,y2-y1,z2-z1),m);b.position.set((x1+x2)/2,(y1+y2)/2,(z1+z2)/2);b.castShadow=true;g.add(b);return b}
function forklift(x,z,rot,lift){
  const g=new THREE.Group();
  fbox(g,-2,2,0.9,3.4,-6.6,-1.2,yellowM);
  fbox(g,-2,2,0.9,3.9,-8.6,-6.6,blackM);
  fbox(g,-1.6,1.6,3.4,4.6,-5.4,-3.6,blackM);
  const wg=new THREE.CylinderGeometry(1.1,1.1,0.9,20);wg.rotateZ(Math.PI/2);
  for(const [wx,wz,r] of [[1.65,-1.9,1.1],[-1.65,-1.9,1.1],[1.65,-7.3,.95],[-1.65,-7.3,.95]]){const w=new THREE.Mesh(wg,tyreM);w.scale.setScalar(r/1.1);w.position.set(wx,r,wz);w.castShadow=true;g.add(w)}
  for(const px of [-1.9,1.9])for(const pz of [-2.1,-6.3])fbox(g,px-.12,px+.12,3.4,7.75,pz-.12,pz+.12,blackM);
  fbox(g,-2,2,7.75,7.95,-6.4,-2,blackM);
  for(const mx of [-1.1,1.1])fbox(g,mx-.18,mx+.18,0.2,7.6,-.9,-.5,mastM);
  const ly=lift||0;
  fbox(g,-1.6,1.6,0.3+ly,3.4+ly,-.45,-.15,mastM);
  for(const fx of [-.85,.85])fbox(g,fx-.22,fx+.22,0.15+ly,0.35+ly,-.15,3.5,mastM);
  g.position.set(X(x),0,Z(z));g.rotation.y=rot;scene.add(g);return g;
}
forklift(24.4,30,Math.PI/2,0);
forklift(95.6,80,-Math.PI/2,1.5);
forklift(62,8,Math.PI/2,0.4);
label('<b>FORKLIFT</b>OM DVX30',18,10,30,'lb');

// ---- delivery vehicles parked at every shutter (pickup with container body, reversed to the shutter)
const whiteM=M(0xf1f2ef,{roughness:.5}),blueM=M(0x2a7fd4,{roughness:.5}),yelM2=M(0xf2c300),glassM=M(0x27323b,{roughness:.15,metalness:.4}),
  chM=M(0x26292c),tyre2=M(0x1b1c1d,{roughness:.9}),rimM=M(0xb9bec2,{metalness:.6,roughness:.3});
function vehicle(cx,len){
  const g=new THREE.Group(),L=len||16.5,bx=L*.68;   // rear at local z=0, front at z=-L
  fbox(g,-2.6,2.6,1.2,1.9,-L,0,chM);
  fbox(g,-2.95,2.95,1.9,8.2,-bx,-.2,whiteM);                      // container
  fbox(g,-3.0,3.0,4.4,4.7,-bx+.6,-.6,blueM);fbox(g,-3.0,3.0,4.9,5.1,-bx+.6,-.6,blueM); // blue stripes
  fbox(g,-3.0,3.0,2.6,2.8,-bx+.4,-.4,yelM2);                      // yellow strip
  fbox(g,-2.98,2.98,2.2,7.8,-.25,-.15,M(0xe4e6e3));               // rear doors
  fbox(g,-.05,.05,2.2,7.8,-.3,-.1,chM);
  fbox(g,-2.85,2.85,1.6,6.4,-L+.3,-bx-.4,whiteM);                 // cab
  fbox(g,-2.6,2.6,6.4,8.0,-bx-2.4,-bx-.3,blueM);                  // roof spoiler
  fbox(g,-2.7,2.7,4.3,6.1,-L+.2,-L+.5,glassM);                    // windscreen
  for(const sx of [-1,1])fbox(g,sx*2.86-.04,sx*2.86+.04,4.4,6.0,-L+1.4,-bx-1.2,glassM);
  for(const sx of [-1,1])fbox(g,sx*2-.5,sx*2+.5,2.4,3.0,-L+.1,-L+.3,M(0xfafad2,{emissive:0x333322}));
  const wg=new THREE.CylinderGeometry(1.2,1.2,.8,20);wg.rotateZ(Math.PI/2);
  const hg=new THREE.CylinderGeometry(.55,.55,.85,12);hg.rotateZ(Math.PI/2);
  for(const wz of [-2.8,-L+3])for(const sx of [-1,1]){const w=new THREE.Mesh(wg,tyre2);w.position.set(sx*2.55,1.2,wz);w.castShadow=true;g.add(w);
    const h=new THREE.Mesh(hg,rimM);h.position.copy(w.position);g.add(h)}
  g.position.set(X(cx),0,Z(-0.9));scene.add(g);return g;
}
shut.forEach(([n,a,b],i)=>vehicle((a+b)/2,i===2?19:16.5));
// 3-wheeler tempo at Rajnigandha gate (rear to the gate)
{const g=new THREE.Group(),b=(x1,x2,y1,y2,z1,z2,m)=>fbox(g,x1,x2,y1,y2,z1,z2,m);
 const cabY=M(0xf2b705,{roughness:.5}),bodyB=M(0x2f6fb5,{roughness:.6});
 b(-2,2,1,1.5,-10.4,0,chM);
 b(-2.4,2.4,1.5,1.8,-6.2,0,bodyB);
 b(-2.45,-2.25,1.8,3.3,-6.2,0,bodyB);b(2.25,2.45,1.8,3.3,-6.2,0,bodyB);b(-2.4,2.4,1.8,3.3,-.2,0,bodyB);b(-2.4,2.4,1.8,3.3,-6.2,-6,bodyB);
 const cr=[0xb0705a,0x4f9a4c,0xe07a2a,0x3a3434];let i=0;
 for(const cx of [-1.2,1.2])for(const cz of [-4.8,-2.6,-.9])b(cx-1,cx+1,1.8,3.4+(i%2)*.8,cz-.8,cz+.8,M(cr[i++%4],{roughness:.4}));
 b(-1.9,1.9,1.2,6.2,-10.3,-6.3,cabY);
 b(-1.95,1.95,6.2,6.45,-10.5,-6.2,chM);
 b(-1.6,1.6,3.7,5.8,-10.35,-10.25,glassM);
 b(-1.95,-1.85,3.4,5.6,-9.6,-7,glassM);b(1.85,1.95,3.4,5.6,-9.6,-7,glassM);
 const wg=new THREE.CylinderGeometry(.9,.9,.6,16);wg.rotateZ(Math.PI/2);
 for(const [wx,wz] of [[0,-9.3],[-2.05,-2.2],[2.05,-2.2]]){const w=new THREE.Mesh(wg,tyre2);w.position.set(wx,.9,wz);w.castShadow=true;g.add(w)}
 g.position.set(X(-1),0,Z(65));g.rotation.y=Math.PI/2;scene.add(g);
 label('3 WHEELER TEMPO',-8,9,65,'lb');}

// potted palm plants (like the site photo): in front of the office cabins and at the front of the shed
{const potM=M(0xc46a3c,{roughness:.8}),potB=M(0x2f7fd0,{roughness:.6}),soilM=M(0x4a3626),leafM=M(0x3f8a3a,{roughness:.7,side:THREE.DoubleSide}),leafM2=M(0x5aa04a,{roughness:.7,side:THREE.DoubleSide});
 const potG=new THREE.CylinderGeometry(.8,.55,1.5,16),soilG=new THREE.CylinderGeometry(.72,.72,.1,16),leafG=new THREE.SphereGeometry(1,8,6);
 let n=0;
 function plant(x,z,h){const g=new THREE.Group();const pot=new THREE.Mesh(potG,(n%5===2)?potB:potM);pot.position.y=.75;pot.castShadow=true;g.add(pot);
   const so=new THREE.Mesh(soilG,soilM);so.position.y=1.45;g.add(so);
   const H=h||3.2;for(let i=0;i<9;i++){const a=i/9*Math.PI*2+n,lf=new THREE.Mesh(leafG,i%2?leafM:leafM2);
     lf.scale.set(.18,H*.55,.55);lf.position.set(Math.cos(a)*.7,1.5+H*.45,Math.sin(a)*.7);lf.rotation.set(Math.sin(a)*.6,0,-Math.cos(a)*.6);lf.castShadow=true;g.add(lf);}
   g.position.set(X(x),0,Z(z));g.rotation.y=n*1.3;scene.add(g);n++;}
 for(let z=1.5;z<=38.5;z+=2.6)plant(13.2,z,3+(n%3)*.5);            // along office glass front
 for(let x=2;x<=10;x+=2.4)plant(x,-1.6);                           // outside, left of main gate
 for(let x=34;x<=47;x+=2.6)plant(x,-1.6);                          // between main gate and shutter A
 for(const z of [57.5,72.5])plant(-1.6,z);                          // both sides of Rajnigandha gate
}

// 60 ft trailer (stock delivery) parked along the 45 ft road
{const g=new THREE.Group();
 const ribT=(()=>{const c=document.createElement('canvas');c.width=512;c.height=64;const q=c.getContext('2d');q.fillStyle='#c8161d';q.fillRect(0,0,512,64);
   for(let x=0;x<512;x+=10){q.fillStyle='rgba(0,0,0,.18)';q.fillRect(x,0,2,64);q.fillStyle='rgba(255,255,255,.12)';q.fillRect(x+4,0,2,64)}
   const t=new THREE.CanvasTexture(c);t.wrapS=THREE.RepeatWrapping;t.repeat.set(4,1);return t})();
 const redM=new THREE.MeshStandardMaterial({map:ribT,roughness:.5,metalness:.2});
 const b=(x1,x2,y1,y2,z1,z2,m)=>fbox(g,x1,x2,y1,y2,z1,z2,m);
 b(0,48,4.3,13.2,-4.25,4.25,redM);                         // container 48 ft
 b(0,48,3.4,4.3,-3.6,3.6,chM);                             // trailer chassis
 b(-.05,.05,4.4,13.1,-4.2,4.2,M(0x9c1016));                // rear doors
 b(38,38.6,0.4,3.4,-3,-2.4,chM);b(38,38.6,0.4,3.4,2.4,3,chM); // landing legs
 b(44,60,2.2,3.4,-3.3,3.3,chM);                            // tractor chassis
 b(53.2,60,2.6,11.2,-4,4,whiteM);                          // cab
 b(53.2,56,11.2,12.6,-3.6,3.6,whiteM);                     // sleeper roof
 b(59.95,60.1,6.6,10.2,-3.6,3.6,glassM);                   // windscreen
 b(56.5,59,7,9.8,-4.05,-3.95,glassM);b(56.5,59,7,9.8,3.95,4.05,glassM);
 b(59.9,60.3,2.4,4.2,-4,4,M(0x3a3d40,{metalness:.5}));      // bumper
 const wg=new THREE.CylinderGeometry(1.7,1.7,1.2,22);wg.rotateX(Math.PI/2);
 const hg=new THREE.CylinderGeometry(.8,.8,1.25,12);hg.rotateX(Math.PI/2);
 for(const wx of [4,8,12,49.5,52.6,57.6])for(const sz of [-1,1]){const w=new THREE.Mesh(wg,tyre2);w.position.set(wx,1.7,sz*3.4);w.castShadow=true;g.add(w);
   const h=new THREE.Mesh(hg,rimM);h.position.copy(w.position);g.add(h)}
 g.position.set(X(56.6),0,Z(-41));scene.add(g);   // pushed to the far edge & right corner of the 45 ft road
 label('TRAILER 60 ft – स्टॉक गाड़ी',86,15,-41,'lb');}
// forklift unloading from the trailer side and handing to the shutters
forklift(84,-36.1,Math.PI,3);
label('Forklift – ट्रेलर से अनलोडिंग',84,10,-31,'lb');

label('Loading – सभी शटर पर गाड़ी',82,10,-20,'lb');

// ---- steel shed: whole plot, 3 columns per frame (2 sides + 1 centre)
const shed=new THREE.Group();shed.visible=true;scene.add(shed);
const colM=M(0x2e3236,{metalness:.5,roughness:.5}),EH=18,RH=26,sx1=0,sx2=117,rx=58.5;
const v=(x,y,z)=>new THREE.Vector3(X(x),y,Z(z));
const FR=[];for(let z=0;z<=120;z+=15)FR.push(z);
for(const z of FR){const zz=Math.min(Math.max(z,.5),119.5);
  box(sx1+.1,sx1+.9,zz-.4,zz+.4,0,EH,colM,true,shed);box(sx2-.9,sx2-.1,zz-.4,zz+.4,0,EH,colM,true,shed);
  box(rx-.4,rx+.4,zz-.4,zz+.4,0,RH-1.2,colM,true,shed);}
const tm=new THREE.LineBasicMaterial({color:0x15181a});
const yr=x=>RH-(RH-EH)*Math.abs(x-rx)/(rx-sx1);
for(const z0 of FR){const z=Math.min(Math.max(z0,.5),119.5),p=[],N=12;
  for(let i=0;i<N;i++){const x1=sx1+(sx2-sx1)*i/N,x2=sx1+(sx2-sx1)*(i+1)/N;
    p.push(v(x1,yr(x1),z),v(x2,yr(x2),z), v(x1,yr(x1)-2.2,z),v(x2,yr(x2)-2.2,z), v(x1,yr(x1),z),v(x1,yr(x1)-2.2,z), v(x1,yr(x1),z),v(x2,yr(x2)-2.2,z));}
  shed.add(new THREE.LineSegments(new THREE.BufferGeometry().setFromPoints(p),tm));}
// centre longitudinal truss
{const p=[];for(let i=0;i<FR.length-1;i++){const z1=FR[i],z2=FR[i+1];
  p.push(v(rx,RH-1.2,z1),v(rx,RH-1.2,z2),v(rx,RH-3.6,z1),v(rx,RH-3.6,z2));
  for(let k=0;k<5;k++){const a1=z1+15*k/5,a2=z1+15*(k+1)/5;p.push(v(rx,RH-3.6,a1),v(rx,RH-1.2,a2),v(rx,RH-1.2,a2),v(rx,RH-3.6,a2))}}
 shed.add(new THREE.LineSegments(new THREE.BufferGeometry().setFromPoints(p),tm));}
function quad(a,b,c,d,mat,nrm){const g=new THREE.BufferGeometry();
  g.setAttribute('position',new THREE.Float32BufferAttribute([a,b,c,d].flatMap(p=>[p.x,p.y,p.z]),3));
  g.setAttribute('uv',new THREE.Float32BufferAttribute([0,0,1,0,1,1,0,1],2));
  g.setIndex([0,1,2,0,2,3]);g.computeVertexNormals();
  const n=new THREE.Vector3().fromBufferAttribute(g.attributes.normal,0);
  if(n.dot(nrm)<0){g.setIndex([0,2,1,0,3,2]);g.computeVertexNormals()}
  const m=new THREE.Mesh(g,mat);m.receiveShadow=true;shed.add(m);return m}
function cv(w,h,fn,rx_,ry_){const c=document.createElement('canvas');c.width=w;c.height=h;fn(c.getContext('2d'));
  const t=new THREE.CanvasTexture(c);t.wrapS=t.wrapT=THREE.RepeatWrapping;t.repeat.set(rx_,ry_);t.anisotropy=4;return t}
const ribsV=(g,w,h)=>{for(let x=0;x<w;x+=8){g.fillStyle='rgba(0,0,0,.16)';g.fillRect(x,0,2,h);g.fillStyle='rgba(255,255,255,.18)';g.fillRect(x+3,0,2,h)}};
const roofT=cv(16,128,g=>{for(let y=0;y<128;y+=8){g.fillStyle=(y/8)%2?'#7c848a':'#a6aeb3';g.fillRect(0,y,16,8)}},1,10);
const roofM=new THREE.MeshStandardMaterial({map:roofT,metalness:.35,roughness:.55});
const DN=new THREE.Vector3(0,-1,0);
quad(v(sx1,EH,0),v(rx,RH,0),v(rx,RH,120),v(sx1,EH,120),roofM,DN);
quad(v(rx,RH,0),v(sx2,EH,0),v(sx2,EH,120),v(rx,RH,120),roofM,DN);
// outer cladding: blue / white bands like the site photo; inner face grey sheet
const outerMat=len=>new THREE.MeshStandardMaterial({map:cv(512,32,g=>{
  const bands=[['#e9ece9',150],['#1f6fc4',70],['#e9ece9',220],['#1f6fc4',72]];let x=0;for(const [c,w] of bands){g.fillStyle=c;g.fillRect(x,0,w,32);x+=w}ribsV(g,512,32)},len/40,1),roughness:.6,metalness:.2});
const innerMat=len=>new THREE.MeshStandardMaterial({map:cv(256,32,g=>{g.fillStyle='#8b9298';g.fillRect(0,0,256,32);ribsV(g,256,32)},len/20,1),roughness:.6,metalness:.25});
function cladX(z,y1,y2,out,x1=sx1,x2=sx2){const L=x2-x1;
  quad(v(x1,y1,z),v(x2,y1,z),v(x2,y2,z),v(x1,y2,z),outerMat(L),new THREE.Vector3(0,0,out));
  quad(v(x1,y1,z-out*.05),v(x2,y1,z-out*.05),v(x2,y2,z-out*.05),v(x1,y2,z-out*.05),innerMat(L),new THREE.Vector3(0,0,-out));}
function cladZ(x,y1,y2,out,z1,z2){const L=z2-z1;
  quad(v(x,y1,z1),v(x,y1,z2),v(x,y2,z2),v(x,y2,z1),outerMat(L),new THREE.Vector3(out,0,0));
  quad(v(x-out*.05,y1,z1),v(x-out*.05,y1,z2),v(x-out*.05,y2,z2),v(x-out*.05,y2,z1),innerMat(L),new THREE.Vector3(-out,0,0));}
cladZ(-.05,WH,EH,-1,0,120);cladZ(117.05,WH,EH,1,0,120);
cladX(120.05,WH,EH,1);cladX(-.05,FH,EH,-1);
// gable triangles
for(const [z,o] of [[-.05,-1],[120.05,1]]){quad(v(sx1,EH,z),v(rx,EH,z),v(rx,RH,z),v(rx,RH,z),outerMat(58.5),new THREE.Vector3(0,0,o));
  quad(v(rx,EH,z),v(sx2,EH,z),v(rx,RH,z),v(rx,RH,z),outerMat(58.5),new THREE.Vector3(0,0,o));}
// front canopy over shutters + gate letter boards
const canM=new THREE.MeshStandardMaterial({map:cv(16,128,g=>{for(let y=0;y<128;y+=8){g.fillStyle=(y/8)%2?'#5d6468':'#7f878c';g.fillRect(0,y,16,8)}},1,1),metalness:.35,roughness:.55,side:THREE.DoubleSide});
quad(v(45,13.5,-.1),v(117,13.5,-.1),v(117,12.4,-6),v(45,12.4,-6),canM,new THREE.Vector3(0,1,0));
for(let x=46;x<=116;x+=10)box(x-.1,x+.1,-6,-.1,12.3,12.6,colM,false,shed);
for(const [n,a,b] of shut){const c=document.createElement('canvas');c.width=64;c.height=80;const g=c.getContext('2d');
  g.fillStyle='#e8541e';g.fillRect(0,0,64,80);g.fillStyle='#fff';g.font='bold 15px Inter,sans-serif';g.textAlign='center';g.fillText('GATE',32,22);g.font='bold 42px Inter,sans-serif';g.fillText(n,32,66);
  const sp=new THREE.Mesh(new THREE.PlaneGeometry(1.8,2.25),new THREE.MeshBasicMaterial({map:new THREE.CanvasTexture(c)}));
  sp.position.set(X((a+b)/2),11.4,Z(-.45));sp.rotation.y=Math.PI;shed.add(sp);}
// hoarding board on front of shed
{const c=document.createElement('canvas');c.width=1024;c.height=128;const g=c.getContext('2d');
 g.fillStyle='#d71920';g.fillRect(0,0,1024,128);g.fillStyle='#fff';g.fillRect(0,0,1024,6);g.fillRect(0,122,1024,6);
 g.font='800 78px Inter,Arial,sans-serif';g.textAlign='center';g.textBaseline='middle';g.fillText('LUXURY WRIST BRAND',512,68);
 const t=new THREE.CanvasTexture(c);t.anisotropy=8;
 const bd=new THREE.Mesh(new THREE.PlaneGeometry(36,4.5),new THREE.MeshStandardMaterial({map:t,roughness:.6}));
 bd.position.set(X(24),15.3,Z(-.55));bd.rotation.y=Math.PI;shed.add(bd);
 box(5.6,42.4,-.5,-.3,12.9,17.7,M(0x2b2e31,{metalness:.5}),false,shed);}
// red number boards on centre columns
let num=1;
for(const z0 of FR){if(z0===0||z0===120)continue;const c=document.createElement('canvas');c.width=c.height=64;const g=c.getContext('2d');
  g.fillStyle='#d32027';g.fillRect(0,0,64,64);g.fillStyle='#fff';g.font='bold 34px Inter,sans-serif';g.textAlign='center';g.textBaseline='middle';g.fillText(String(num++).padStart(2,'0'),32,34);
  const mat=new THREE.MeshBasicMaterial({map:new THREE.CanvasTexture(c)});
  for(const [dz,ry] of [[-.45,Math.PI],[.45,0]]){const sp=new THREE.Mesh(new THREE.PlaneGeometry(1.4,1.4),mat);sp.position.set(X(rx),14,Z(z0)+dz);sp.rotation.y=ry;shed.add(sp)}}

// ---- views
const views={
  v3d:{p:[-95,120,175],t:[0,0,5]},
  vtop:{p:[0,250,1],t:[0,0,0]},
  vfront:{p:[10,35,-150],t:[0,6,-20]},
  vside:{p:[200,60,30],t:[0,0,0]},
  vin:{p:[X(18),5.5,Z(6)],t:[X(26),6,Z(80)]}
};
let anim=null;
function go(k){
  const v=views[k];document.querySelectorAll('#v3d,#vtop,#vfront,#vside,#vin').forEach(b=>b.classList.toggle('on',b.id===k));
  const p0=camera.position.clone(),t0=controls.target.clone(),p1=new THREE.Vector3(...v.p),t1=new THREE.Vector3(...v.t);
  const reduce=matchMedia('(prefers-reduced-motion: reduce)').matches;const st=performance.now(),dur=reduce?0:700;
  anim=now=>{const f=dur?Math.min(1,(now-st)/dur):1,e=f<.5?2*f*f:1-((-2*f+2)**2)/2;
    camera.position.lerpVectors(p0,p1,e);controls.target.lerpVectors(t0,t1,e);if(f>=1)anim=null;};
}
for(const k in views) document.getElementById(k).addEventListener('click',()=>go(k));
const zoom=f=>{const off=camera.position.clone().sub(controls.target).multiplyScalar(f);
  const d=off.length();if(d<controls.minDistance||d>controls.maxDistance)return;camera.position.copy(controls.target).add(off)};
document.getElementById('zin').addEventListener('click',()=>zoom(.75));
document.getElementById('zout').addEventListener('click',()=>zoom(1.33));
document.getElementById('zreset').addEventListener('click',()=>go('v3d'));
const vlab=document.getElementById('vlab');
vlab.addEventListener('click',()=>{const on=!vlab.classList.contains('on');vlab.classList.toggle('on',on);vlab.setAttribute('aria-pressed',on);lr.domElement.style.display=on?'':'none'});

function toggle(id,fn){const b=document.getElementById(id);b.addEventListener('click',()=>{const on=!b.classList.contains('on');b.classList.toggle('on',on);b.setAttribute('aria-pressed',on);fn(on)})}
toggle('vpal',on=>palGroup.visible=on);
toggle('vshed',on=>shed.visible=on);



camera.position.set(...views.v3d.p);controls.target.set(...views.v3d.t);
function size(){const w=view.clientWidth,h=view.clientHeight;renderer.setSize(w,h);lr.setSize(w,h);camera.aspect=w/h;
  camera.fov=w<h?60:42;camera.updateProjectionMatrix()}
const ro=new ResizeObserver(size);ro.observe(view);size();
renderer.setAnimationLoop(now=>{if(anim)anim(now);controls.update();renderer.render(scene,camera);lr.render(scene,camera)});

return {setLanes,go};
};
