package com.luxurywristbrand.erp;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.location.*;
import android.os.*;
import org.json.JSONObject;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

public final class DriverLocationService extends Service implements LocationListener {
    private static final int NOTICE=406;
    private LocationManager locations;
    private TrackingApi api;
    private final ScheduledExecutorService network=Executors.newSingleThreadScheduledExecutor();
    private final Handler main=new Handler(Looper.getMainLooper());
    private final AtomicBoolean sending=new AtomicBoolean();
    private volatile Location last;
    private volatile boolean destroyed=false,permitted=false;
    private volatile long lastSent=0,lastChecked=0;
    private PowerManager.WakeLock wake;
    private Notification notification(String text) {
        Intent open=new Intent(this,DriverTrackingActivity.class);
        PendingIntent content=PendingIntent.getActivity(this,0,open,PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_UPDATE_CURRENT);
        Intent stop=new Intent(this,DriverLocationService.class).setAction("STOP");
        PendingIntent action=PendingIntent.getService(this,1,stop,PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_UPDATE_CURRENT);
        Notification.Builder b=Build.VERSION.SDK_INT>=26?new Notification.Builder(this,"driver-gps"):new Notification.Builder(this);
        return b.setSmallIcon(com.luxurywristbrand.erp.R.drawable.ic_notification).setContentTitle("LWB · Driver GPS")
            .setContentText(text).setContentIntent(content).setOngoing(true)
            .addAction(new Notification.Action.Builder(null,"Stop GPS",action).build()).build();
    }
    private void show(String text){if(!destroyed)getSystemService(NotificationManager.class).notify(NOTICE,notification(text));}
    @Override public void onCreate() {
        super.onCreate();api=new TrackingApi(this);
        if(Build.VERSION.SDK_INT>=26)getSystemService(NotificationManager.class).createNotificationChannel(new NotificationChannel("driver-gps","Driver location sharing",NotificationManager.IMPORTANCE_LOW));
        startForeground(NOTICE,notification("Checking driver and work hours…"));
        locations=(LocationManager)getSystemService(LOCATION_SERVICE);
        wake=((PowerManager)getSystemService(POWER_SERVICE)).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"lwb:driver-gps");
        wake.setReferenceCounted(false);
        network.scheduleWithFixedDelay(()->tick(),0,30,TimeUnit.SECONDS);
    }
    @Override public int onStartCommand(Intent intent,int flags,int id) {
        if(intent!=null&&"STOP".equals(intent.getAction())){stopSelf();new Thread(()->api.clear()).start();}
        else network.execute(()->{api=new TrackingApi(this);lastChecked=0;lastSent=0;});
        // No background/reboot auto-start: Android requires the driver to start from a visible screen.
        return START_NOT_STICKY;
    }
    private void listen(boolean enabled) {
        main.post(()->{
            if(destroyed)return;
            locations.removeUpdates(this);
            if(!enabled)return;
            if(checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)!=PackageManager.PERMISSION_GRANTED){show("Location permission removed. Open GPS setup.");stopSelf();return;}
            try {
                boolean provider=false;
                for(String p:new String[]{LocationManager.GPS_PROVIDER,LocationManager.NETWORK_PROVIDER})
                    if(locations.isProviderEnabled(p)){locations.requestLocationUpdates(p,25000,0,this,Looper.getMainLooper());provider=true;}
                if(!provider)show("Phone location is off. Turn it on to share GPS.");
            }catch(SecurityException ex){show("Location permission removed. Open GPS setup.");stopSelf();}
        });
    }
    private void tick() {
        if(destroyed)return;
        try {
            wake.acquire(25000);
            long now=SystemClock.elapsedRealtime();
            if(now-lastChecked>60000||lastChecked==0){
                JSONObject me=api.rpc("lwb_track_me",new JSONObject());lastChecked=now;
                if(!"driver".equals(me.optString("role"))||!me.optBoolean("tracked")){api.clear();stopSelf();return;}
                boolean inHours=me.optBoolean("in_hours");
                permitted=inHours;listen(inHours);
                if(!inHours){last=null;show("Outside work hours · GPS paused");return;}
            }
            if(!permitted)return;
            Location fix=last;
            if(fix==null||SystemClock.elapsedRealtimeNanos()-fix.getElapsedRealtimeNanos()>90000000000L){show("Waiting for a fresh GPS fix · check phone location");return;}
            if(now-lastSent<25000||!sending.compareAndSet(false,true))return;
            try {
                JSONObject body=new JSONObject().put("p_lat",fix.getLatitude()).put("p_lng",fix.getLongitude())
                    .put("p_accuracy",fix.getAccuracy()).put("p_status","ON")
                    .put("p_speed_kmph",fix.hasSpeed()?fix.getSpeed()*3.6:JSONObject.NULL)
                    .put("p_heading",fix.hasBearing()?fix.getBearing():JSONObject.NULL);
                JSONObject r=api.rpc("lwb_driver_track_ping",body);
                if(!r.optBoolean("tracked")){api.clear();stopSelf();return;}
                if(!r.optBoolean("in_hours")){permitted=false;listen(false);show("Outside work hours · GPS paused");return;}
                lastSent=now;show("Location shared · "+new java.text.SimpleDateFormat("HH:mm",java.util.Locale.US).format(new java.util.Date()));
            }finally{sending.set(false);}
        } catch(TrackingApi.HttpError ex) {
            if(ex.status==400||ex.status==401||ex.status==403){api.clear();show("GPS login expired. Open GPS setup.");stopSelf();}
            else show("Connection unavailable · retrying fresh GPS");
        } catch(Exception ex){show("Connection unavailable · retrying fresh GPS");}
        finally{if(wake.isHeld())wake.release();}
    }
    @Override public void onLocationChanged(Location location){last=new Location(location);}
    @Override public void onProviderEnabled(String provider){lastChecked=0;}
    @Override public void onProviderDisabled(String provider){show("Location provider off · check phone GPS");}
    @Override public void onStatusChanged(String provider,int status,Bundle extras){}
    @Override public IBinder onBind(Intent intent){return null;}
    @Override public void onDestroy(){destroyed=true;permitted=false;main.removeCallbacksAndMessages(null);locations.removeUpdates(this);network.shutdownNow();if(wake.isHeld())wake.release();stopForeground(true);super.onDestroy();}
}
