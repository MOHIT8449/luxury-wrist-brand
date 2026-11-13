package com.luxurywristbrand.erp;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.location.LocationManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.text.InputType;
import android.view.Gravity;
import android.widget.*;
import org.json.JSONObject;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * App launcher and location gate. Every open checks: signed in, agreed once,
 * location permission ("Allow all the time"), notifications and phone location on.
 * Anything missing shows a popup that cannot be skipped. When everything is fine
 * the location service is started (from this visible screen, as Android requires)
 * and the ERP opens. Admin logins are never tracked and go straight to the ERP.
 */
public final class DriverTrackingActivity extends Activity {
    private static final int REQ_FINE=11,REQ_BG=12,REQ_NOTIFY=13;
    private int attemptId=0;
    private TextView status; private EditText email,password; private Button agree; private CheckBox tick;
    private LinearLayout form;
    private AlertDialog dialog;
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private TrackingApi api;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        api=new TrackingApi(this);
        int pad=(int)(16*getResources().getDisplayMetrics().density);
        ScrollView scroll=new ScrollView(this);
        LinearLayout root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setPadding(pad,pad,pad,pad);
        scroll.addView(root);
        TextView title=new TextView(this);title.setText("Luxury Wrist Brand · Location");title.setTextSize(20);root.addView(title);
        status=new TextView(this);status.setPadding(0,pad/2,0,pad/2);root.addView(status);

