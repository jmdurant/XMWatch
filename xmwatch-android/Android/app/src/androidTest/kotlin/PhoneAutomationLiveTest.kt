package xmwatch.android

import android.app.Notification
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.ShortcutManager
import android.media.session.MediaSession
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import androidx.media3.common.util.UnstableApi
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Explicit live test: saved cookie only, real foreground actions and decoder. */
@RunWith(AndroidJUnit4::class)
@UnstableApi
class PhoneAutomationLiveTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private fun <T> main(block: () -> T): T {
        var result: T? = null
        instrumentation.runOnMainSync { result = block() }
        @Suppress("UNCHECKED_CAST") return result as T
    }
    private fun snapshot() = JSONObject(main { RadioEngine.get(context).snapshot() })
    private fun await(label: String, block: () -> Boolean) {
        val end = SystemClock.elapsedRealtime() + 90_000
        while (SystemClock.elapsedRealtime() < end) {
            if (block()) return
            SystemClock.sleep(100)
        }
        fail("Live phone action timed out: $label")
    }
    private fun action(path: String) {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("xmwatch://automation/$path"), context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP))
    }
    private fun token(): MediaSession.Token? = context.getSystemService(NotificationManager::class.java).activeNotifications
        .firstOrNull { it.notification.extras.containsKey(Notification.EXTRA_MEDIA_SESSION) }?.notification?.extras
        ?.getParcelable(Notification.EXTRA_MEDIA_SESSION, MediaSession.Token::class.java)

    @Test fun savedSessionTunesAndDecodesThroughForegroundActions() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("allowLivePhoneAutomation") == "true")
        assertTrue("An existing encrypted radio session is required", RadioSecureStore.load(context).isNotEmpty())
        val shortcuts = context.getSystemService(ShortcutManager::class.java)
        val dynamic = shortcuts.dynamicShortcuts
        val pinned = shortcuts.pinnedShortcuts.associate { it.id to it.isEnabled }
        try {
            action("tune?number=2")
            await("tuned channel decoded") { snapshot().optBoolean("playing") && snapshot().optInt("renderedBuffers") > 10 }
            val engine = main { RadioEngine.get(context) }
            val mediaID = main { engine.player.currentMediaItem?.mediaId }
            val source = main { engine.player.currentMediaItem?.localConfiguration?.uri }
            assertFalse(mediaID.isNullOrBlank())
            assertEquals("xmwatch", source?.scheme)
            val initial = snapshot().getInt("renderedBuffers")
            await("fresh decoded buffers") { snapshot().optInt("renderedBuffers") > initial + 20 }
            await("media notification token") { token() != null }
            val session = token()
            action("pause")
            await("action pause") { !snapshot().optBoolean("playing") && !snapshot().optBoolean("wantsPlayback") }
            val position = snapshot().getDouble("position")
            SystemClock.sleep(800)
            assertTrue(kotlin.math.abs(snapshot().getDouble("position") - position) < 0.4)
            val pausedBuffers = snapshot().getInt("renderedBuffers")
            action("resume")
            await("resume decoded buffers") { snapshot().optBoolean("playing") && snapshot().optInt("renderedBuffers") > pausedBuffers + 20 }
            main {
                assertSame(engine, RadioEngine.get(context))
                assertEquals(mediaID, engine.player.currentMediaItem?.mediaId)
                // Live resume renews the stream plan, as the normal radio Play
                // button does. Its opaque per-plan URL is expected to change.
                assertEquals("xmwatch", engine.player.currentMediaItem?.localConfiguration?.uri?.scheme)
            }
            assertEquals(session, token())
            action("pause")
            await("final pause") { !snapshot().optBoolean("playing") && !snapshot().optBoolean("wantsPlayback") }
            instrumentation.sendStatus(0, Bundle().apply {
                putString("phoneAutomationLiveResult", JSONObject().put("savedSessionUsed", true)
                    .put("actualTuneAction", true).put("decodedAudio", true).put("pauseResumeActions", true)
                    .put("samePlayerChannelAndSession", true).put("livePlanRenewalAllowed", true).put("leftPaused", true)
                    .put("initialRenderedBuffers", initial).put("resumedRenderedBuffers", snapshot().getInt("renderedBuffers"))
                    .put("providerAccountMutationsRequested", false).toString())
            })
        } finally {
            main { RadioEngine.get(context).pause() }
            assertTrue(shortcuts.setDynamicShortcuts(dynamic))
            pinned.filterValues { it }.keys.toList().takeIf { it.isNotEmpty() }?.let { shortcuts.enableShortcuts(it) }
            pinned.filterValues { !it }.keys.toList().takeIf { it.isNotEmpty() }?.let { shortcuts.disableShortcuts(it) }
            assertEquals(dynamic.map { it.id }.toSet(), shortcuts.dynamicShortcuts.map { it.id }.toSet())
            assertEquals(pinned, shortcuts.pinnedShortcuts.associate { it.id to it.isEnabled })
        }
    }
}
