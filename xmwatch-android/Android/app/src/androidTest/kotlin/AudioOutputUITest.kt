package xmwatch.android

import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.KeyEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Actual SwiftUI entry and system chooser. No output device is selected. */
@RunWith(AndroidJUnit4::class)
@UnstableApi
class AudioOutputUITest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private fun <T> main(block: () -> T): T {
        var value: T? = null; instrumentation.runOnMainSync { value = block() }
        @Suppress("UNCHECKED_CAST") return value as T
    }
    private fun nodes(root: AccessibilityNodeInfo?): List<AccessibilityNodeInfo> = if (root == null) emptyList() else
        listOf(root) + (0 until root.childCount).flatMap { nodes(root.getChild(it)) }
    private fun root(): AccessibilityNodeInfo? { instrumentation.uiAutomation.clearCache(); return instrumentation.uiAutomation.rootInActiveWindow }
    private fun label(node: AccessibilityNodeInfo, value: String) = node.text?.toString() == value || node.contentDescription?.toString() == value
    private fun await(message: String, condition: () -> Boolean) {
        val end = SystemClock.elapsedRealtime() + 20_000
        while (SystemClock.elapsedRealtime() < end) { if (condition()) return; SystemClock.sleep(100) }
        fail("$message; activePackage=${root()?.packageName}")
    }
    private fun click(value: String) {
        await("Visible button missing: $value") {
            var target = nodes(root()).firstOrNull { it.isVisibleToUser && label(it, value) } ?: return@await false
            while (!target.isClickable) target = target.parent ?: return@await false
            target.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        }
    }
    private fun reveal(value: String) {
        repeat(18) {
            if (nodes(root()).any { it.isVisibleToUser && label(it, value) }) return
            nodes(root()).firstOrNull { it.isVisibleToUser && it.isScrollable }
                ?.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
            SystemClock.sleep(250)
        }
        fail("Settings row missing: $value")
    }
    private fun outputDialog(): Boolean {
        val root = root() ?: return false
        if (root.packageName?.toString() != "com.android.systemui") return false
        val visible = nodes(root).filter { it.isVisibleToUser }
        val ids = visible.mapNotNull { it.viewIdResourceName?.lowercase() }
        val outputResource = ids.any { it.contains("media_output") || it.contains("mediaoutput") }
        val deviceLabels = setOf("Media output", "Audio output", "This phone", "This device", "Phone speaker", "Connect a device", "Pair new device")
        val knownDeviceUI = visible.any { node -> deviceLabels.any { label(node, it) } } &&
            visible.any { label(it, "Done") || label(it, "Cancel") || label(it, "Connect a device") }
        // A SystemUI status bar alone never meets this chooser-specific check.
        return outputResource || knownDeviceUI
    }
    private fun snapshot(player: Player) = JSONObject().put("count", player.mediaItemCount).put("index", player.currentMediaItemIndex)
        .put("position", player.currentPosition).put("playWhenReady", player.playWhenReady).put("state", player.playbackState)
        .put("mediaID", player.currentMediaItem?.mediaId).put("source", player.currentMediaItem?.localConfiguration?.uri?.toString()).toString()

    @Test fun actualSettingsEntryOpensSystemOutputWithoutChangingOwnedPlayback() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("allowAudioOutputFixture") == "true")
        assertTrue("This run verifies the API34+ system chooser, not the older Bluetooth fallback", Build.VERSION.SDK_INT >= 34)
        val automation = instrumentation.uiAutomation
        val originalInfo = automation.serviceInfo
        automation.serviceInfo = automation.serviceInfo.apply { flags = flags or AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS }
        val file = File.createTempFile("owned-audio-output-", ".wav", context.cacheDir)
        val samples = 800
        file.writeBytes(ByteBuffer.allocate(44 + samples * 2).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()).putInt(36 + samples * 2).put("WAVEfmt ".toByteArray()).putInt(16)
                .putShort(1).putShort(1).putInt(8000).putInt(16000).putShort(2).putShort(16)
                .put("data".toByteArray()).putInt(samples * 2)
        }.array())
        var activity: android.app.Activity? = null
        var session: MediaSession? = null
        try {
            activity = instrumentation.startActivitySync(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            click("Settings"); reveal("Audio Output")
            val engine = main { RadioEngine.get(context) }
            main {
                assertEquals("Fixture requires an idle radio", 0, engine.player.mediaItemCount)
                engine.player.setMediaItem(MediaItem.Builder().setMediaId("owned-audio-output")
                    .setUri(Uri.fromFile(file)).build())
                session = MediaSession.Builder(context, engine.sessionPlayer).setId("owned-audio-output-session").build()
                assertEquals(Player.STATE_IDLE, engine.player.playbackState) // Deliberately no prepare/play.
            }
            val before = main { snapshot(engine.player) }
            val queueBefore = main { snapshot(engine.sessionPlayer) }
            val token = main { session!!.token }
            click("Audio Output")
            await("Actual system media output chooser did not open") { outputDialog() }
            instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
            await("Output chooser did not return to caller") { root()?.packageName?.toString() == context.packageName }
            main {
                assertSame(engine, RadioEngine.get(context))
                assertEquals(before, snapshot(engine.player))
                assertEquals(queueBefore, snapshot(engine.sessionPlayer))
                assertEquals(token, session!!.token)
            }
            instrumentation.sendStatus(0, Bundle().apply { putString("audioOutputUIResult", JSONObject()
                .put("actualSwiftUIEntry", true).put("systemOutputDialog", true).put("dismissedToCaller", true)
                .put("ownedSourceUnchanged", true).put("queueUnchanged", true).put("sessionUnchanged", true)
                .put("routeSelected", false).put("bluetoothPermissionRequested", false).put("olderAPIFallbackTested", false).toString()) })
        } finally {
            if (outputDialog()) instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
            main { session?.release(); RadioEngine.get(context).stop(); activity?.finish() }
            file.delete(); automation.serviceInfo = originalInfo
        }
    }
}
