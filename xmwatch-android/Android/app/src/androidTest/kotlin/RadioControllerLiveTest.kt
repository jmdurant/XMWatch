package xmwatch.android

import android.content.ComponentName
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.session.MediaBrowser
import androidx.media3.session.SessionToken
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import org.junit.Assert.*
import org.junit.Assume
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.TimeUnit

/** Explicit opt-in: reuses the existing cookie and leaves the live radio paused. */
@RunWith(AndroidJUnit4::class)
class RadioControllerLiveTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private fun <T> main(block: () -> T): T {
        var result: T? = null
        instrumentation.runOnMainSync { result = block() }
        @Suppress("UNCHECKED_CAST") return result as T
    }
    private fun waitFor(label: String, condition: () -> Boolean) {
        val until = android.os.SystemClock.elapsedRealtime() + 60000
        while (android.os.SystemClock.elapsedRealtime() < until) { if (condition()) return; Thread.sleep(100) }
        error("Radio controller timed out: $label")
    }
    @Test fun coldExplicitPlaybackResumptionUsesTheSavedCookieAndChannel() {
        Assume.assumeTrue(InstrumentationRegistry.getArguments().getString("allowLiveRadioController") == "true")
        check(RadioSecureStore.load(context).isNotBlank())
        val browser = main { MediaBrowser.Builder(context, SessionToken(context, ComponentName(context, RadioPlaybackService::class.java))).buildAsync() }.get(20, TimeUnit.SECONDS)
        val engine = main { RadioEngine.get(context) }
        try {
            assertEquals(0, main { engine.player.mediaItemCount })
            val saved = main { browser.getItem(MediaLibraryCatalog.RESUME_ID) }.get(40, TimeUnit.SECONDS)
            assertEquals(0, saved.resultCode); assertTrue(saved.value!!.mediaMetadata.isPlayable == true)
            assertEquals(0, main { engine.player.mediaItemCount })
            // No setMediaItem: this exercises onPlaybackResumption itself.
            main { browser.play() }
            waitFor("cold explicit resumption decoded") { main { engine.player.isPlaying && (engine.player.audioDecoderCounters?.renderedOutputBufferCount ?: 0) > 10 } }
            assertTrue(main { ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).isEmpty() })
            instrumentation.sendStatus(0, android.os.Bundle().apply { putString("radioResumptionResult", "cookie-only cold resumption decoded; metadata stayed silent; no activity") })
        } finally { main { browser.pause(); browser.release(); engine.pause() } }
    }
    @Test fun coldCookieBrowseSearchPrivatePreparationAndLiveRadioControls() {
        Assume.assumeTrue(InstrumentationRegistry.getArguments().getString("allowLiveRadioController") == "true")
        check(RadioSecureStore.load(context).isNotBlank()) { "Use the existing signed-in cookie session" }
        assertTrue(main { ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).isEmpty() })
        val browser = main { MediaBrowser.Builder(context, SessionToken(context, ComponentName(context, RadioPlaybackService::class.java))).buildAsync() }.get(20, TimeUnit.SECONDS)
        val engine = main { RadioEngine.get(context) }
        fun children(id: String): List<MediaItem> {
            val result = main { browser.getChildren(id, 0, 100, null) }.get(40, TimeUnit.SECONDS)
            assertEquals(0, result.resultCode)
            return requireNotNull(result.value).toList().also { rows ->
                rows.forEach { assertNull(it.localConfiguration); assertTrue(it.mediaId.startsWith("media:v1:")) }
            }
        }
        fun cover(item: MediaItem) {
            val uri = requireNotNull(item.mediaMetadata.artworkUri)
            assertEquals("content", uri.scheme)
            val bytes = context.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
            assertTrue(bytes.size in 1..256 * 1024)
            val image = requireNotNull(android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size))
            try { assertTrue(maxOf(image.width, image.height) <= 512) } finally { image.recycle() }
        }
        try {
            val root = main { browser.getLibraryRoot(null) }.get(20, TimeUnit.SECONDS).value!!
            val folders = children(root.mediaId)
            val all = folders.single { it.mediaMetadata.title.toString() == "All Channels" }
            val tracks = mutableListOf<MediaItem>(); var next: String? = all.mediaId; val pages = mutableSetOf<String>()
            while (next != null) {
                check(pages.add(next)); val rows = children(next)
                tracks.addAll(rows.filter { it.mediaMetadata.isPlayable == true })
                next = rows.singleOrNull { it.mediaMetadata.title.toString() == "More…" }?.mediaId
            }
            assertTrue(tracks.size > 20); assertEquals(tracks.size, tracks.map { it.mediaId }.toSet().size)
            children(folders.single { it.mediaMetadata.title.toString() == "Favorites" }.mediaId)
            val categories = children(folders.single { it.mediaMetadata.title.toString() == "Categories" }.mediaId)
            assertTrue(categories.isNotEmpty()); assertTrue(children(categories.first().mediaId).isNotEmpty())
            assertEquals(0, main { engine.player.mediaItemCount })
            assertFalse(main { engine.player.playWhenReady })
            val query = "Hits"
            assertEquals(0, main { browser.search(query, null) }.get(30, TimeUnit.SECONDS).resultCode)
            val found = main { browser.getSearchResult(query, 0, 100, null) }.get(30, TimeUnit.SECONDS)
            assertEquals(0, found.resultCode)
            assertTrue(requireNotNull(found.value).isNotEmpty())
            val first = tracks.first { it.mediaMetadata.title.toString() == "SiriusXM Hits 1" }
            cover(first)
            val injected = first.buildUpon().setUri("https://untrusted.invalid/source?cookie=forged")
                .setMediaMetadata(MediaMetadata.Builder().setTitle("Injected controller title").build()).build()
            main { browser.setMediaItem(injected) }
            waitFor("authenticated source committed") { main { engine.player.mediaItemCount == 1 && !engine.preparing } }
            assertFalse(main { engine.player.playWhenReady })
            assertEquals(first.mediaMetadata.title.toString(), main { engine.player.currentMediaItem!!.mediaMetadata.title.toString() })
            assertEquals("xmwatch", main { engine.player.currentMediaItem!!.localConfiguration!!.uri.scheme })
            main { browser.prepare(); browser.play() }
            waitFor("radio decoded") { main { engine.player.isPlaying && (engine.player.audioDecoderCounters?.renderedOutputBufferCount ?: 0) > 10 } }
            cover(main { requireNotNull(engine.player.currentMediaItem) })
            main { browser.pause() }; waitFor("pause") { main { !engine.player.playWhenReady } }
            val previous = main { engine.player.currentMediaItem!!.mediaId }
            main { browser.seekToNextMediaItem() }
            waitFor("next channel") { main { engine.player.currentMediaItem?.mediaId?.let { it != previous } == true && !engine.preparing } }
            main { browser.pause() }; waitFor("pause next") { main { !engine.player.playWhenReady } }
            val cancelled = main {
                val pending = RadioControllerPreparation.select(listOf(first), 0, 0)
                RadioControllerPreparation.cancel(); pending
            }
            assertTrue(cancelled.isCancelled)
            val invalid = main { RadioControllerPreparation.select(listOf(MediaItem.Builder().setMediaId("media:v1:unknown").build()), 0, 0) }
            try { invalid.get(10, TimeUnit.SECONDS); fail("Unknown controller selection accepted") }
            catch (_: java.util.concurrent.ExecutionException) { }
            main { browser.setMediaItem(MediaItem.Builder().setRequestMetadata(
                MediaItem.RequestMetadata.Builder().setSearchQuery("SiriusXM Hits 1").build()).build()) }
            waitFor("voice search prepared") { main { engine.player.currentMediaItem?.mediaId == previous && !engine.preparing } }
            main { browser.play() }
            waitFor("voice search audio decoded") { main { engine.player.isPlaying && (engine.player.audioDecoderCounters?.renderedOutputBufferCount ?: 0) > 10 } }
            main { browser.pause() }
            assertTrue(main { ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).isEmpty() })
            val saved = main { browser.getItem(MediaLibraryCatalog.RESUME_ID) }.get(30, TimeUnit.SECONDS)
            assertEquals(0, saved.resultCode); cover(requireNotNull(saved.value))
            instrumentation.sendStatus(0, android.os.Bundle().apply {
                putString("radioControllerResult", org.json.JSONObject().put("channelCount", tracks.size)
                    .put("pagedBrowse", true).put("favorites", true).put("categories", true).put("search", true)
                    .put("localCoverDecoded", true).put("cookieOnlyColdStart", true).put("silentPreparation", true)
                    .put("ignoredInjectedURI", true).put("decodedRadio", true).put("pauseAndNext", true)
                    .put("cancelledAndUnknownSelectionRejected", true).put("voiceSearch", true).put("noActivity", true).put("resumeMetadata", true).toString())
            })
        } finally { main { browser.pause(); browser.release(); RadioControllerPreparation.cancel(); engine.pause() } }
    }
}
