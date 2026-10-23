package xmwatch.testing;

import android.content.ComponentName;
import android.content.Context;
import android.media.MediaMetadata;
import android.media.browse.MediaBrowser;
import android.media.session.MediaController;
import android.media.session.PlaybackState;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;

/** Separate-app legacy browser. No classes or runtime are injected into XMWatch. */
@SuppressWarnings("deprecation")
public final class RadioLibraryProbe extends android.app.Instrumentation {
    private static Handler MAIN;
    private Bundle arguments;
    @Override public void onCreate(Bundle values) { arguments=values;super.onCreate(values);start(); }
    @Override public void onStart() {
        Bundle result=new Bundle();
        try {
            check("true".equals(arguments.getString("allowOwnedControllerProbe")),"Explicit owned fixture opt-in required");
            MAIN=new Handler(Looper.getMainLooper());
            rejectUnapproved(getTargetContext());
            getUiAutomation().adoptShellPermissionIdentity("android.permission.MEDIA_CONTENT_CONTROL");
            probe(getTargetContext(), "true".equals(arguments.getString("requireArtwork")));
            result.putBoolean("controllerArtworkDecoded", "true".equals(arguments.getString("requireArtwork")));
            result.putBoolean("unapprovedArtworkCallerRejected", "true".equals(arguments.getString("requireArtwork")));
            result.putBoolean("playPauseNextStopAndVoiceSearch", true);
            result.putBoolean("testRuntimeInjected", false);
            result.putBoolean("unapprovedBrowserRejected", true);
            result.putString("status","passed");finish(android.app.Activity.RESULT_OK,result);
        } catch (Throwable error) { result.putString("status","failed");result.putString("failure",android.util.Log.getStackTraceString(error));finish(android.app.Activity.RESULT_CANCELED,result); }
        finally { getUiAutomation().dropShellPermissionIdentity(); }
    }
    private static <T> T main(Callable<T> work) throws Exception {
        FutureTask<T> task=new FutureTask<>(work);MAIN.post(task);return task.get(10,TimeUnit.SECONDS);
    }
    private static void check(boolean value,String label) { if (!value) throw new AssertionError(label); }
    private static void waitFor(String label,Callable<Boolean> work) throws Exception {
        long deadline=SystemClock.elapsedRealtime()+60000;
        while (SystemClock.elapsedRealtime()<deadline) { if (main(work)) return;SystemClock.sleep(100); }
        throw new AssertionError("Controller timed out: "+label);
    }
    private static List<MediaBrowser.MediaItem> children(MediaBrowser browser,String id) throws Exception {
        CompletableFuture<List<MediaBrowser.MediaItem>> future=new CompletableFuture<>();
        main(()->{ browser.subscribe(id,new MediaBrowser.SubscriptionCallback() {
            @Override public void onChildrenLoaded(String parent,List<MediaBrowser.MediaItem> rows) { future.complete(rows); }
            @Override public void onError(String parent) { future.completeExceptionally(new IllegalStateException("Browse failed")); }
        });return null; });
        try {
            List<MediaBrowser.MediaItem> rows=future.get(40,TimeUnit.SECONDS);
            for (MediaBrowser.MediaItem row:rows) {
                check(row.getDescription().getMediaUri()==null,"Source URI exposed");
                check(row.getMediaId().startsWith("media:v1:"),"Non-opaque browse identifier");
            }
            return rows;
        } finally { main(()->{ browser.unsubscribe(id);return null; }); }
    }
    private static MediaBrowser.MediaItem titled(List<MediaBrowser.MediaItem> rows,String title) {
        for (MediaBrowser.MediaItem row:rows) if (title.contentEquals(row.getDescription().getTitle())) return row;
        throw new AssertionError("Missing owned fixture: "+title);
    }
    private static boolean title(MediaController controller,String title) {
        MediaMetadata value=controller.getMetadata();return value!=null && title.equals(value.getString(MediaMetadata.METADATA_KEY_TITLE));
    }
    private static boolean playing(MediaController controller) { return controller.getPlaybackState()!=null && controller.getPlaybackState().getState()==PlaybackState.STATE_PLAYING; }
    private static long position(MediaController controller) {
        PlaybackState state=controller.getPlaybackState();
        if (state==null) return -1;
        return state.getPosition()+(playing(controller)?(long)((SystemClock.elapsedRealtime()-state.getLastPositionUpdateTime())*state.getPlaybackSpeed()):0);
    }
    private void rejectUnapproved(Context context) throws Exception {
        CompletableFuture<Boolean> ready=new CompletableFuture<>();
        MediaBrowser browser=main(()->{
            MediaBrowser value=new MediaBrowser(context,new ComponentName("com.doctordurant.xmwatch.android","xmwatch.android.RadioPlaybackService"),new MediaBrowser.ConnectionCallback() {
                @Override public void onConnected() { ready.complete(true); }
                @Override public void onConnectionFailed() { ready.complete(false); }
                @Override public void onConnectionSuspended() { ready.complete(false); }
            },null);value.connect();return value;
        });
        try { check(!ready.get(20,TimeUnit.SECONDS),"Unapproved legacy browser rejected"); }
        finally { main(()->{browser.disconnect();return null;}); }
    }
    private static void cover(Context context, android.net.Uri uri) throws Exception {
        check(uri!=null && "content".equals(uri.getScheme()), "Local controller artwork URI");
        check("com.doctordurant.xmwatch.android.artwork".equals(uri.getAuthority()), "Own artwork provider");
        check("image/jpeg".equals(context.getContentResolver().getType(uri)), "JPEG artwork MIME");
        try (java.io.InputStream input=context.getContentResolver().openInputStream(uri)) {
            android.graphics.Bitmap bitmap=android.graphics.BitmapFactory.decodeStream(input);
            check(bitmap!=null, "Controller cover decodes");
            try { check(Math.max(bitmap.getWidth(),bitmap.getHeight())<=512,"Bounded controller cover"); }
            finally { bitmap.recycle(); }
        }
    }
    private void probe(Context context, boolean artwork) throws Exception {
        check(android.os.Build.HARDWARE.equals("ranchu") || android.os.Build.HARDWARE.equals("goldfish"),"Select an emulator");
        check(android.os.Process.myUid()!=context.getPackageManager().getApplicationInfo("com.doctordurant.xmwatch.android",0).uid,"Separate controller UID");
        android.content.Intent discover=new android.content.Intent("android.media.browse.MediaBrowserService").setPackage("com.doctordurant.xmwatch.android");
        check(!context.getPackageManager().queryIntentServices(discover,0).isEmpty(),"Legacy service discovery");
        CompletableFuture<Boolean> connected=new CompletableFuture<>();
        MediaBrowser browser=main(()->{
            MediaBrowser value=new MediaBrowser(context,new ComponentName("com.doctordurant.xmwatch.android","xmwatch.android.RadioPlaybackService"),new MediaBrowser.ConnectionCallback() {
                @Override public void onConnected() { connected.complete(true); }
                @Override public void onConnectionFailed() { connected.completeExceptionally(new IllegalStateException("Controller rejected")); }
            },null);value.connect();return value;
        });
        MediaController controller=null;
        try {
            check(connected.get(30,TimeUnit.SECONDS),"Browser connection");
            String root=main(browser::getRoot);
            MediaBrowser.MediaItem all=titled(children(browser,root),"All Channels");
            List<MediaBrowser.MediaItem> tracks=children(browser,all.getMediaId());
            MediaBrowser.MediaItem first=titled(tracks,"SiriusXM Hits 1");
            if (artwork) {
                cover(context,first.getDescription().getIconUri());
                getUiAutomation().dropShellPermissionIdentity();boolean denied=false;
                try { context.getContentResolver().openFileDescriptor(first.getDescription().getIconUri(),"r").close(); }
                catch (SecurityException expected) { denied=true; }
                finally { getUiAutomation().adoptShellPermissionIdentity("android.permission.MEDIA_CONTENT_CONTROL"); }
                check(denied,"Unapproved artwork caller rejected");
            }
            final MediaController active=main(()->new MediaController(context,browser.getSessionToken()));controller=active;
            main(()->{active.getTransportControls().prepareFromMediaId(first.getMediaId(),null);return null;});
            waitFor("paused preparation",()->active.getMetadata()!=null && "SiriusXM Hits 1".equals(active.getMetadata().getString(MediaMetadata.METADATA_KEY_TITLE)));
            check(!main(()->playing(active)),"Preparation must stay silent");
            main(()->{active.getTransportControls().play();return null;});waitFor("radio playback",()->playing(active));
            String firstID=main(()->active.getMetadata().getString(MediaMetadata.METADATA_KEY_MEDIA_ID));
            main(()->{active.getTransportControls().skipToNext();return null;});
            waitFor("next station",()->playing(active) && !firstID.equals(active.getMetadata().getString(MediaMetadata.METADATA_KEY_MEDIA_ID)));
            main(()->{active.getTransportControls().pause();return null;});waitFor("pause",()->!playing(active));
            main(()->{active.getTransportControls().playFromSearch("SiriusXM Hits 1",null);return null;});
            waitFor("voice search",()->playing(active) && firstID.equals(active.getMetadata().getString(MediaMetadata.METADATA_KEY_MEDIA_ID)));
            main(()->{active.getTransportControls().stop();return null;});waitFor("stop",()->!playing(active));
        } finally {
            final MediaController active=controller;
            main(()->{if (active!=null) active.getTransportControls().pause();browser.disconnect();return null;});
        }
    }
}
