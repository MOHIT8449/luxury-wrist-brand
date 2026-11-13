package com.luxurywristbrand.erp;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.text.InputType;
import android.widget.*;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Explicit start from a visible Activity: location FGS continues when Chrome is backgrounded. */
public final class DriverTrackingActivity extends Activity {
    private int attemptId=0;
    private TextView status; private EditText email,password; private Button start;
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setPadding(32,48,32,24);
        TextView title=new TextView(this);title.setText("Driver GPS · Luxury Wrist Brand");title.setTextSize(22);root.addView(title);
        status=new TextView(this);status.setText("Sign in with your driver email and password, then Start shift GPS. Location is shared with Admin, Sales Head, Godown Manager and Accounts during configured work hours, including when the screen is off. A notification stays visible. Stop here or from the notification at shift end. This GPS login is separate from the ERP browser login.");root.addView(status);
        email=new EditText(this);email.setHint("Driver email");email.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS);root.addView(email);
        password=new EditText(this);password.setHint("Driver password");password.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_PASSWORD);root.addView(password);
        start=new Button(this);start.setText("Start shift GPS");root.addView(start);start.setOnClickListener(v->begin());
        Button stop=new Button(this);stop.setText("Stop GPS and clear GPS login");root.addView(stop);
        stop.setOnClickListener(v->{attemptId++;start.setEnabled(true);stopService(new Intent(this,DriverLocationService.class));worker.execute(()->{new TrackingApi(this).clear();runOnUiThread(()->status.setText("GPS stopped. Native driver session cleared."));});});
        Button erp=new Button(this);erp.setText("Return to ERP");root.addView(erp);
        erp.setOnClickListener(v->{startActivity(new Intent(this,com.google.androidbrowserhelper.trusted.LauncherActivity.class));finish();});
        setContentView(root);
    }
    private void begin() {
        if(checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)!=PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.ACCESS_COARSE_LOCATION,Manifest.permission.ACCESS_FINE_LOCATION},11);return;
        }
        if(Build.VERSION.SDK_INT>=33&&checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS},12);return;
        }
        String e=email.getText().toString().trim(),p=password.getText().toString();
        if(e.isEmpty()||p.isEmpty()){status.setText("Enter your driver email and password.");return;}
        final int attempt=++attemptId;
        start.setEnabled(false);status.setText("Checking driver login…");
        worker.execute(()->{
            try {
                new TrackingApi(this).login(e,p);
                runOnUiThread(()->{
                    if(attempt!=attemptId||isDestroyed())return;
                    start.setEnabled(true);password.setText("");
                    if(isFinishing()||!hasWindowFocus()){status.setText("Return to this screen and tap Start again.");return;}
                    try {
                        Intent i=new Intent(this,DriverLocationService.class);
                        if(Build.VERSION.SDK_INT>=26)startForegroundService(i);else startService(i);
                        status.setText("GPS started. Check the GPS notification for live status. Stop GPS before changing driver or signing out of the ERP.");
                    }catch(RuntimeException ex){status.setText("Could not start GPS. Keep this screen open, check location permission, then retry.");}
                });
            }catch(Exception ex){runOnUiThread(()->{if(attempt!=attemptId||isDestroyed())return;start.setEnabled(true);password.setText("");status.setText("GPS not started: "+ex.getMessage());});}
        });
    }
    @Override public void onRequestPermissionsResult(int request,String[] permissions,int[] grants) {
        super.onRequestPermissionsResult(request,permissions,grants);
        status.setText("Permissions updated. Precise location and notifications are needed. Tap Start shift GPS to continue.");
    }
    @Override protected void onDestroy(){worker.shutdown();super.onDestroy();}
}
