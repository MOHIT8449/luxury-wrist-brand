package com.luxurywristbrand.erp;

import android.Manifest;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;

/** After phone restart or app update: start location sharing again without opening the app. */
public final class BootReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context c, Intent intent) {
        String a=intent.getAction();
        if(!Intent.ACTION_BOOT_COMPLETED.equals(a)&&!Intent.ACTION_MY_PACKAGE_REPLACED.equals(a))return;
        TrackingApi api=new TrackingApi(c);
        if(!api.hasSession()||!api.tracked())return;
        if(c.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)!=PackageManager.PERMISSION_GRANTED)return;
        // Android allows a background location start only with "Allow all the time".
        if(Build.VERSION.SDK_INT>=29&&c.checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION)!=PackageManager.PERMISSION_GRANTED)return;
        try {
            Intent i=new Intent(c,DriverLocationService.class);
            if(Build.VERSION.SDK_INT>=26)c.startForegroundService(i);else c.startService(i);
        } catch(RuntimeException ignored) {} // The app starts it on next open.
    }
}
