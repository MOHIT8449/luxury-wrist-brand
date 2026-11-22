package com.luxurywristbrand.erp;

import android.app.Activity;
import android.app.NotificationManager;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.media.AudioManager;
import android.media.MediaPlayer;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.view.Gravity;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;
import org.json.JSONObject;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Full-screen urgent task alarm (SirenAlarm). Turns the screen on over the lock screen, plays the
 * siren in a loop on the ALARM sound (so Silent mode does not stop it) and vibrates, until the person
 * taps ✅ Done (task marked done) or ⏰ Later (rings again in 20 min if not done). Stops by itself
 * after 3 minutes; the task still rings again at the next 20-minute time.
 */
public final class SirenActivity extends Activity {
    private MediaPlayer player;
    private Vibrator vibrator;
    private int oldVolume=-1;
    private final Handler main=new Handler(Looper.getMainLooper());
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private long id;
    private boolean sure=false;
    private TextView note;

    private int dp(int v){return (int)(v*getResources().getDisplayMetrics().density);}
    private Button button(String text,int bg,int fg){
        Button b=new Button(this);b.setText(text);b.setAllCaps(false);b.setTextSize(17);b.setTypeface(Typeface.DEFAULT_BOLD);
        b.setTextColor(fg);GradientDrawable d=new GradientDrawable();d.setColor(bg);d.setCornerRadius(dp(10));
        if(bg==Color.WHITE)d.setStroke(dp(2),Color.parseColor("#D5DAE0"));
        b.setBackground(d);b.setMinHeight(dp(54));
        return b;
    }

    @Override protected void onCreate(Bundle state){
        super.onCreate(state);
        if(Build.VERSION.SDK_INT>=27){setShowWhenLocked(true);setTurnScreenOn(true);}
        else getWindow().addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED|WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getSystemService(NotificationManager.class).cancel(SirenAlarm.NOTE); // its repeating sound stops; this screen rings now

        Intent in=getIntent();
        id=in.getLongExtra("id",-1);
        int every=in.getIntExtra("every",20);

        LinearLayout root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setGravity(Gravity.CENTER);
        root.setBackgroundColor(Color.parseColor("#B71C1C"));root.setPadding(dp(16),dp(16),dp(16),dp(16));
        LinearLayout card=new LinearLayout(this);card.setOrientation(LinearLayout.VERTICAL);card.setPadding(dp(16),dp(16),dp(16),dp(16));
        GradientDrawable cd=new GradientDrawable();cd.setColor(Color.WHITE);cd.setCornerRadius(dp(14));card.setBackground(cd);
        root.addView(card,new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT,LinearLayout.LayoutParams.WRAP_CONTENT));

        TextView head=new TextView(this);head.setText("🚨 URGENT TASK");head.setTextSize(22);head.setTypeface(Typeface.DEFAULT_BOLD);head.setTextColor(Color.parseColor("#C62828"));card.addView(head);
        TextView sub=new TextView(this);sub.setText(id==0?"DEMO · this is how staff phones ring":"Ring "+in.getIntExtra("count",1)+" · siren + vibration every "+every+" min till done");
        sub.setTextSize(13);sub.setTextColor(Color.parseColor("#6B7480"));sub.setPadding(0,0,0,dp(10));card.addView(sub);
        TextView title=new TextView(this);title.setText(in.getStringExtra("title"));title.setTextSize(21);title.setTypeface(Typeface.DEFAULT_BOLD);title.setTextColor(Color.parseColor("#1C232B"));card.addView(title);
        String details=in.getStringExtra("details");
        if(details!=null&&!details.isEmpty()&&!"null".equals(details)){TextView d=new TextView(this);d.setText(details);d.setTextSize(14);d.setTextColor(Color.parseColor("#4B5763"));d.setMaxLines(4);d.setPadding(0,dp(6),0,0);card.addView(d);}
        TextView meta=new TextView(this);meta.setText((id>0?"TSK-"+id+" · ":"")+"From "+in.getStringExtra("by"));meta.setTextSize(13);meta.setTextColor(Color.parseColor("#C62828"));meta.setTypeface(Typeface.DEFAULT_BOLD);meta.setPadding(0,dp(8),0,dp(14));card.addView(meta);

