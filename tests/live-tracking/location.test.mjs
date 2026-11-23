import {test} from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
const code=await readFile(new URL('../../live-location.js',import.meta.url),'utf8');
test('browser GPS failure never republishes an old fix as a fresh position',async()=>{
 let fail=false;const sent=[];
 const ctx={window:{},document:{hidden:false,addEventListener(){}},navigator:{userAgent:'Mozilla/5.0 (Linux; Android 14) Mobile',geolocation:{watchPosition(){return 1},clearWatch(){},getCurrentPosition(ok,bad){fail?bad({code:2}):ok({coords:{latitude:21,longitude:72,accuracy:10}})}}},setInterval(){return 1},clearInterval(){},setTimeout(){},Date,Math};
 vm.createContext(ctx);vm.runInContext(code,ctx);
 await ctx.window.LWBLocation.start({rpc:async(name,args)=>{if(args)sent.push(args);return {data:{tracked:true,in_hours:true}}}});
 assert.equal((await ctx.window.LWBLocation.now()).lat,21);
 fail=true;assert.equal(await ctx.window.LWBLocation.now(),null);
 assert.equal(sent.length,1);
});
test('desktop / laptop: no location asked, nothing sent, no lock',async()=>{
 let asked=0;const calls=[];
 const ctx={window:{},document:{hidden:false,addEventListener(){}},navigator:{userAgent:'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/142',userAgentData:{mobile:false},geolocation:{watchPosition(){asked++;return 1},clearWatch(){},getCurrentPosition(){asked++}}},setInterval(){return 1},clearInterval(){},setTimeout(){},Date,Math};
 vm.createContext(ctx);vm.runInContext(code,ctx);
 await ctx.window.LWBLocation.start({rpc:async n=>{calls.push(n);return {data:{tracked:true,in_hours:true}}}});
 assert.equal(asked,0);assert.equal(calls.length,0);assert.equal(ctx.window.LWBLocation.status,'desktop');
});
