/**
 * Luxury Wrist Brand — company document share link (share.html?t=<token>).
 *
 * The party who got the link on WhatsApp has no ERP login. share.html sends the token here;
 * lwb_cdoc_share_open() (service role only, lwb_company_docs_setup.sql) checks it is not expired
 * or stopped, counts the open, and returns the files. Each file gets a signed link valid 15 minutes.
 * The files are the watermarked copies made when the link was sent. Nothing else can be read.
 *
 * Function name: lwb-doc-share   (Verify JWT OFF: public link; the token is the only key)
 */
import { createClient } from 'npm:@supabase/supabase-js@2.118.0';

const ok=(o:string)=>o==='https://luxury-wrist-brand.pages.dev'||/^https:\/\/[a-z0-9-]+\.luxury-wrist-brand\.pages\.dev$/.test(o);
const headers=(origin:string)=>({'Access-Control-Allow-Origin':ok(origin)?origin:'https://luxury-wrist-brand.pages.dev',
  'Access-Control-Allow-Headers':'authorization,apikey,x-client-info,content-type','Access-Control-Allow-Methods':'POST, OPTIONS',
  'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin','X-Robots-Tag':'noindex'});
const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});

Deno.serve(async(req)=>{
  const h=headers(req.headers.get('origin')||'');
  const reply=(status:number,v:unknown)=>new Response(JSON.stringify(v),{status,headers:h});
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers:h});
  if(req.method!=='POST')return reply(405,{error:'POST required'});
  try{
    if(Number(req.headers.get('content-length')||0)>512)return reply(413,{error:'Request too large'});
    const body=await req.json().catch(()=>({}));
    const token=String(body?.token||'');
    if(!/^[0-9a-f]{32}$/.test(token))return reply(404,{error:'This link is not valid'});
    const r=await db.rpc('lwb_cdoc_share_open',{p_token:token});
    if(r.error)throw Error('Could not read the link');
    const s=r.data;
    if(!s)return reply(404,{error:'This link is not valid'});
    if(s.stopped)return reply(410,{error:s.revoked?'This link was stopped by the sender.':'This link has expired.',expires_at:s.expires_at});
    const files=Array.isArray(s.files)?s.files:[];
    const paths=files.map((f:any)=>String(f.path||'')).filter((p:string)=>/^COMPANY\/\d+\/(FILE|SHARE)\//.test(p));
    const signed=paths.length?await db.storage.from('lwb-documents').createSignedUrls(paths,900):{data:[],error:null};
    if(signed.error)throw Error('Could not open the files');
    const url=new Map((signed.data||[]).filter((x:any)=>x.signedUrl).map((x:any)=>[x.path,x.signedUrl]));
    return reply(200,{party_name:s.party_name||'',by_name:s.by_name||'',expires_at:s.expires_at,created_at:s.created_at,
      files:files.filter((f:any)=>url.has(f.path)).map((f:any)=>({name:String(f.name||'Document').slice(0,120),
        mime:f.mime==='application/pdf'?'application/pdf':'image/jpeg',url:url.get(f.path)}))});
  }catch(e){
    console.error('lwb-doc-share failed:',String((e as Error)?.message||'error').slice(0,120));
    return reply(500,{error:'Could not open the documents. Try again in a minute.'});
  }
});