        form=new LinearLayout(this);form.setOrientation(LinearLayout.VERTICAL);root.addView(form);
        TextView notice=new TextView(this);
        notice.setText("This company app shares your phone location with Admin during work hours, also when the app is closed or the screen is off. "
            +"A notification stays visible while it is shared. It cannot be switched off from this phone. "
            +"If location is turned off, the app will ask you again every time it opens.\n\n"
            +"यह कंपनी ऐप काम के समय में आपकी लोकेशन Admin को भेजता है, ऐप बंद हो या स्क्रीन बंद हो तब भी। लोकेशन बंद करने पर ऐप हर बार खुलते समय फिर से पूछेगा।");
        form.addView(notice);
        tick=new CheckBox(this);tick.setText("I agree / मैं सहमत हूँ");form.addView(tick);
        email=new EditText(this);email.setHint("ERP email");email.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS);form.addView(email);
        password=new EditText(this);password.setHint("ERP password");password.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_PASSWORD);form.addView(password);
        agree=new Button(this);agree.setText("Agree and continue");form.addView(agree);agree.setOnClickListener(v->signIn());

        LinearLayout row=new LinearLayout(this);row.setOrientation(LinearLayout.HORIZONTAL);row.setGravity(Gravity.END);root.addView(row);
        Button change=new Button(this);change.setText("Change login");change.setOnClickListener(v->{form.setVisibility(LinearLayout.VISIBLE);status.setText("Sign in with the new staff login. Location then goes with the new login.");});
        row.addView(change);
        setContentView(scroll);
    }

    @Override protected void onResume(){super.onResume();check();}

    /** The gate: runs on every open and after every permission answer. */
    private void check(){
        if(dialog!=null&&dialog.isShowing())dialog.dismiss();
        if(!api.hasSession()||!api.agreed()&&api.tracked()){
            form.setVisibility(LinearLayout.VISIBLE);
            status.setText("Sign in once with your ERP login and agree to location sharing.");
            return;
        }
        form.setVisibility(LinearLayout.GONE);
        if(!api.tracked()){openErp();return;} // Admin: never tracked
        if(checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)!=PackageManager.PERMISSION_GRANTED){
            popup("Allow location","Location permission is needed to use the app. Choose \"Precise\" and \"While using the app\".\n\nऐप चलाने के लिए लोकेशन की अनुमति दें।","Allow",
                ()->{if(shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_FINE_LOCATION)||!asked("fine"))
                        requestPermissions(new String[]{Manifest.permission.ACCESS_COARSE_LOCATION,Manifest.permission.ACCESS_FINE_LOCATION},REQ_FINE);
                     else appSettings();});
            return;
        }
        if(Build.VERSION.SDK_INT>=29&&checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION)!=PackageManager.PERMISSION_GRANTED){
            popup("Allow all the time","On the next screen choose \"Allow all the time\" so location works when the app is closed.\n\nअगली स्क्रीन पर \"Allow all the time\" चुनें।","Open",
                ()->{if(!asked("bg"))requestPermissions(new String[]{Manifest.permission.ACCESS_BACKGROUND_LOCATION},REQ_BG);else appSettings();});
            return;
        }
        if(Build.VERSION.SDK_INT>=33&&checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED){
            popup("Allow notifications","Notifications are needed to show that location is being shared.\n\nनोटिफिकेशन की अनुमति दें।","Allow",
                ()->{if(!asked("notify"))requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS},REQ_NOTIFY);else appSettings();});
            return;
        }
        if(!locationOn()){
            popup("Turn on location","Phone location (GPS) is off. Turn it on to use the app.\n\nफ़ोन की लोकेशन (GPS) बंद है। ऐप चलाने के लिए चालू करें।","Turn on",
                ()->startActivity(new Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)));
            return;
        }
        try {
            Intent i=new Intent(this,DriverLocationService.class);
            if(Build.VERSION.SDK_INT>=26)startForegroundService(i);else startService(i);
        }catch(RuntimeException ex){status.setText("Could not start location. Close and open the app again.");return;}
        openErp();
    }

    private boolean asked(String key){
        boolean was=getSharedPreferences("gps-gate",0).getBoolean(key,false);
        getSharedPreferences("gps-gate",0).edit().putBoolean(key,true).apply();
        return was;
    }
    private boolean locationOn(){
        LocationManager lm=(LocationManager)getSystemService(LOCATION_SERVICE);
        if(Build.VERSION.SDK_INT>=28)return lm.isLocationEnabled();
        return lm.isProviderEnabled(LocationManager.GPS_PROVIDER)||lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER);
    }
    private void appSettings(){
        startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,Uri.fromParts("package",getPackageName(),null)));
    }
    /** One button, no Skip. Back closes the app; the popup comes again on next open. */
    private void popup(String title,String text,String button,Runnable action){
        status.setText(title);
        dialog=new AlertDialog.Builder(this).setTitle(title).setMessage(text).setCancelable(false)
            .setPositiveButton(button,(d,w)->action.run()).create();
        dialog.setOnKeyListener((d,code,ev)->{if(code==android.view.KeyEvent.KEYCODE_BACK){finish();return true;}return false;});
        dialog.show();
    }
    private void openErp(){
        startActivity(new Intent(this,com.google.androidbrowserhelper.trusted.LauncherActivity.class));
        finish();
    }

    private void signIn() {
        if(!tick.isChecked()){status.setText("Tick \"I agree\" to continue.");return;}
        String e=email.getText().toString().trim(),p=password.getText().toString();
        if(e.isEmpty()||p.isEmpty()){status.setText("Enter your ERP email and password.");return;}
        final int attempt=++attemptId;
        agree.setEnabled(false);status.setText("Checking login…");
        worker.execute(()->{
            try {
                JSONObject me=api.login(e,p);
                if(me.optBoolean("tracked"))
                    api.rpc("lwb_gps_agree",new JSONObject().put("p_device",Build.MANUFACTURER+" "+Build.MODEL+" · Android "+Build.VERSION.RELEASE));
                api.setAgreed();
                runOnUiThread(()->{if(attempt!=attemptId||isDestroyed())return;agree.setEnabled(true);password.setText("");check();});
            }catch(Exception ex){runOnUiThread(()->{if(attempt!=attemptId||isDestroyed())return;agree.setEnabled(true);password.setText("");status.setText("Not signed in: "+ex.getMessage());});}
        });
    }
    @Override public void onRequestPermissionsResult(int request,String[] permissions,int[] grants) {
        super.onRequestPermissionsResult(request,permissions,grants);
        check();
    }
    @Override protected void onDestroy(){if(dialog!=null)dialog.dismiss();worker.shutdown();super.onDestroy();}
}
