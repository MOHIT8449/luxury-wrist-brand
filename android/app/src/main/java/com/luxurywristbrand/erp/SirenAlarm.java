package com.luxurywristbrand.erp;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.media.AudioAttributes;
import android.net.Uri;
import android.os.Build;
import android.os.SystemClock;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * 🚨 Urgent task alarm (Mohit, 22 Nov 2026; lwb_task_siren_setup.sql + lwb_task_siren_native_setup.sql).
 * The server rings an URGENT task every 20 min (9 AM - 8 PM) until it is Done. The app's background
 * service calls poll() every minute; a new ring shows an alarm notification on the phone's ALARM sound
 * (rings in Silent mode, repeats until touched) that opens SirenActivity full screen over the lock screen.
 */
final class SirenAlarm {
    static final String CHANNEL="task-siren-alarm";
    static final int NOTE=408;
    static final long[] VIBE={0,1000,200,1000,200,1000,200,300,150,300,150,300,600};
    private static long lastPoll=0;

    static Uri sound(Context c){ return Uri.parse("android.resource://"+c.getPackageName()+"/"+R.raw.task_siren); }
    static AudioAttributes alarmAudio(){
        return new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build();
    }

    static void channel(Context c){
        if(Build.VERSION.SDK_INT<26)return;
        NotificationManager nm=c.getSystemService(NotificationManager.class);
        if(nm.getNotificationChannel(CHANNEL)!=null)return;
        NotificationChannel ch=new NotificationChannel(CHANNEL,"Urgent task alarm",NotificationManager.IMPORTANCE_HIGH);
        ch.setDescription("Siren + vibration for URGENT tasks, every 20 min till done (9 AM - 8 PM).");
        ch.setSound(sound(c),alarmAudio());
        ch.enableVibration(true);ch.setVibrationPattern(VIBE);
        ch.setBypassDnd(true);ch.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
        nm.createNotificationChannel(ch);
    }

    /** Checks the server at most once a minute. Network call: run it off the main thread. */
    static void poll(Context c,TrackingApi api) throws Exception {
        synchronized(SirenAlarm.class){
            long now=SystemClock.elapsedRealtime();
            if(lastPoll!=0&&now-lastPoll<55000)return;
            lastPoll=now;
        }
        String raw=api.rpcRaw("lwb_task_my_sirens",new JSONObject());
        if(raw==null||!raw.startsWith("["))return;
        JSONArray list=new JSONArray(raw);
        for(int i=0;i<list.length();i++){
            JSONObject t=list.getJSONObject(i);
            String key=t.optLong("id")+"@"+t.optInt("siren_count");
            if(rang(c,key))continue;
            remember(c,key);
            ring(c,t);
            return; // one alarm at a time; the next one comes on the next minute
        }
    }

    private static boolean rang(Context c,String key){
        return ("|"+c.getSharedPreferences("task-siren",0).getString("rang","")+"|").contains("|"+key+"|");
    }
    private static void remember(Context c,String key){
        String old=c.getSharedPreferences("task-siren",0).getString("rang","");
        String next=(key+"|"+old);
        if(next.length()>1500)next=next.substring(0,1500);
        c.getSharedPreferences("task-siren",0).edit().putString("rang",next).commit();
    }

    static Intent screen(Context c,JSONObject t){
        return new Intent(c,SirenActivity.class)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK|Intent.FLAG_ACTIVITY_CLEAR_TOP|Intent.FLAG_ACTIVITY_NO_USER_ACTION)
            .putExtra("id",t.optLong("id")).putExtra("title",t.optString("title"))
            .putExtra("details",t.optString("details",""))
            .putExtra("by",t.optString("assigned_by_name","Admin")+(t.optString("assigned_by_role","").isEmpty()?"":" ("+t.optString("assigned_by_role")+")"))
            .putExtra("count",t.optInt("siren_count",1)).putExtra("every",t.optInt("every_min",20));
    }

    static void ring(Context c,JSONObject t){
        channel(c);
        PendingIntent full=PendingIntent.getActivity(c,(int)(t.optLong("id")%100000),screen(c,t),
            PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_UPDATE_CURRENT);
        Notification.Builder b=Build.VERSION.SDK_INT>=26?new Notification.Builder(c,CHANNEL):new Notification.Builder(c);
        b.setSmallIcon(R.drawable.ic_notification).setContentTitle("🚨 URGENT task")
            .setContentText(t.optString("title")).setStyle(new Notification.BigTextStyle().bigText(t.optString("title")+"\nFrom "+t.optString("assigned_by_name","Admin")+" · tap to open"))
            .setCategory(Notification.CATEGORY_ALARM).setPriority(Notification.PRIORITY_MAX)
            .setVisibility(Notification.VISIBILITY_PUBLIC).setContentIntent(full).setFullScreenIntent(full,true)
            .setAutoCancel(true);
        if(Build.VERSION.SDK_INT<26){b.setSound(sound(c),android.media.AudioManager.STREAM_ALARM);b.setVibrate(VIBE);}
        Notification n=b.build();
        n.flags|=Notification.FLAG_INSISTENT; // sound repeats until the person touches it
        c.getSystemService(NotificationManager.class).notify(NOTE,n);
    }
}
