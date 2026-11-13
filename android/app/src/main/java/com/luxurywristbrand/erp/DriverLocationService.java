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

/**
 * Staff location sharing (every active login except Admin). There is no Stop
 * button for staff: it stops only when the server says this login is not
 * tracked (Admin, inactive or removed user). If the phone's location is
 * switched off or permission is removed, Admin sees "Location off" and the
 * app asks again on every open (DriverTrackingActivity).
 */
public final class DriverLocationService extends Service implements LocationListener {
    private static final int NOTICE=406,ALERT=407;
    private LocationManager locations;
    private TrackingApi api;
    private final ScheduledExecutorService network=Executors.newSingleThreadScheduledExecutor();
    private final Handler main=new Handler(Looper.getMainLooper());
    private final AtomicBoolean sending=new AtomicBoolean();
    private volatile Location last;
    private volatile boolean destroyed=false,permitted=false;
    private volatile long lastSent=0,lastChecked=0,lastOffSent=0;

    private PowerManager.WakeLock wake;
    private PendingIntent openGate(){
        Intent open=new Intent(this,DriverTrackingActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        return PendingIntent.getActivity(this,0,open,PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_UPDATE_CURRENT);
    }
    private Notification notification(String text) {
        Notification.Builder b=Build.VERSION.SDK_INT>=26?new Notification.Builder(this,"driver-gps"):new Notification.Builder(this);
        return b.setSmallIcon(com.luxurywristbrand.erp.R.drawable.ic_notification).setContentTitle("LWB · Location sharing")
            .setContentText(text).setContentIntent(openGate()).setOngoing(true).build();
    }
    private void show(String text){if(!destroyed)getSystemService(NotificationManager.class).notify(NOTICE,notification(text));}
    /** Loud reminder when location is off or permission is gone. Tapping it opens the setup popup. */
    private void alert(String text){
        Notification.Builder b=Build.VERSION.SDK_INT>=26?new Notification.Builder(this,"gps-alert"):new Notification.Builder(this);
        getSystemService(NotificationManager.class).notify(ALERT,b.setSmallIcon(com.luxurywristbrand.erp.R.drawable.ic_notification)
            .setContentTitle("Turn on location").setContentText(text).setContentIntent(openGate()).setAutoCancel(true).build());
    }
    private void clearAlert(){getSystemService(NotificationManager.class).cancel(ALERT);}
    /** Tell Admin the phone's location is off (rate-limited). */
    private void reportOff(String status){
        long now=SystemClock.elapsedRealtime();
        if(now-lastOffSent<60000&&lastOffSent!=0)return;
        lastOffSent=now;
        network.execute(()->{try{api.rpc("lwb_driver_track_ping",new JSONObject().put("p_lat",JSONObject.NULL).put("p_lng",JSONObject.NULL).put("p_status",status));}catch(Exception ignored){}});
    }
    @Override public void onCreate() {
        super.onCreate();api=new TrackingApi(this);
        if(Build.VERSION.SDK_INT>=26){
            NotificationManager nm=getSystemService(NotificationManager.class);
            nm.createNotificationChannel(new NotificationChannel("driver-gps","Location sharing",NotificationManager.IMPORTANCE_LOW));
            nm.createNotificationChannel(new NotificationChannel("gps-alert","Location off reminder",NotificationManager.IMPORTANCE_HIGH));
        }
        try{startForeground(NOTICE,notification("Checking login and work hours…"));}
        catch(RuntimeException ex){destroyed=true;stopSelf();return;} // Android refused a background start; the app starts it on next open.
        locations=(LocationManager)getSystemService(LOCATION_SERVICE);
        wake=((PowerManager)getSystemService(POWER_SERVICE)).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"lwb:staff-gps");
        wake.setReferenceCounted(false);
        network.scheduleWithFixedDelay(()->tick(),0,30,TimeUnit.SECONDS);
    }
    @Override public int onStartCommand(Intent intent,int flags,int id) {
        if(!destroyed)network.execute(()->{api=new TrackingApi(this);lastChecked=0;lastSent=0;});
        // Sticky: Android restarts it after killing it. Boot and app open also start it.
        return START_STICKY;
    }
    private void listen(boolean enabled) {
        main.post(()->{
            if(destroyed)return;
            locations.removeUpdates(this);
            if(!enabled)return;
            if(checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)!=PackageManager.PERMISSION_GRANTED){
                reportOff("DENIED");alert("Location permission was removed. Open the app and allow it.");show("Location permission removed");return;
            }
            try {
                boolean provider=false;
                for(String p:new String[]{LocationManager.GPS_PROVIDER,LocationManager.NETWORK_PROVIDER})
                    if(locations.isProviderEnabled(p)){locations.requestLocationUpdates(p,25000,0,this,Looper.getMainLooper());provider=true;}
                if(!provider){reportOff("OFF");alert("Phone location is off. Turn it on.");show("Phone location is off");}
                else clearAlert();
            }catch(SecurityException ex){reportOff("DENIED");alert("Location permission was removed. Open the app and allow it.");}
        });
    }
    private void tick() {
        if(destroyed)return;
        try {
            wake.acquire(25000);
            long now=SystemClock.elapsedRealtime();
            if(now-lastChecked>60000||lastChecked==0){
                JSONObject me=api.rpc("lwb_track_me",new JSONObject());lastChecked=now;
                if(!me.optBoolean("tracked")){api.setTracked(false);stopSelf();return;} // Admin, inactive or removed login
                boolean inHours=me.optBoolean("in_hours");
                permitted=inHours;listen(inHours);
                if(!inHours){last=null;show("Outside work hours · paused");return;}
            }
            if(!permitted)return;
            Location fix=last;
            if(fix==null||SystemClock.elapsedRealtimeNanos()-fix.getElapsedRealtimeNanos()>90000000000L){show("Waiting for a fresh GPS fix");return;}
            if(now-lastSent<25000||!sending.compareAndSet(false,true))return;
            try {
                JSONObject body=new JSONObject().put("p_lat",fix.getLatitude()).put("p_lng",fix.getLongitude())
                    .put("p_accuracy",fix.getAccuracy()).put("p_status","ON")
                    .put("p_speed_kmph",fix.hasSpeed()?fix.getSpeed()*3.6:JSONObject.NULL)
                    .put("p_heading",fix.hasBearing()?fix.getBearing():JSONObject.NULL);
                JSONObject r=api.rpc("lwb_driver_track_ping",body);
                if(!r.optBoolean("tracked")){api.setTracked(false);stopSelf();return;}
                if(!r.optBoolean("in_hours")){permitted=false;listen(false);show("Outside work hours · paused");return;}
                lastSent=now;lastOffSent=0;show("Location shared with Admin · "+new java.text.SimpleDateFormat("HH:mm",java.util.Locale.US).format(new java.util.Date()));
            }finally{sending.set(false);}
        } catch(TrackingApi.HttpError ex) {
            // Expired login: keep the service, ask the person to open the app and sign in again.
            if(ex.status==400||ex.status==401||ex.status==403){api.clear();alert("Login expired. Open the app and sign in.");show("Login expired · open the app");stopSelf();}
            else show("No internet · retrying");
        } catch(Exception ex){show("No internet · retrying");}
        finally{if(wake!=null&&wake.isHeld())wake.release();}
    }
    @Override public void onLocationChanged(Location location){last=new Location(location);}
    @Override public void onProviderEnabled(String provider){lastChecked=0;clearAlert();}
    @Override public void onProviderDisabled(String provider){lastChecked=0;}
    @Override public void onStatusChanged(String provider,int status,Bundle extras){}
    @Override public IBinder onBind(Intent intent){return null;}
    @Override public void onDestroy(){destroyed=true;permitted=false;main.removeCallbacksAndMessages(null);if(locations!=null)locations.removeUpdates(this);network.shutdownNow();if(wake!=null&&wake.isHeld())wake.release();stopForeground(true);super.onDestroy();}
}
