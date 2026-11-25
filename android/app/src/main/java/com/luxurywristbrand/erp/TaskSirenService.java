package com.luxurywristbrand.erp;

import android.app.*;
import android.content.Context;
import android.content.Intent;
import android.os.*;
import java.util.concurrent.*;

/**
 * Urgent task alarm watcher for logins whose location is not shared (Admin). Staff phones already run
 * DriverLocationService, which does the same check every minute, so this one is not started for them.
 * Checks lwb_task_my_sirens once a minute; SirenAlarm rings when an urgent task rings.
 */
public final class TaskSirenService extends Service {
    private static final int NOTICE=409;
    private final ScheduledExecutorService network=Executors.newSingleThreadScheduledExecutor();
    private PowerManager.WakeLock wake;
    private volatile boolean destroyed=false;

    static void start(Context c){
        try{
            Intent i=new Intent(c,TaskSirenService.class);
            if(Build.VERSION.SDK_INT>=26)c.startForegroundService(i);else c.startService(i);
        }catch(RuntimeException ignored){} // Android refused a background start; the app starts it on next open
    }

    @Override public void onCreate(){
        super.onCreate();
        if(Build.VERSION.SDK_INT>=26)
            getSystemService(NotificationManager.class).createNotificationChannel(
                new NotificationChannel("task-siren-watch","Urgent task alarm (on)",NotificationManager.IMPORTANCE_MIN));
        SirenAlarm.channel(this);
        Notification.Builder b=Build.VERSION.SDK_INT>=26?new Notification.Builder(this,"task-siren-watch"):new Notification.Builder(this);
        Intent open=new Intent(this,DriverTrackingActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        b.setSmallIcon(R.drawable.ic_notification).setContentTitle("LWB · Urgent task alarm is on")
            .setContentText("Rings for URGENT tasks, 9 AM - 8 PM")
            .setContentIntent(PendingIntent.getActivity(this,1,open,PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_UPDATE_CURRENT))
            .setOngoing(true);
        try{startForeground(NOTICE,b.build());}
        catch(RuntimeException ex){destroyed=true;stopSelf();return;}
        wake=((PowerManager)getSystemService(POWER_SERVICE)).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"lwb:task-siren");
        wake.setReferenceCounted(false);
        network.scheduleWithFixedDelay(this::tick,0,60,TimeUnit.SECONDS);
    }
    private void tick(){
        if(destroyed)return;
        TrackingApi api=new TrackingApi(this);
        if(!api.hasSession()){stopSelf();return;}
        try{wake.acquire(20000);SirenAlarm.poll(this,api);}
        catch(TrackingApi.HttpError ex){if(ex.status==400||ex.status==401||ex.status==403)stopSelf();}
        catch(Exception ignored){} // no internet: try again next minute
        finally{if(wake!=null&&wake.isHeld())wake.release();}
    }
    @Override public int onStartCommand(Intent intent,int flags,int id){return START_STICKY;}
    @Override public IBinder onBind(Intent intent){return null;}
    @Override public void onDestroy(){destroyed=true;network.shutdownNow();if(wake!=null&&wake.isHeld())wake.release();stopForeground(true);super.onDestroy();}
}
