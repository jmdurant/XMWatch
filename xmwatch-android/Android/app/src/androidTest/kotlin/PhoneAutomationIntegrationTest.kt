package xmwatch.android

import android.app.Activity
import android.content.Intent
import android.content.pm.ShortcutManager
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.view.KeyEvent
import android.view.MotionEvent
import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Real Activity delivery and Swift transport; never resolves a real account item. */
@RunWith(AndroidJUnit4::class)
@UnstableApi
class PhoneAutomationIntegrationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private fun <T> main(block: () -> T): T {
        var result: T? = null; instrumentation.runOnMainSync { result = block() }
        @Suppress("UNCHECKED_CAST") return result as T
    }
    private fun root(): AccessibilityNodeInfo? { instrumentation.uiAutomation.clearCache(); return instrumentation.uiAutomation.rootInActiveWindow }
    private fun nodes(node: AccessibilityNodeInfo?): List<AccessibilityNodeInfo> = if (node == null) emptyList() else
        listOf(node) + (0 until node.childCount).flatMap { nodes(node.getChild(it)) }
    private fun visible(value: String) = nodes(root()).any { it.isVisibleToUser && (it.text?.toString() == value || it.contentDescription?.toString() == value) }
    private fun await(label: String, condition: () -> Boolean) {
        val end = SystemClock.elapsedRealtime() + 20_000
        while (SystemClock.elapsedRealtime() < end) { if (condition()) return; SystemClock.sleep(70) }
        fail("Phone automation timed out: $label; package=${root()?.packageName}")
    }
    private fun click(value: String) {
        var bounds: Rect? = null; var stable = 0L
        await("stable $value") {
            val node = nodes(root()).firstOrNull { it.isVisibleToUser && it.isEnabled && (it.text?.toString() == value || it.contentDescription?.toString() == value) } ?: return@await false
            val next = Rect(); node.getBoundsInScreen(next)
            if (next.isEmpty) return@await false
            if (bounds != next) { bounds = next; stable = SystemClock.elapsedRealtime() }
            SystemClock.elapsedRealtime() - stable >= 400
        }
        val rect = checkNotNull(bounds); val now = SystemClock.uptimeMillis()
        val down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, rect.exactCenterX(), rect.exactCenterY(), 0)
        val up = MotionEvent.obtain(now, now + 50, MotionEvent.ACTION_UP, rect.exactCenterX(), rect.exactCenterY(), 0)
        try { instrumentation.sendPointerSync(down); instrumentation.sendPointerSync(up) } finally { down.recycle(); up.recycle() }
    }
    private fun resumed() = main { ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<MainActivity>().singleOrNull() }
    private fun request(path: String) = Intent(Intent.ACTION_VIEW, Uri.parse("xmwatch://automation/$path"), context, MainActivity::class.java)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    private fun source(player: Player) = JSONObject().put("count", player.mediaItemCount).put("index", player.currentMediaItemIndex)
        .put("mediaID", player.currentMediaItem?.mediaId).put("uri", player.currentMediaItem?.localConfiguration?.uri.toString()).toString()

    @Test fun actualColdAndWarmActionsPublishPickersAndReuseOwnedPausedSession() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("allowPhoneAutomationFixture") == "true")
        var activity: Activity? = null; var session: MediaSession? = null
        val shortcutManager = context.getSystemService(ShortcutManager::class.java)
        val previousDynamic = shortcutManager.dynamicShortcuts
        val previousPinned = shortcutManager.pinnedShortcuts.associate { it.id to it.isEnabled }
        val file = File.createTempFile("owned-phone-automation-", ".wav", context.cacheDir)
        file.writeBytes(ByteBuffer.allocate(160044).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()).putInt(160036).put("WAVEfmt ".toByteArray()).putInt(16)
            putShort(1).putShort(1).putInt(8000).putInt(16000).putShort(2).putShort(16).put("data".toByteArray()).putInt(160000)
        }.array())
        try {
            assertNull("Fixture must cold-launch MainActivity", resumed())
            activity = instrumentation.startActivitySync(request("pick?query=Owned"))
            await("actual Swift channel selector") { visible("Tune Channel") && visible("No Matching Channels") && visible("Done") }
            main { assertEquals(Intent.ACTION_MAIN, activity!!.intent.action); assertNull(activity!!.intent.data) }
            val shortcuts = context.getSystemService(ShortcutManager::class.java).manifestShortcuts
            assertEquals(setOf("tune-channel", "pause", "resume"), shortcuts.map { it.id }.toSet())
            assertTrue(shortcuts.all { it.isEnabled && it.activity?.className == MainActivity::class.java.name && it.intent?.component?.className == MainActivity::class.java.name && it.intent?.component?.packageName == context.packageName })
            assertTrue(shortcuts.all { it.intent?.action in setOf(Intent.ACTION_VIEW, PhoneAutomation.ACTION) })
            assertEquals(setOf("xmwatch://automation/pick", "xmwatch://automation/pause", "xmwatch://automation/resume"), shortcuts.map { it.intent?.data.toString() }.toSet())
            click("Done")
            val first = activity
            main { first!!.recreate() }
            await("recreated caller without query replay") { resumed()?.let { it !== first && !visible("Tune Channel") } == true }
            activity = resumed()
            main { assertEquals(Intent.ACTION_MAIN, activity!!.intent.action); assertNull(activity!!.intent.data) }
            val engine = main { RadioEngine.get(context) }
            main {
                assertEquals(0, engine.player.mediaItemCount)
                engine.player.setMediaItem(MediaItem.Builder().setMediaId("owned-phone-automation").setUri(Uri.fromFile(file)).build())
                session = MediaSession.Builder(context, engine.sessionPlayer).setId("owned-phone-automation-session").build()
                engine.player.playWhenReady = true // STATE_IDLE, no preparation or decoding.
                assertEquals(Player.STATE_IDLE, engine.player.playbackState)
            }
            val before = main { source(engine.player) }; val queue = main { source(engine.sessionPlayer) }; val token = main { session!!.token }
            val oldIntent = main { activity!!.intent }
            context.startActivity(request("pause"))
            await("warm MainActivity -> Swift pause -> existing engine") { main { activity!!.intent !== oldIntent && !engine.player.playWhenReady } }
            assertSame(activity, resumed())
            val pausedIntent = main { activity!!.intent }
            context.startActivity(request("tune?query=https%3A%2F%2Finvalid.example%2Fprivate"))
            await("malformed request delivered without execution") { main { activity!!.intent !== pausedIntent } }
            SystemClock.sleep(450)
            assertFalse(visible("Tune Channel"))
            main {
                assertSame(engine, RadioEngine.get(context)); assertEquals(before, source(engine.player)); assertEquals(queue, source(engine.sessionPlayer))
                assertEquals(token, session!!.token); assertFalse(engine.player.playWhenReady); assertEquals(Player.STATE_IDLE, engine.player.playbackState)
                assertEquals(0, engine.player.audioDecoderCounters?.renderedOutputBufferCount ?: 0)
            }
            instrumentation.sendStatus(0, Bundle().apply { putString("phoneAutomationUIResult", JSONObject()
                .put("coldActivityIntent", true).put("warmActivityIntent", true).put("publishedLauncherShortcuts", true)
                .put("entitySelectionUI", true).put("intentConsumedAcrossRecreation", true).put("invalidInputNoAutoplay", true)
                .put("ownedTransportReuse", true).put("originalAccountUsed", false).put("externalPlaybackStarted", false)
                .put("entityPlayAndShuffleRuntimeTested", false).put("transportAction", "pause").toString()) })
        } finally {
            try {
                main { session?.release(); RadioEngine.get(context).stop(); activity?.finish() }
            } finally {
                // Publishing signed-out metadata must not leave the user's launcher changed.
                assertTrue(shortcutManager.setDynamicShortcuts(previousDynamic))
                previousPinned.filterValues { it }.keys.toList().takeIf { it.isNotEmpty() }?.let { shortcutManager.enableShortcuts(it) }
                previousPinned.filterValues { !it }.keys.toList().takeIf { it.isNotEmpty() }?.let { shortcutManager.disableShortcuts(it) }
                assertEquals(previousDynamic.map { it.id }.toSet(), shortcutManager.dynamicShortcuts.map { it.id }.toSet())
                assertEquals(previousPinned, shortcutManager.pinnedShortcuts.associate { it.id to it.isEnabled })
                assertTrue(!file.exists() || file.delete())
            }
        }
    }
}