        LinearLayout row=new LinearLayout(this);row.setOrientation(LinearLayout.HORIZONTAL);
        Button done=button("✅ Done",Color.parseColor("#1B7F3B"),Color.WHITE);
        Button later=button("⏰ Later "+every+"m",Color.WHITE,Color.parseColor("#1C232B"));
        LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(0,LinearLayout.LayoutParams.WRAP_CONTENT,1);lp.setMarginEnd(dp(8));
        row.addView(done,lp);row.addView(later,new LinearLayout.LayoutParams(0,LinearLayout.LayoutParams.WRAP_CONTENT,1));
        card.addView(row);
        Button open=new Button(this);open.setText(id>0?"Open task in ERP":"Open ERP");open.setAllCaps(false);open.setBackgroundColor(Color.TRANSPARENT);open.setTextColor(Color.parseColor("#1A56B0"));card.addView(open);
        note=new TextView(this);note.setText("📳 Rings on Silent too. Only 9 AM - 8 PM. Stops when Done.");note.setTextSize(12);note.setGravity(Gravity.CENTER);note.setTextColor(Color.parseColor("#7A838C"));card.addView(note);
        setContentView(root);

        done.setOnClickListener(v->{
            if(!sure){sure=true;done.setText("Tap again: Done");return;}
            done.setEnabled(false);done.setText("Saving…");
            send(id==0?"lwb_task_siren_seen":"lwb_task_update",
                id==0?json("p_id",0):json("p_id",id,"p_status","DONE","p_note","Done (from the phone alarm)","p_due",JSONObject.NULL),
                "Task done. Siren stopped.",()->{done.setEnabled(true);sure=false;done.setText("✅ Done");});
        });
        later.setOnClickListener(v->send("lwb_task_siren_seen",json("p_id",id),"OK. It rings again in "+every+" min if not done.",null));
        open.setOnClickListener(v->{
            stopAlarm();
            worker.execute(()->{try{new TrackingApi(this).rpcRaw("lwb_task_siren_seen",json("p_id",id));}catch(Exception ignored){}});
            startActivity(new Intent(this,com.google.androidbrowserhelper.trusted.LauncherActivity.class)
                .setData(Uri.parse("https://luxurywristbrand.com/tasks.html"+(id>0?"?id="+id:"")))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            finish();
        });
        startAlarm();
        main.postDelayed(this::stopAlarm,180000);
    }

    private static JSONObject json(Object... kv){
        JSONObject o=new JSONObject();
        try{for(int i=0;i<kv.length;i+=2)o.put((String)kv[i],kv[i+1]);}catch(Exception ignored){}
        return o;
    }
    private void send(String rpc,JSONObject body,String ok,Runnable failed){
        stopAlarm();
        worker.execute(()->{
            String err=null;
            try{new TrackingApi(this).rpcRaw(rpc,body);}catch(Exception ex){err=ex.getMessage();}
            final String e=err;
            runOnUiThread(()->{
                if(isDestroyed())return;
                if(e==null){Toast.makeText(this,ok,Toast.LENGTH_LONG).show();finish();}
                else{note.setText("Could not save (no internet?). Try again or open the ERP.");if(failed!=null)failed.run();}
            });
        });
    }

    private void startAlarm(){
        try{
            AudioManager am=getSystemService(AudioManager.class);
            int max=am.getStreamMaxVolume(AudioManager.STREAM_ALARM),cur=am.getStreamVolume(AudioManager.STREAM_ALARM);
            if(cur<max*7/10){oldVolume=cur;am.setStreamVolume(AudioManager.STREAM_ALARM,max*7/10,0);} // loud enough to be heard
            player=new MediaPlayer();player.setAudioAttributes(SirenAlarm.alarmAudio());
            player.setDataSource(this,SirenAlarm.sound(this));player.setLooping(true);player.prepare();player.start();
        }catch(Exception ignored){}
        try{
            vibrator=(Vibrator)getSystemService(Context.VIBRATOR_SERVICE);
            if(vibrator!=null&&vibrator.hasVibrator()){
                if(Build.VERSION.SDK_INT>=26)vibrator.vibrate(VibrationEffect.createWaveform(SirenAlarm.VIBE,1),SirenAlarm.alarmAudio());
                else vibrator.vibrate(SirenAlarm.VIBE,1);
            }
        }catch(Exception ignored){}
    }
    private void stopAlarm(){
        main.removeCallbacksAndMessages(null);
        try{if(player!=null){player.stop();player.release();}}catch(Exception ignored){}
        player=null;
        try{if(vibrator!=null)vibrator.cancel();}catch(Exception ignored){}
        if(oldVolume>=0){try{getSystemService(AudioManager.class).setStreamVolume(AudioManager.STREAM_ALARM,oldVolume,0);}catch(Exception ignored){}oldVolume=-1;}
    }
    // Back does nothing: choose Done or Later.
    @Override public boolean onKeyDown(int code,android.view.KeyEvent ev){return code==android.view.KeyEvent.KEYCODE_BACK||super.onKeyDown(code,ev);}
    @Override protected void onDestroy(){stopAlarm();worker.shutdown();super.onDestroy();}
}
