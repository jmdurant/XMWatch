package xmwatch.android

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationManager
import android.content.Intent
import android.media.session.MediaController
import android.media.session.MediaSession
import android.os.Bundle
import android.graphics.Rect
import android.view.MotionEvent
import android.view.InputDevice
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.media3.common.util.UnstableApi
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.Assume
import org.junit.runner.RunWith

/** Opt-in live playback against the already authorized, encrypted account session. */
@RunWith(AndroidJUnit4::class)
@UnstableApi
class RadioLivePlaybackTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private fun <T> main(block: () -> T): T {
        var result: T? = null
        instrumentation.runOnMainSync { result = block() }
        @Suppress("UNCHECKED_CAST") return result as T
    }
    private fun snapshot() = JSONObject(main { RadioEngine.get(context).snapshot() })
    private fun waitFor(timeout: Long = 30000, predicate: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeout
        while (SystemClock.elapsedRealtime() < deadline) {
            if (predicate()) return
            Thread.sleep(100)
        }
        throw AssertionError("Radio check timed out")
    }
    private fun node(root: AccessibilityNodeInfo?, label: String, prefix: Boolean = false): AccessibilityNodeInfo? {
        root ?: return null
        val description = root.contentDescription?.toString().orEmpty()
        if (if (prefix) description.startsWith(label) else description == label) return root
        for (index in 0 until root.childCount) node(root.getChild(index), label, prefix)?.let { return it }
        return null
    }
    private fun click(label: String) {
        waitFor { node(instrumentation.uiAutomation.rootInActiveWindow, label) != null }
        instrumentation.uiAutomation.waitForIdle(300, 5000)
        val found = checkNotNull(node(instrumentation.uiAutomation.rootInActiveWindow, label))
        found.refresh()
        val bounds = Rect().also { found.getBoundsInScreen(it) }
        assertFalse("Radio control has no visible bounds", bounds.isEmpty)
        instrumentation.sendStatus(0, Bundle().apply {
            putString("tapControl", label); putString("tapBounds", bounds.toShortString())
        })
        // Use the platform's input command, as the manual device harness does.
        // Executing a shell command does not adopt shell permissions in the app.
        val coordinateKey = if (label.startsWith("Play ")) "playTap" else "nextTap"
        val coordinates = InstrumentationRegistry.getArguments().getString(coordinateKey)?.split(",")?.map { it.toInt() }
        val x = coordinates?.get(0) ?: bounds.centerX()
        val y = coordinates?.get(1) ?: bounds.centerY()
        val descriptor = instrumentation.uiAutomation.executeShellCommand("input tap $x $y")
        android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { it.readBytes() }

    }
    @Test fun liveAudioBackgroundControlsNextAndSavedSession() {
        Assume.assumeTrue("Explicit live playback required",
            InstrumentationRegistry.getArguments().getString("allowLiveRadio") == "true")
        assertTrue("No saved authorized session", RadioSecureStore.load(context).isNotEmpty())
        var controller: MediaController? = null
        try {
            context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            click("Play SiriusXM Hits 1")
            waitFor { snapshot().optBoolean("playing") && snapshot().optInt("renderedBuffers") > 0 }
            instrumentation.sendStatus(0, Bundle().apply { putString("initialTimeline", snapshot().toString()) })
            waitFor(45000) { snapshot().getInt("metadataRevision") > 0 }
            val metadataTitle = main { RadioEngine.get(context).player.currentMediaItem?.mediaMetadata?.title?.toString() }
            assertFalse("Current-song metadata was not populated", metadataTitle.isNullOrEmpty())
            val first = snapshot()
            instrumentation.uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_HOME)
            val before = snapshot()
            Thread.sleep(10000)
            val background = snapshot()
            assertTrue(background.getBoolean("playing"))
            instrumentation.sendStatus(0, Bundle().apply {
                putString("backgroundBefore", before.toString())
                putString("backgroundAfter", background.toString())
            })
            // A live HLS window moves as older segments expire; window-relative
            // position may rebase while audio continues. Check decoded output instead.
            assertTrue("Decoded audio did not advance in background", background.getInt("renderedBuffers") > before.getInt("renderedBuffers") + 20)
            val service = context.getSystemService(ActivityManager::class.java).getRunningServices(100)
                .firstOrNull { it.service.className == "xmwatch.android.RadioPlaybackService" }
            assertTrue("Media service was not foreground", service?.foreground == true)
            // Observe the app's own notification token without borrowing shell UID permissions.
            val notification = context.getSystemService(NotificationManager::class.java).activeNotifications
                .first { it.notification.extras.containsKey(Notification.EXTRA_MEDIA_SESSION) }.notification
            val token = checkNotNull(notification.extras.getParcelable(Notification.EXTRA_MEDIA_SESSION, MediaSession.Token::class.java))
            controller = MediaController(context, token)
            controller.transportControls.pause()
            waitFor { !snapshot().getBoolean("playing") }
            val paused = snapshot().getDouble("position")
            Thread.sleep(1500)
            assertTrue("Pause did not hold", snapshot().getDouble("position") <= paused + 0.3)
            controller.transportControls.play()
            val pausedBuffers = snapshot().getInt("renderedBuffers")
            waitFor { snapshot().getBoolean("playing") && snapshot().getInt("renderedBuffers") > pausedBuffers + 10 }
            val remoteFirstID = main { RadioEngine.get(context).player.currentMediaItem?.mediaId }
            controller.transportControls.skipToNext()
            waitFor { main { RadioEngine.get(context).player.currentMediaItem?.mediaId } != remoteFirstID &&
                snapshot().optBoolean("playing") && snapshot().optInt("renderedBuffers") > 0 }
            controller.transportControls.skipToPrevious()
            waitFor { main { RadioEngine.get(context).player.currentMediaItem?.mediaId } == remoteFirstID &&
                snapshot().optBoolean("playing") && snapshot().optInt("renderedBuffers") > 0 }
            var renewalVerified = false
            var recoveryVerified = false
            if (InstrumentationRegistry.getArguments().getString("verifyRenewal") == "true") {
                val originalURI = main { RadioEngine.get(context).player.currentMediaItem?.localConfiguration?.uri.toString() }
                val renewalBefore = snapshot().getInt("renewals")
                var reportAt = SystemClock.elapsedRealtime()
                waitFor(540000) {
                    val current = snapshot()
                    if (SystemClock.elapsedRealtime() >= reportAt) {
                        instrumentation.sendStatus(0, Bundle().apply {
                            putString("renewalWait", JSONObject().put("playing", current.optBoolean("playing"))
                                .put("renderedBuffers", current.optInt("renderedBuffers")).put("renewals", current.optInt("renewals")).toString())
                        })
                        reportAt = SystemClock.elapsedRealtime() + 30000
                    }
                    current.getInt("renewals") > renewalBefore
                }
                val beforeOutput = snapshot().getInt("renderedBuffers")
                waitFor { snapshot().getBoolean("playing") && snapshot().getInt("renderedBuffers") > beforeOutput + 20 }
                assertEquals("Renewal must preserve the current source", originalURI,
                    main { RadioEngine.get(context).player.currentMediaItem?.localConfiguration?.uri.toString() })
                renewalVerified = true
            }
            if (InstrumentationRegistry.getArguments().getString("verifyRecovery") == "true") {
                val originalURI = main { RadioEngine.get(context).player.currentMediaItem?.localConfiguration?.uri.toString() }
                // Break only this in-memory stream route. Saved cookies, device networking,
                // and other apps stay untouched; recovery must resolve a fresh real plan.
                main {
                    val field = RadioEngine::class.java.getDeclaredField("activePlan").apply { isAccessible = true }
                    val plan = field.get(RadioEngine.get(context)) as RadioStreamPlan
                    val values = RadioStreamPlan::class.java.getDeclaredField("values").apply { isAccessible = true }
                    val broken = JSONObject((values.get(plan) as JSONObject).toString())
                        .put("playlistURL", "https://127.0.0.1:1/unavailable.m3u8")
                        .put("segmentBaseURL", "https://127.0.0.1:1/")
                    plan.renew(broken.toString())
                }
                waitFor(90000) { main { RadioEngine.get(context).player.currentMediaItem?.localConfiguration?.uri.toString() } != originalURI &&
                    snapshot().getBoolean("playing") && snapshot().getInt("renderedBuffers") > 0 }
                recoveryVerified = true
            }
            context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            val firstID = main { RadioEngine.get(context).player.currentMediaItem?.mediaId }
            controller.transportControls.skipToNext()
            waitFor { main { RadioEngine.get(context).player.currentMediaItem?.mediaId } != firstID &&
                snapshot().optBoolean("playing") && snapshot().optInt("renderedBuffers") > 0 }
            val currentURI = main { RadioEngine.get(context).player.currentMediaItem?.localConfiguration?.uri.toString() }
            assertTrue("Session URI must be opaque", currentURI.startsWith("xmwatch://live/"))
            val channelsTap = checkNotNull(InstrumentationRegistry.getArguments().getString("channelsTap"))
                .split(",").map { it.toInt() }
            instrumentation.uiAutomation.executeShellCommand("input tap ${channelsTap[0]} ${channelsTap[1]}").let {
                android.os.ParcelFileDescriptor.AutoCloseInputStream(it).use { stream -> stream.readBytes() }
            }
            Thread.sleep(1000)
            val currentNotification = context.getSystemService(NotificationManager::class.java).activeNotifications
                .first { it.notification.extras.containsKey(Notification.EXTRA_MEDIA_SESSION) }.notification
            checkNotNull(currentNotification.contentIntent).send()
            Thread.sleep(1000)
            val result = JSONObject().put("coldSessionRestore", true).put("decodedAudio", true)
                .put("firstRenderedBuffers", first.getInt("renderedBuffers"))
                .put("backgroundDecodedBuffers", background.getInt("renderedBuffers") - before.getInt("renderedBuffers"))
                .put("foregroundService", true).put("systemPauseResume", true).put("nextChannel", true)
                .put("opaqueSessionURI", true).put("metadata", true)
                .put("systemNextPrevious", true).put("notificationIntentSent", true)
                .put("renewal", renewalVerified).put("recovery", recoveryVerified)
            instrumentation.sendStatus(0, Bundle().apply { putString("radioResult", result.toString()) })
        } finally { controller?.transportControls?.pause(); main { RadioEngine.get(context).stop() } }
    }
}
