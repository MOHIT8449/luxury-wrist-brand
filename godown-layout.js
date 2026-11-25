/* LUXURY WRIST BRAND ERP — Godown 3D: the pallet lines (lanes) of the main godown.
   One place for the layout, used by godown-3d.html (tables) and godown-3d-scene.js (3D).
   Sizes in feet. Plot 117 x 120 ft; x = left to right (offices on the left), z = front (shutters) to back.
   Pallet 40 x 50 in. Roads (C shape): left driveway x 12-24, front yard z 0-15, right driveway x 96-106.
   Line codes:
     A01-A25  centre stock, left of the centre column line, picked from the left driveway   (10 pallets deep)
     B01-B25  centre stock, right of the centre column line, picked from the right driveway (11 pallets deep)
     C1, C2   right side stock (11 ft strip), picked from the front                          (30 pallets deep)
     D1, D2   left side stock behind the offices, picked from the Rajnigandha gate passage   (14 pallets deep)
   Every slot holds `levels` pallets (2 = one pallet on top of another). */
(function(){
  const PW=40/12,PL=50/12,lanes=[];
  const pad=n=>String(n).padStart(2,"0");
  for(let i=0;i<25;i++){const z=15.6+i*PL;
    const a=[];for(let j=0;j<10;j++)a.push({x:24.6+j*PW,z,w:PW,d:PL});
    lanes.push({code:"A"+pad(i+1),zone:"A",slots:a.reverse(),box:[24.6,z,24.6+10*PW,z+PL],mark:{x:22.4,z:z+PL/2,rot:Math.PI/2}});
    const b=[];for(let j=0;j<11;j++)b.push({x:59.1+j*PW,z,w:PW,d:PL});
    lanes.push({code:"B"+pad(i+1),zone:"B",slots:b,box:[59.1,z,59.1+11*PW,z+PL],mark:{x:98.2,z:z+PL/2,rot:-Math.PI/2}});}
  for(let i=0;i<2;i++){const x=106.5+i*PL;
    const c=[];for(let k=0;k<30;k++)c.push({x,z:16+k*PW,w:PL,d:PW});
    lanes.push({code:"C"+(i+1),zone:"C",slots:c.reverse(),box:[x,16,x+PL,16+30*PW],mark:{x:x+PL/2,z:14.1,rot:0}});
    const xd=3.17+i*PL,d=[];for(let k=0;k<14;k++)d.push({x:xd,z:71+k*PW,w:PL,d:PW});
    lanes.push({code:"D"+(i+1),zone:"D",slots:d.reverse(),box:[xd,71,xd+PL,71+14*PW],mark:{x:xd+PL/2,z:69,rot:0}});}
  const order={A:0,B:1,C:2,D:3};
  lanes.sort((p,q)=>order[p.zone]-order[q.zone]||p.code.localeCompare(q.code,"en",{numeric:true}));
  const ZONE={A:"Centre – left (from left road)",B:"Centre – right (from right road)",C:"Right side stock",D:"Left side stock (Rajnigandha gate)"};
  // Dummy look of a load from the SKU name: brand colour + pack type + bottle size.
  function look(name){
    const s=String(name||"").toUpperCase();
    const br=/THUMS/.test(s)?"TU":/SPRITE/.test(s)?"SP":/COKE|COCA|DIET/.test(s)?"CC":/FANTA/.test(s)?"FA":/LIMCA/.test(s)?"LI":
      /MAAZA|MAZA/.test(s)?"MA":/SODA/.test(s)?"SO":/KINLEY|WATER/.test(s)?"KI":/RAJNI/.test(s)?"RG":s?"PK":"XX";
    if(/\bCAN\b|CANS/.test(s))return [br,"can"];
    if(/TETRA/.test(s))return [br,"tetra"];
    const m=s.match(/(\d+(?:\.\d+)?)\s*(ML|LTR|LT|L)\b/);let ml=m?Number(m[1])*(m[2]==="ML"?1:1000):600;
    if(ml<50)ml*=1000;
    const g=ml<=300?[14,8]:ml<=600?[10,6]:ml<=1000?[9,5]:ml<=1500?[8,5]:[6,4];
    return [br,"b",g[0],g[1]];
  }
  window.LWBGodownLayout={lanes,ZONE,look,PALLET_IN:[40,50]};
})();
