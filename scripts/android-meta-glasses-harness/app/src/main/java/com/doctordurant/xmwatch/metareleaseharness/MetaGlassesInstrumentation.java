package com.doctordurant.xmwatch.metareleaseharness;

import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.Activity;
import android.app.Instrumentation;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.graphics.Rect;
import android.os.Build;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.View;
import android.view.ViewGroup;
import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.widget.TextView;
import java.lang.reflect.Field;
import java.lang.reflect.Modifier;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;
import org.json.JSONObject;

/** Runs inside the actual optimized target with only Android framework classes. */
public final class MetaGlassesInstrumentation extends Instrumentation {
    private Bundle arguments;
    private volatile Activity glassesActivity;
    private volatile int glassesCreates;
    @Override public void onCreate(Bundle args) { arguments = args; super.onCreate(args); start(); }
    @Override public void callActivityOnCreate(Activity activity, Bundle state) {
        super.callActivityOnCreate(activity, state);
        if (activity.getClass().getName().equals("xmwatch.android.MetaGlassesActivity")) {
            glassesActivity = activity;
            glassesCreates++;
        }
    }
    @Override public void onStart() {
        if ("audioOutput".equals(arguments.getString("mode"))) {
            runAudioOutput();
            return;
        }
        Bundle result = new Bundle();
        try {
            require("true".equals(arguments.getString("allowMetaOptimizedFixture")), "Explicit fixture opt-in required");
            require("com.doctordurant.xmwatch.android".equals(getTargetContext().getPackageName()), "Unexpected target");
            require((getTargetContext().getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) == 0,
                "Target must be the optimized, non-debuggable APK");
            String phase = arguments.getString("phase");
            require("denied".equals(phase) || "granted".equals(phase), "Unknown permission phase");
            boolean granted = "granted".equals(phase);
            require((getTargetContext().checkSelfPermission("android.permission.BLUETOOTH_CONNECT") == 0) == granted,
                "Permission phase precondition mismatch");
            try {
                getTargetContext().getClassLoader().loadClass("xmwatch.android.MetaGlassesMockActivity");
                throw new AssertionError("Debug mock lab leaked into optimized target");
            } catch (ClassNotFoundException expected) { }
            if (!granted) checkSDKState(false);

            // Android can restore this unexported settings Activity without MainActivity.
            Activity cold = startActivitySync(new Intent().setClassName(getTargetContext(),
                "xmwatch.android.MetaGlassesActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            checkSettings(granted);
            JSONObject coldSnapshot = configuredSnapshot();
            require(!coldSnapshot.optString("title").isBlank(), "Cold settings did not bind the real Swift playback provider");
            require(coldSnapshot.has("canPlayPause"), "Cold provider omitted the playback contract");
            checkLiveRadioSnapshot(coldSnapshot);
            main(() -> { cold.finish(); return null; });
            waitForIdleSync();
            if (!granted) checkSDKState(false);

            Activity home = startActivitySync(new Intent().setClassName(getTargetContext(),
                "xmwatch.android.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            clickLabel("Settings");
            revealAndClick("Meta Glasses");
            await("Swift Settings did not open the native glasses Activity", () -> glassesCreates >= 2);
            checkSettings(granted);
            JSONObject settingsSnapshot = configuredSnapshot();
            require(!settingsSnapshot.optString("title").isBlank() && settingsSnapshot.has("canPlayPause"),
                "Swift Settings did not configure the real playback provider");
            checkLiveRadioSnapshot(settingsSnapshot);
            require(glassesCreates == 2, "Unexpected duplicate settings launch");
            main(() -> { glassesActivity.finish(); home.finish(); return null; });
            result.putString("status", "passed");
            result.putString("phase", phase);
            result.putInt("nativeSettingsLaunches", glassesCreates);
            result.putBoolean("coldRestoredSettingsProvider", true);
            result.putBoolean("swiftSettingsBridge", true);
            result.putBoolean("realDefaultProviderInvoked", true);
            result.putBoolean("targetDebuggable", false);
            result.putBoolean("sdkMockUsed", false);
            result.putBoolean("initializedMatchesPermission", true);
            result.putString("permissionPromptScope", granted ? "pregranted by shell" : "denial after explicit settings entry");
            finish(Activity.RESULT_OK, result);
        } catch (Throwable error) {
            result.putString("status", "failed");
            result.putString("failure", android.util.Log.getStackTraceString(error));
            finish(Activity.RESULT_CANCELED, result);
        }
    }
    private void runAudioOutput() {
        Bundle result = new Bundle();
        Activity home = null;
        AccessibilityServiceInfo previousInfo = getUiAutomation().getServiceInfo();
        try {
            require("true".equals(arguments.getString("allowAudioOutputOptimizedFixture")), "Explicit audio output fixture opt-in required");
            require("com.doctordurant.xmwatch.android".equals(getTargetContext().getPackageName()), "Unexpected target");
            require(Build.VERSION.SDK_INT >= 34, "This check requires the API 34+ system chooser");
            require((getTargetContext().getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) == 0,
                "Target must be the optimized, non-debuggable APK");
            try {
                getTargetContext().getClassLoader().loadClass("xmwatch.android.MetaGlassesMockActivity");
                throw new AssertionError("Debug mock lab leaked into optimized target");
            } catch (ClassNotFoundException expected) { }
            AccessibilityServiceInfo info = getUiAutomation().getServiceInfo();
            info.flags |= AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS;
            getUiAutomation().setServiceInfo(info);
            home = startActivitySync(new Intent().setClassName(getTargetContext(),
                "xmwatch.android.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            clickLabel("Settings");
            revealAudioOutput();
            tapAudioOutput();
            await("Actual system media output chooser did not open", this::audioOutputDialog);
            sendKeyDownUpSync(KeyEvent.KEYCODE_BACK);
            await("Output chooser did not return to Swift Settings", () -> {
                getUiAutomation().clearCache();
                AccessibilityNodeInfo root = getUiAutomation().getRootInActiveWindow();
                return root != null && "com.doctordurant.xmwatch.android".contentEquals(root.getPackageName())
                    && findAudioOutput() != null;
            });
            result.putString("status", "passed");
            result.putString("mode", "audioOutput");
            result.putBoolean("targetDebuggable", false);
            result.putBoolean("actualSwiftUIEntry", true);
            result.putBoolean("systemOutputDialog", true);
            result.putBoolean("dismissedToCaller", true);
            result.putBoolean("routeSelected", false);
            result.putBoolean("bluetoothPermissionRequested", false);
            result.putBoolean("sdkMockUsed", false);
            result.putBoolean("optimizedPlaybackStateTested", false);
        } catch (Throwable error) {
            result.putString("status", "failed");
            result.putString("failure", android.util.Log.getStackTraceString(error));
        } finally {
            try {
                if (audioOutputDialog()) sendKeyDownUpSync(KeyEvent.KEYCODE_BACK);
                Activity caller = home;
                if (caller != null) main(() -> { caller.finish(); return null; });
                getUiAutomation().setServiceInfo(previousInfo);
            } catch (Throwable error) {
                result.putString("status", "failed");
                result.putString("cleanupFailure", android.util.Log.getStackTraceString(error));
            }
        }
        finish("passed".equals(result.getString("status")) ? Activity.RESULT_OK : Activity.RESULT_CANCELED, result);
    }
    private boolean audioLabel(AccessibilityNodeInfo node, String label) {
        return label.contentEquals(node.getText() == null ? "" : node.getText()) ||
            label.contentEquals(node.getContentDescription() == null ? "" : node.getContentDescription());
    }
    private AccessibilityNodeInfo findAudioOutput() {
        for (AccessibilityNodeInfo node : nodes()) {
            if (node.isVisibleToUser() && audioLabel(node, "Audio Output")) return node;
        }
        return null;
    }
    private void revealAudioOutput() throws Exception {
        for (int i = 0; i < 20; i++) {
            if (findAudioOutput() != null) return;
            for (AccessibilityNodeInfo node : nodes()) if (node.isVisibleToUser() && node.isScrollable()) {
                node.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD); break;
            }
            SystemClock.sleep(250);
        }
        throw new AssertionError("Swift Settings Audio Output entry missing");
    }
    private void tapAudioOutput() {
        AccessibilityNodeInfo node = findAudioOutput();
        require(node != null, "Audio Output entry disappeared");
        while (node != null && !node.isClickable()) node = node.getParent();
        require(node != null && node.isEnabled(), "Audio Output has no enabled button");
        Rect bounds = new Rect(); node.getBoundsInScreen(bounds);
        require(bounds.width() > 0 && bounds.height() > 0, "Audio Output button has no visible bounds");
        // A single real touch works through SwiftUI semantic wrappers. Do not
        // retry a click after the chooser might already have appeared.
        long now = SystemClock.uptimeMillis();
        MotionEvent down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, bounds.exactCenterX(), bounds.exactCenterY(), 0);
        MotionEvent up = MotionEvent.obtain(now, now + 60, MotionEvent.ACTION_UP, bounds.exactCenterX(), bounds.exactCenterY(), 0);
        down.setSource(InputDevice.SOURCE_TOUCHSCREEN); up.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        try {
            require(getUiAutomation().injectInputEvent(down, true), "Audio Output touch down failed");
            SystemClock.sleep(60);
            require(getUiAutomation().injectInputEvent(up, true), "Audio Output touch up failed");
        } finally { down.recycle(); up.recycle(); }
    }
    private boolean audioOutputDialog() {
        getUiAutomation().clearCache();
        AccessibilityNodeInfo root = getUiAutomation().getRootInActiveWindow();
        if (root == null || !"com.android.systemui".contentEquals(root.getPackageName())) return false;
        List<AccessibilityNodeInfo> values = new ArrayList<>(); collectNodes(root, values);
        boolean deviceLabel = false, dialogControl = false;
        String[] labels = {"Media output", "Audio output", "This phone", "This device", "Phone speaker", "Connect a device", "Pair new device"};
        for (AccessibilityNodeInfo node : values) {
            if (!node.isVisibleToUser()) continue;
            String id = node.getViewIdResourceName();
            if (id != null && (id.toLowerCase(java.util.Locale.ROOT).contains("media_output") ||
                id.toLowerCase(java.util.Locale.ROOT).contains("mediaoutput"))) return true;
            for (String label : labels) if (audioLabel(node, label)) deviceLabel = true;
            if (audioLabel(node, "Done") || audioLabel(node, "Cancel") || audioLabel(node, "Connect a device")) dialogControl = true;
        }
        return deviceLabel && dialogControl;
    }
    private static void require(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
    private static void checkLiveRadioSnapshot(JSONObject state) throws Exception {
        require(!state.getBoolean("canSeek"), "Live radio exposed seek controls");
        require(!state.getBoolean("canChangeRate"), "Live radio exposed rate controls");
        require(state.getLong("durationMS") == 0L, "Live radio exposed a finite duration");
    }
    private <T> T main(Callable<T> action) throws Exception {
        FutureTask<T> task = new FutureTask<>(action); runOnMainSync(task); return task.get(10, TimeUnit.SECONDS);
    }
    private void await(String message, Callable<Boolean> condition) throws Exception {
        long deadline = SystemClock.elapsedRealtime() + 20_000;
        while (SystemClock.elapsedRealtime() < deadline) {
            if (condition.call()) return;
            SystemClock.sleep(100);
        }
        throw new AssertionError(message);
    }
    private JSONObject configuredSnapshot() throws Exception {
        return main(() -> {
            ClassLoader loader = getTargetContext().getClassLoader();
            Class<?> controller = loader.loadClass(arguments.getString("controllerClass"));
            Field field = controller.getDeclaredField(arguments.getString("providerField"));
            field.setAccessible(true);
            require(Modifier.isStatic(field.getModifiers()), "Expected Kotlin object provider field");
            Object provider = field.get(null);
            Class<?> function = loader.loadClass(arguments.getString("functionClass"));
            Object value = function.getMethod(arguments.getString("invokeMethod")).invoke(provider);
            return new JSONObject(String.valueOf(value));
        });
    }
    private void checkSDKState(boolean expectedInitialized) throws Exception {
        main(() -> {
            require((getTargetContext().checkSelfPermission("android.permission.BLUETOOTH_CONNECT") == 0) == expectedInitialized,
                "Nearby permission changed unexpectedly");
            Class<?> controller = getTargetContext().getClassLoader().loadClass(arguments.getString("controllerClass"));
            Field initialized = controller.getDeclaredField(arguments.getString("initializedField"));
            Field error = controller.getDeclaredField(arguments.getString("errorField"));
            Field state = controller.getDeclaredField(arguments.getString("stateField"));
            initialized.setAccessible(true); error.setAccessible(true); state.setAccessible(true);
            require(initialized.getBoolean(null) == expectedInitialized, "SDK initialization did not respect Nearby permission");
            JSONObject snapshot = new JSONObject(String.valueOf(state.get(null)));
            require(snapshot.optBoolean("initialized") == expectedInitialized, "Published SDK initialization state disagreed");
            require(String.valueOf(error.get(null)).isEmpty(), "Unexpected SDK initialization error");
            return null;
        });
    }
    private void collect(View view, StringBuilder output) {
        if (view.getVisibility() != View.VISIBLE) return;
        if (view instanceof TextView) output.append(((TextView) view).getText()).append('\n');
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) collect(group.getChildAt(i), output);
        }
    }
    private String settingsText() throws Exception {
        return main(() -> { StringBuilder text = new StringBuilder(); collect(glassesActivity.getWindow().getDecorView(), text); return text.toString(); });
    }
    private void checkSettings(boolean granted) throws Exception {
        if (!granted) {
            // The optional feature requests permission only after explicit settings entry.
            long deadline = SystemClock.elapsedRealtime() + 3_000;
            while (SystemClock.elapsedRealtime() < deadline) {
                AccessibilityNodeInfo deny = nodes().stream().filter(n -> {
                    String id = n.getViewIdResourceName(); return id != null && id.endsWith(":id/permission_deny_button");
                }).findFirst().orElse(null);
                if (deny != null) { require(deny.performAction(AccessibilityNodeInfo.ACTION_CLICK), "Permission denial failed"); break; }
                SystemClock.sleep(100);
            }
            await("Denied permission guidance missing", () -> settingsText().contains("Allow Nearby devices to use the optional glasses display"));
        } else {
            await("Granted SDK state did not settle", () -> {
                String text = settingsText();
                return text.contains("Registration:") && !text.contains("Registration: UNINITIALIZED") && text.contains("Session: STOPPED · Display: STOPPED");
            });
        }
        String text = settingsText();
        require(text.contains("No glasses discovered"), "Unexpected glasses on the hardware-free fixture");
        require(text.contains("Standard Ray-Ban Meta glasses do not have a display"), "Bluetooth phone audio guidance missing");
        require(!text.contains("Open mock glasses lab"), "Optimized settings exposed the debug lab");
        require(text.contains("Register with Meta AI"), "Optional registration action missing");
        checkSDKState(granted);
    }
    private List<AccessibilityNodeInfo> nodes() {
        getUiAutomation().clearCache();
        List<AccessibilityNodeInfo> values = new ArrayList<>();
        AccessibilityNodeInfo root = getUiAutomation().getRootInActiveWindow();
        if (root != null) collectNodes(root, values);
        return values;
    }
    private void collectNodes(AccessibilityNodeInfo node, List<AccessibilityNodeInfo> values) {
        values.add(node);
        for (int i = 0; i < node.getChildCount(); i++) { AccessibilityNodeInfo child = node.getChild(i); if (child != null) collectNodes(child, values); }
    }
    private boolean clickIfPresent(String label) {
        for (AccessibilityNodeInfo node : nodes()) {
            if (!node.isVisibleToUser() || !(label.contentEquals(node.getText() == null ? "" : node.getText()) ||
                label.contentEquals(node.getContentDescription() == null ? "" : node.getContentDescription()))) continue;
            while (node != null && !node.isClickable()) node = node.getParent();
            return node != null && node.performAction(AccessibilityNodeInfo.ACTION_CLICK);
        }
        return false;
    }
    private void clickLabel(String label) throws Exception { await("UI button missing: " + label, () -> clickIfPresent(label)); }
    private void revealAndClick(String label) throws Exception {
        for (int i = 0; i < 20; i++) {
            if (clickIfPresent(label)) return;
            for (AccessibilityNodeInfo node : nodes()) if (node.isVisibleToUser() && node.isScrollable()) {
                node.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD); break;
            }
            SystemClock.sleep(300);
        }
        throw new AssertionError("Settings row missing: " + label);
    }
}
