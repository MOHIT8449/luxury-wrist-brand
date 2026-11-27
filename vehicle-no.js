/* Vehicle number format (Mohit, 27 Nov 2026): every vehicle no. is written one way, GJ05 BX 4471.
   2 letters state + 2 digits RTO (GJ5 -> GJ05) + 1 to 3 letters series + 4 digits (44 -> 0044).
   Bharat series: 22 BH 1234 AA. Same rule as lwb_vehicle_fmt() in lwb_dial_book_setup.sql.
   LWBVeh.check(raw)  -> {ok, value, key, err, state}
   LWBVeh.fmt(raw)    -> formatted number, or the typed text (upper case) when it is not valid
   LWBVeh.key(raw)    -> number without spaces (search / match)
   LWBVeh.attach(input, {required}) -> formats on blur, shows a green / red line under the box, input.lwbVehOk() */
(function(){
  'use strict';
  const STATES={AN:"Andaman",AP:"Andhra Pradesh",AR:"Arunachal",AS:"Assam",BR:"Bihar",CG:"Chhattisgarh",CH:"Chandigarh",DD:"Daman",
    DL:"Delhi",DN:"Dadra",GA:"Goa",GJ:"Gujarat",HP:"Himachal",HR:"Haryana",JH:"Jharkhand",JK:"Jammu & Kashmir",KA:"Karnataka",
    KL:"Kerala",LA:"Ladakh",LD:"Lakshadweep",MH:"Maharashtra",ML:"Meghalaya",MN:"Manipur",MP:"Madhya Pradesh",MZ:"Mizoram",
    NL:"Nagaland",OD:"Odisha",OR:"Odisha",PB:"Punjab",PY:"Puducherry",RJ:"Rajasthan",SK:"Sikkim",TN:"Tamil Nadu",TR:"Tripura",
    TS:"Telangana",UK:"Uttarakhand",UA:"Uttarakhand",UP:"Uttar Pradesh",WB:"West Bengal"};
  const clean=v=>String(v==null?"":v).toUpperCase().replace(/[^A-Z0-9]/g,"");
  function check(raw){
    const v=clean(raw);
    if(!v)return {ok:false,empty:true,value:"",key:"",err:"Enter the vehicle no."};
    let m=v.match(/^(\d{2})BH(\d{1,4})([A-Z]{1,2})$/);
    if(m){const value=m[1]+" BH "+m[2].padStart(4,"0")+" "+m[3];return {ok:true,value,key:value.replace(/ /g,""),state:"Bharat (BH) series"}}
    m=v.match(/^([A-Z]{2})(\d{1,2})([A-Z]{1,3})(\d{1,4})$/);
    if(!m){
      const s=v.match(/^([A-Z]{2})(\d{1,2})(\d{1,4})$/);
      return {ok:false,value:v,key:v,err:s?"Series letters missing (like BX): GJ05 BX 4471":
        /^[A-Z]{2}\d{1,2}[A-Z]{1,3}$/.test(v)?"Last 4 digits missing: GJ05 BX 4471":"Write it like GJ05 BX 4471"};
    }
    if(!STATES[m[1]])return {ok:false,value:v,key:v,err:'"'+m[1]+'" is not a state code (GJ, MH, RJ ...)'};
    if(!Number(m[4]))return {ok:false,value:v,key:v,err:"Number cannot be 0000"};
    const value=m[1]+m[2].padStart(2,"0")+" "+m[3]+" "+m[4].padStart(4,"0");
    return {ok:true,value,key:value.replace(/ /g,""),state:STATES[m[1]]};
  }
  const fmt=raw=>{const c=check(raw);return c.ok?c.value:String(raw==null?"":raw).toUpperCase().trim()};
  const key=raw=>check(raw).key;
  function css(){
    if(document.getElementById("lwbVehCss"))return;
    const s=document.createElement("style");s.id="lwbVehCss";
    s.textContent=".lwb-veh-msg{display:block;font-size:12px;margin-top:3px;line-height:1.3}.lwb-veh-msg.ok{color:#13824a}.lwb-veh-msg.bad{color:#c62828;font-weight:600}"+
      "input.lwb-veh-bad{border-color:#c62828!important}input.lwb-veh-ok{border-color:#13824a!important}input.lwb-veh{text-transform:uppercase}";
    document.head.appendChild(s);
  }
  function attach(input,opt){
    if(!input||input.lwbVehOk)return input;
    css();opt=opt||{};input.classList.add("lwb-veh");
    const msg=document.createElement("small");msg.className="lwb-veh-msg";msg.hidden=true;
    input.insertAdjacentElement("afterend",msg);
    const show=(final)=>{
      const c=check(input.value);
      input.classList.toggle("lwb-veh-ok",c.ok);
      input.classList.toggle("lwb-veh-bad",!c.ok&&!c.empty&&final);
      if(c.empty){msg.hidden=!(opt.required&&final);msg.className="lwb-veh-msg bad";msg.textContent=c.err;return c}
      if(c.ok){if(final&&input.value!==c.value){input.value=c.value;input.dispatchEvent(new Event("input",{bubbles:true}))}
        msg.hidden=false;msg.className="lwb-veh-msg ok";msg.textContent="✓ "+c.value+" · "+c.state;return c}
      msg.hidden=!final;msg.className="lwb-veh-msg bad";msg.textContent="✗ "+c.err;return c;
    };
    input.addEventListener("input",()=>{if(!input.lwbVehBusy)show(false)});
    input.addEventListener("blur",()=>{input.lwbVehBusy=true;show(true);input.lwbVehBusy=false});
    input.lwbVehOk=()=>{const c=check(input.value);return c.ok||(c.empty&&!opt.required)};
    input.lwbVehShow=()=>{input.lwbVehBusy=true;const c=show(true);input.lwbVehBusy=false;return c};
    if(input.value)input.lwbVehShow();
    return input;
  }
  window.LWBVeh={check,fmt,key,attach,STATES};
})();
