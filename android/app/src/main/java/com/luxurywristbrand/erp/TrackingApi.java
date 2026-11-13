package com.luxurywristbrand.erp;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import org.json.JSONObject;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** Independent native driver session. Never takes credentials from an intent or WebView. */
final class TrackingApi {
    private static final String HOST="https://txkbhadzdbxpieunfvox.supabase.co";
    private static final String KEY="sb_publishable_W4I3Q5ODf0g17sq5uDml2Q_sLolXYEk";
    private final Context context;
    private JSONObject session;
    TrackingApi(Context c) { context=c.getApplicationContext(); }
    static final class HttpError extends Exception {
        final int status;
        HttpError(int s) { super("Server request failed ("+s+")"); status=s; }
    }
    private JSONObject request(String path, JSONObject body, String token) throws Exception {
        HttpURLConnection c=(HttpURLConnection)new URL(HOST+path).openConnection();
        try {
            c.setConnectTimeout(15000); c.setReadTimeout(15000); c.setRequestMethod("POST");
            c.setRequestProperty("apikey",KEY); c.setRequestProperty("Content-Type","application/json");
            if(token!=null)c.setRequestProperty("Authorization","Bearer "+token);
            c.setDoOutput(true);
            try(java.io.OutputStream out=c.getOutputStream()){out.write(body.toString().getBytes(StandardCharsets.UTF_8));}
            int code=c.getResponseCode();
            if(code<200||code>=300)throw new HttpError(code);
            try(java.io.InputStream in=c.getInputStream(); java.io.ByteArrayOutputStream out=new java.io.ByteArrayOutputStream()) {
                byte[] b=new byte[4096]; int n; while((n=in.read(b))!=-1)out.write(b,0,n);
                String text=out.toString("UTF-8"); return text.isEmpty()?new JSONObject():new JSONObject(text);
            }
        } finally { c.disconnect(); }
    }
    private SecretKey key() throws Exception {
        KeyStore ks=KeyStore.getInstance("AndroidKeyStore"); ks.load(null);
        if(!ks.containsAlias("lwb-driver-session")) {
            KeyGenerator g=KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore");
            g.init(new KeyGenParameterSpec.Builder("lwb-driver-session",KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
            g.generateKey();
        }
        return (SecretKey)ks.getKey("lwb-driver-session",null);
    }
    private void save(JSONObject value) throws Exception {
        if(!value.has("expires_at"))value.put("expires_at",System.currentTimeMillis()/1000L+value.optLong("expires_in",3600));
        Cipher c=Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.ENCRYPT_MODE,key());
        String encoded=Base64.encodeToString(c.getIV(),Base64.NO_WRAP)+":"+
            Base64.encodeToString(c.doFinal(value.toString().getBytes(StandardCharsets.UTF_8)),Base64.NO_WRAP);
        if(!context.getSharedPreferences("driver-gps",0).edit().putString("session",encoded).commit())throw new Exception("Could not save driver session");
        session=value;
    }
    private void load() throws Exception {
        if(session!=null)return;
        String raw=context.getSharedPreferences("driver-gps",0).getString("session","");
        if(raw.isEmpty())throw new HttpError(401);
        String[] parts=raw.split(":");
        Cipher c=Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.DECRYPT_MODE,key(),new GCMParameterSpec(128,Base64.decode(parts[0],Base64.NO_WRAP)));
        session=new JSONObject(new String(c.doFinal(Base64.decode(parts[1],Base64.NO_WRAP)),StandardCharsets.UTF_8));
    }
    synchronized void login(String email,String password) throws Exception {
        JSONObject next=request("/auth/v1/token?grant_type=password",new JSONObject().put("email",email).put("password",password),null);
        JSONObject me=request("/rest/v1/rpc/lwb_track_me",new JSONObject(),next.getString("access_token"));
        if(!"driver".equals(me.optString("role"))||!me.optBoolean("tracked"))throw new Exception("An active, tracking-enabled driver login is required");
        save(next);
    }
    synchronized JSONObject rpc(String name,JSONObject body) throws Exception {
        load();
        if(session.optLong("expires_at")*1000L<System.currentTimeMillis()+60000L)
            save(request("/auth/v1/token?grant_type=refresh_token",new JSONObject().put("refresh_token",session.getString("refresh_token")),null));
        return request("/rest/v1/rpc/"+name,body,session.getString("access_token"));
    }
    synchronized void clear() { session=null; context.getSharedPreferences("driver-gps",0).edit().clear().commit(); }
}
