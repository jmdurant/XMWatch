package xmwatch.android

import android.app.Activity
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Rect
import android.graphics.Bitmap
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import org.json.JSONObject
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Assume
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Opt-in actual Swift UI and decoded radio check. The outer harness escrows preferences. */
@RunWith(AndroidJUnit4::class)
@UnstableApi
class RadioPlaybackLayoutLiveTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private fun <T> main(block: () -> T): T {
        var result: T? = null
        instrumentation.runOnMainSync { result = block() }
        @Suppress("UNCHECKED_CAST") return result as T
    }
    private fun await(label: String, timeoutMS: Long = 20_000, test: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMS
        while (SystemClock.elapsedRealtime() < deadline) {
            if (test()) return
            Thread.sleep(100)
        }
        diagnostics("timeout: $label")
        throw AssertionError("Playback layout check timed out: $label")
    }
    private fun root(): AccessibilityNodeInfo? {
        instrumentation.uiAutomation.clearCache()
        return instrumentation.uiAutomation.rootInActiveWindow
    }
    private fun find(node: AccessibilityNodeInfo?, label: String): AccessibilityNodeInfo? {
        node ?: return null
        if (node.isVisibleToUser && (node.text?.toString() == label || node.contentDescription?.toString() == label)) return node
        for (index in 0 until node.childCount) find(node.getChild(index), label)?.let { return it }
        return null
    }
    /** Only fixed public control labels and geometry; never dump account/channel text. */
    private fun diagnostics(stage: String) {
        runCatching {
            val labels = setOf("Channels", "Favorites", "Now Playing", "Settings", "Open Now Playing",
                "Previous Channel", "Next Channel", "Play", "Pause")
            val rows = JSONArray()
            fun collect(value: AccessibilityNodeInfo?) {
                value ?: return
                val label = listOfNotNull(value.text?.toString(), value.contentDescription?.toString()).firstOrNull { it in labels }
                if (label != null) {
                    val bounds = Rect().also { value.getBoundsInScreen(it) }
                    val clickBounds = actionable(value)?.let { action -> Rect().also { action.getBoundsInScreen(it) }.toShortString() }
                    rows.put(JSONObject().put("label", label).put("visible", value.isVisibleToUser)
                        .put("selected", value.isSelected).put("enabled", value.isEnabled)
                        .put("clickable", value.isClickable).put("bounds", bounds.toShortString())
                        .put("actionBounds", clickBounds ?: ""))
                }
                for (index in 0 until value.childCount) collect(value.getChild(index))
            }
            collect(root())
            val counts = JSONObject()
            for (label in labels) counts.put(label, (0 until rows.length()).count {
                rows.getJSONObject(it).optString("label") == label && rows.getJSONObject(it).optBoolean("visible")
            })
            instrumentation.sendStatus(0, Bundle().apply {
                putString("playbackLayoutDiagnostics", JSONObject().put("stage", stage)
                    .put("orientation", main { context.resources.configuration.orientation })
                    .put("visibleLabelCounts", counts).put("controls", rows).toString())
            })
        }
        if (stage.startsWith("timeout:") && InstrumentationRegistry.getArguments().getString("allowRadioPlaybackLayout") == "true") {
            val saved = runCatching {
                val image = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
                try {
                    File(context.cacheDir, "radio-playback-layout-failure.png").outputStream().use {
                        check(image.compress(Bitmap.CompressFormat.PNG, 100, it))
                    }
                } finally { image.recycle() }
            }.isSuccess
            instrumentation.sendStatus(0, Bundle().apply { putBoolean("playbackLayoutFailureScreenshotSaved", saved) })
        }
    }
    private fun actionable(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        var current: AccessibilityNodeInfo? = node
        while (current != null && !current.isClickable) current = current.parent
        return current?.takeIf { it.isEnabled && it.isVisibleToUser &&
            it.actionList.any { action -> action.id == AccessibilityNodeInfo.ACTION_CLICK } }
    }
    private fun visibleBounds(label: String): Rect {
        val window = checkNotNull(root()) { "No active app window" }
        val found = checkNotNull(find(window, label)) { "Missing visible control: $label" }
        val control = checkNotNull(actionable(found)) { "Control is not actionable: $label" }
        val bounds = Rect().also { control.getBoundsInScreen(it) }
        val windowBounds = Rect().also { window.getBoundsInScreen(it) }
        assertFalse("Empty control bounds: $label", bounds.isEmpty)
        if (label in setOf("Open Now Playing", "Play", "Pause", "Previous Channel", "Next Channel")) {
            val minimumHeight = kotlin.math.ceil(44.0 * context.resources.displayMetrics.density).toInt()
            assertTrue("Playback target is clipped below 44dp: $label ${bounds.toShortString()}", bounds.height() >= minimumHeight)
        }
        assertTrue("Control extends beyond the visible window: $label", windowBounds.contains(bounds))
        return bounds
    }
    private fun click(label: String) {
        await("visible action $label") { find(root(), label)?.let { actionable(it) } != null }
        val bounds = visibleBounds(label)
        instrumentation.sendStatus(0, Bundle().apply {
            putString("playbackLayoutTap", JSONObject().put("label", label).put("bounds", bounds.toShortString()).toString())
        })
        if (label == "Open Now Playing") diagnostics("before mini-player coordinate tap")
        instrumentation.uiAutomation.executeShellCommand("input tap ${bounds.centerX()} ${bounds.centerY()}")
            .let { ParcelFileDescriptor.AutoCloseInputStream(it).use { stream -> stream.readBytes() } }
    }
    private fun scrollable(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        node ?: return null
        if (node.isVisibleToUser && node.isScrollable &&
            node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_SCROLL_FORWARD }) return node
        for (index in 0 until node.childCount) scrollable(node.getChild(index))?.let { return it }
        return null
    }
    private fun revealLandscapeControls() {
        val labels = listOf("Previous Channel", "Play", "Next Channel")
        repeat(8) {
            if (labels.all { runCatching { visibleBounds(it) }.isSuccess }) return
            scrollable(root())?.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
            Thread.sleep(250)
        }
        for (label in labels) visibleBounds(label)
    }
    private fun activity(): Activity? = main {
        ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
            .firstOrNull { it is MainActivity }
    }
    private fun snapshot(): JSONObject = JSONObject(main { RadioEngine.get(context).snapshot() })
    private fun paused() = main {
        val engine = RadioEngine.get(context)
        !engine.player.playWhenReady && !engine.player.isPlaying && !engine.preparing
    }
    private fun decoded() = main {
        val player = RadioEngine.get(context).player
        player.playbackState == Player.STATE_READY && player.isPlaying && player.volume > 0f &&
            (player.audioDecoderCounters?.renderedOutputBufferCount ?: 0) > 10
    }

    @Test(timeout = 180_000)
    fun liveDecodedPlaybackMiniPlayerNavigationAndLandscapeControls() {
        Assume.assumeTrue("Explicit live playback layout opt-in required",
            InstrumentationRegistry.getArguments().getString("allowRadioPlaybackLayout") == "true")
        assertTrue("A saved encrypted radio session is required", RadioSecureStore.load(context).isNotBlank())
        val owner = checkNotNull(RadioSecureStore.owner(context))
        var launched: Activity? = null
        var originalRequest = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        var originalOrientation = Configuration.ORIENTATION_UNDEFINED
        try {
            context.startActivity(Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP))
            await("actual MainActivity resumed", 30_000) { activity() != null }
            launched = checkNotNull(activity())
            originalRequest = main { launched!!.requestedOrientation }
            originalOrientation = main { launched!!.resources.configuration.orientation }
            click("Channels")
            // This existing first US channel is also used by the saved-cookie live suite.
            // No assertion depends on its current artist/song or metadata timing.
            click("Play SiriusXM Hits 1")
            await("real READY player and decoded audio", 45_000) { decoded() }
            val firstBuffers = snapshot().getInt("renderedBuffers")
            await("decoded output advances", 10_000) { decoded() && snapshot().getInt("renderedBuffers") > firstBuffers + 5 }
            val channelID = main { RadioEngine.get(context).player.currentMediaItem?.mediaId }
            assertFalse("No privately resolved channel source", channelID.isNullOrBlank())
            click("Pause")
            await("phone Pause stops playback") { paused() && find(root(), "Play") != null }

            click("Channels")
            await("mini-player appears while browsing") { find(root(), "Open Now Playing") != null && find(root(), "Play") != null }
            visibleBounds("Open Now Playing"); visibleBounds("Play")
            assertTrue("Browsing restarted paused playback", paused())
            click("Open Now Playing")
            await("mini-player opens the full player") {
                find(root(), "Previous Channel") != null && find(root(), "Next Channel") != null &&
                    find(root(), "Play") != null && find(root(), "Open Now Playing") == null
            }
            assertEquals("Mini-player navigation changed the channel", channelID,
                main { RadioEngine.get(context).player.currentMediaItem?.mediaId })
            assertTrue("Mini-player navigation restarted playback", paused())

            main { launched!!.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
            await("landscape configuration", 15_000) {
                main { launched!!.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE }
            }
            // Short displays may use the intentional vertical-scroll fallback.
            revealLandscapeControls()
            // A real coordinate tap proves the main control is reachable in the new layout.
            click("Play")
            await("landscape Play resumes decoded audio", 30_000) { decoded() }
            click("Pause")
            await("landscape Pause stops playback") { paused() && find(root(), "Play") != null }
            assertEquals("Layout changes changed the channel", channelID,
                main { RadioEngine.get(context).player.currentMediaItem?.mediaId })
            assertEquals("UI flow changed the authorized account", owner, RadioSecureStore.owner(context))
            instrumentation.sendStatus(0, Bundle().apply {
                putString("playbackLayoutResult", JSONObject().put("savedCookieUsed", true)
                    .put("decodedAudioAdvanced", true).put("miniPlayerVisible", true)
                    .put("miniPlayerOpenedNowPlaying", true).put("landscapeControlsReachable", true)
                    .put("landscapePlayPause", true).put("sameChannelPreserved", true).toString())
            })
        } finally {
            // Never change system rotation settings. Restore only this Activity's request.
            main {
                RadioEngine.get(context).sessionPlayer.pause()
                launched?.requestedOrientation = originalRequest
            }
            await("cleanup leaves the owned player paused", 10_000) { paused() }
            if (launched != null && originalOrientation != Configuration.ORIENTATION_UNDEFINED) {
                await("original Activity orientation restored", 15_000) {
                    main { launched!!.resources.configuration.orientation == originalOrientation }
                }
            }
        }
    }
}
