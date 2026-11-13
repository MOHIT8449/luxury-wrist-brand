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

/** Independent native staff session for location sharing. Never takes credentials from an intent or WebView. */
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
    /** Anonymous RPC whose answer is a plain JSON value (e.g. a text). */
    private String requestText(String path, JSONObject body) throws Exception {
        HttpURLConnection c=(HttpURLConnection)new URL(HOST+path).openConnection();
        try {
            c.setConnectTimeout(15000); c.setReadTimeout(15000); c.setRequestMethod("POST");
            c.setRequestProperty("apikey",KEY);
            c.setRequestProperty("Content-Type","application/json"); c.setDoOutput(true);
            try(java.io.OutputStream out=c.getOutputStream()){out.write(body.toString().getBytes(StandardCharsets.UTF_8));}
            int code=c.getResponseCode();
            if(code<200||code>=300)throw new HttpError(code);
            try(java.io.InputStream in=c.getInputStream(); java.io.ByteArrayOutputStream out=new java.io.ByteArrayOutputStream()) {
                byte[] b=new byte[4096]; int n; while((n=in.read(b))!=-1)out.write(b,0,n);
                return out.toString("UTF-8");
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
    /** Any active staff login. Returns lwb_track_me: tracked=false for Admin (never tracked). */
    /** 10-digit Indian mobile (with or without +91 / 0), else null. Same rule as login.html. */
    static String mobile(String raw) {
        String d=raw.replaceAll("[^0-9]","");
        if(d.length()==12&&d.startsWith("91"))d=d.substring(2);
        if(d.length()==11&&d.startsWith("0"))d=d.substring(1);
        return d.matches("[6-9][0-9]{9}")?d:null;
    }
    synchronized JSONObject login(String login,String password) throws Exception {
        String email=login.trim();
        if(!email.contains("@")) {
            // Mobile login, as on the ERP website: the database gives the login email only for the right password.
            String m=mobile(email);
            if(m==null)throw new Exception("Enter a valid 10-digit mobile number or your email");
            String found;
            try { found=requestText("/rest/v1/rpc/lwb_login_email",new JSONObject().put("p_login",m).put("p_password",password)); }
            catch(HttpError ex){ throw new Exception("Mobile login is not set up for this user. Use your email, or ask Admin."); }
            found=found==null?"":found.trim();
            if(found.startsWith("\"")&&found.endsWith("\""))found=found.substring(1,found.length()-1);
            if(found.isEmpty()||"null".equals(found))throw new Exception("Wrong mobile number or password");
            email=found;
        }
        JSONObject next;
        try { next=request("/auth/v1/token?grant_type=password",new JSONObject().put("email",email).put("password",password),null); }
        catch(HttpError ex){ if(ex.status==400)throw new Exception("Wrong login or password"); throw ex; }
        JSONObject me=request("/rest/v1/rpc/lwb_track_me",new JSONObject(),next.getString("access_token"));
        if(me.optString("role").isEmpty())throw new Exception("This login is not an active ERP staff login");
        clear();
        save(next);
        context.getSharedPreferences("driver-gps",0).edit().putBoolean("tracked",me.optBoolean("tracked")).commit();
        return me;
    }
    boolean hasSession() { return !context.getSharedPreferences("driver-gps",0).getString("session","").isEmpty(); }
    boolean tracked() { return context.getSharedPreferences("driver-gps",0).getBoolean("tracked",true); }
    boolean agreed() { return context.getSharedPreferences("driver-gps",0).getBoolean("agreed",false); }
    void setTracked(boolean v) { context.getSharedPreferences("driver-gps",0).edit().putBoolean("tracked",v).commit(); }
    void setAgreed() { context.getSharedPreferences("driver-gps",0).edit().putBoolean("agreed",true).commit(); }
    synchronized JSONObject rpc(String name,JSONObject body) throws Exception {
        load();
        if(session.optLong("expires_at")*1000L<System.currentTimeMillis()+60000L)
            save(request("/auth/v1/token?grant_type=refresh_token",new JSONObject().put("refresh_token",session.getString("refresh_token")),null));
        return request("/rest/v1/rpc/"+name,body,session.getString("access_token"));
    }
    synchronized void clear() { session=null; context.getSharedPreferences("driver-gps",0).edit().clear().commit(); }
}
