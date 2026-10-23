package xmwatch.android

import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Exercises the installed radio binding without authentication or network I/O. */
@RunWith(AndroidJUnit4::class)
@UnstableApi
class MetaRadioPlaybackBindingTest {
    @Test fun unsupportedSeekAndRateLeaveTheSingleRadioSourceUntouched() {
        assumeTrue("Requires the account-preserving Meta SDK fixture harness",
            InstrumentationRegistry.getArguments().getString("allowMetaGlassesFixture") == "true")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        // Initialize the read-only Swift state bridge before capturing its native
        // handler, so lazy ViewModel setup cannot replace our owned callback.
        instrumentation.runOnMainSync { MetaPlaybackState.shared.snapshot() }
        var originalBinding: Pair<() -> org.json.JSONObject, (String) -> Unit>? = null
        var originalHandler: ((String) -> Unit)? = null
        val commands = mutableListOf<String>()
        val fixture = MediaItem.Builder().setMediaId("meta-owned-radio-fixture")
            .setUri("https://fixture.invalid/live.m3u8").build()
        try {
            instrumentation.runOnMainSync {
                originalBinding = MetaGlassesController.capturePlaybackBinding()
                val engine = RadioEngine.get(context)
                originalHandler = engine.commandHandler
                engine.commandHandler = { commands.add(it) }
                // Deliberately omit prepare(): no request can reach the fixture URI.
                engine.player.setMediaItem(fixture)
                MetaPlaybackBinding.configure(context)
            }
            instrumentation.waitForIdleSync()
            var position = 0L
            var speed = 1f
            var revision = 0L
            instrumentation.runOnMainSync {
                val engine = RadioEngine.get(context)
                position = engine.player.currentPosition
                speed = engine.player.playbackParameters.speed
                revision = engine.revision
                val binding = MetaGlassesController.capturePlaybackBinding()
                val snapshot = binding.first()
                assertFalse(snapshot.getBoolean("canSeek"))
                assertFalse(snapshot.getBoolean("canChangeRate"))
                assertEquals(0L, snapshot.getLong("durationMS"))
                assertFalse(snapshot.toString().contains("fixture.invalid"))
                for (command in listOf("seekBack", "seekForward", "rate")) binding.second(command)
            }
            // The real binding posts transport work to its main Handler.
            instrumentation.waitForIdleSync()
            instrumentation.runOnMainSync {
                val engine = RadioEngine.get(context)
                assertTrue("Unsupported controls reached radio command handler", commands.isEmpty())
                assertEquals(revision, engine.revision)
                assertEquals(1, engine.player.mediaItemCount)
                assertEquals(fixture.mediaId, engine.player.currentMediaItem?.mediaId)
                assertEquals(Uri.parse("https://fixture.invalid/live.m3u8"), engine.player.currentMediaItem?.localConfiguration?.uri)
                assertEquals(position, engine.player.currentPosition)
                assertEquals(speed, engine.player.playbackParameters.speed, 0f)
                assertFalse(engine.player.playWhenReady)
            }
        } finally {
            instrumentation.runOnMainSync {
                val engine = RadioEngine.get(context)
                engine.stop()
                engine.commandHandler = originalHandler
                originalBinding?.let { MetaGlassesController.restorePlaybackBinding(it) }
            }
        }
    }
}
