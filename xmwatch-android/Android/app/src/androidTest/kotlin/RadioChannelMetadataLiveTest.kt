package xmwatch.android

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import android.view.inputmethod.InputMethodManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Real saved-cookie bulk metadata and the actual SwiftUI search field; never tunes. */
@RunWith(AndroidJUnit4::class)
class RadioChannelMetadataLiveTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private fun <T> main(block: () -> T): T {
        var value: T? = null; instrumentation.runOnMainSync { value = block() }
        @Suppress("UNCHECKED_CAST") return value as T
    }
    private fun await(label: String, timeout: Long = 30_000, test: () -> Boolean) {
        val end = SystemClock.elapsedRealtime() + timeout
        while (SystemClock.elapsedRealtime() < end) { if (test()) return; SystemClock.sleep(100) }
        val visible = nodes().filter { it.isVisibleToUser }.flatMap(::labels).toSet()
        val diagnostics = JSONObject().put("visiblePlayLabels", visible.count { it.startsWith("Play ") })
            .put("visibleSongLabels", visible.count { it.startsWith("Current song: ") })
            .put("visibleArtistLabels", visible.count { it.startsWith("Current artist: ") })
            .put("visibleEditableFields", nodes().count { it.isVisibleToUser && it.isEditable })
            .put("signInVisible", "Sign In" in visible).put("retryChannelsVisible", "Retry Channels" in visible)
        fail("Live channel metadata check timed out: $label; public UI counts=$diagnostics")
    }
    private fun descendants(root: AccessibilityNodeInfo?): List<AccessibilityNodeInfo> {
        if (root == null) return emptyList()
        return listOf(root) + (0 until root.childCount).flatMap { descendants(root.getChild(it)) }
    }
    private fun nodes(): List<AccessibilityNodeInfo> {
        instrumentation.uiAutomation.clearCache()
        return descendants(instrumentation.uiAutomation.rootInActiveWindow)
    }
    private fun labels(node: AccessibilityNodeInfo) = listOfNotNull(node.contentDescription?.toString(), node.text?.toString())
    private fun click(label: String) {
        await(label) {
            var node = nodes().firstOrNull { it.isVisibleToUser && label in labels(it) } ?: return@await false
            while (!node.isClickable) node = node.parent ?: return@await false
            node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        }
    }
    private data class Row(val play: String, val song: String, val artist: String)
    private fun rows(): List<Row> {
        val result = mutableListOf<Row>()
        val visible = nodes().filter { it.isVisibleToUser }
        for (songNode in visible) {
            val song = labels(songNode).firstOrNull { it.startsWith("Current song: ") }?.removePrefix("Current song: ") ?: continue
            var parent = songNode.parent
            for (depth in 0 until 6) {
                if (parent == null) break
                val children = descendants(parent).filter { it.isVisibleToUser }
                val plays = children.flatMap(::labels).filter { it.startsWith("Play ") }.distinct()
                val artist = children.flatMap(::labels).firstOrNull { it.startsWith("Current artist: ") }?.removePrefix("Current artist: ")
                if (plays.size == 1 && !artist.isNullOrBlank() && song.isNotBlank()) {
                    result.add(Row(plays.single(), song, artist)); break
                }
                parent = parent?.parent
            }
        }
        return result.distinctBy { it.play }
    }
    private fun playLabels() = nodes().filter { it.isVisibleToUser }.flatMap(::labels).filter { it.startsWith("Play ") }.toSet()
    private fun searchField() = nodes().firstOrNull { it.isVisibleToUser && it.isEditable }
    private fun search(value: String) {
        await("real channel search field") { searchField() != null }
        val field = checkNotNull(searchField())
        assertTrue("Actual search EditText rejected text", field.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT,
            Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value) }))
    }

    @Test fun liveRowsExposeCurrentSongAndArtistAndSearchBothWithoutTuning() {
        assumeTrue("Requires the state-preserving live channel metadata harness",
            InstrumentationRegistry.getArguments().getString("allowChannelMetadataLive") == "true")
        assertTrue("Saved encrypted session required; this check never signs in", RadioSecureStore.load(context).isNotBlank())
        val owner = checkNotNull(RadioSecureStore.owner(context))
        val region = JSONObject(RadioSecureStore.load(context)).getString("region")
        assertFalse("Harness must disable optional auto-resume before process launch",
            context.getSharedPreferences("defaults", 0).getBoolean("xm.android.resumeLastChannel", false))
        var activity: Activity? = null
        try {
            activity = instrumentation.startActivitySync(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            click("Channels")
            var sample: Row? = null
            var baseline = emptyList<Row>()
            await("at least two actual bulk-fed song/artist rows", 90_000) {
                baseline = rows()
                sample = baseline.firstOrNull { candidate ->
                    candidate.song.length >= 3 && candidate.artist.length >= 3 &&
                        !candidate.play.contains(candidate.song, ignoreCase = true) && !candidate.play.contains(candidate.artist, ignoreCase = true) &&
                        listOf(candidate.song, candidate.artist).all { term -> baseline.any { other ->
                            other.play != candidate.play && listOf(other.play, other.song, other.artist).none { it.contains(term, ignoreCase = true) }
                        } }
                }
                sample != null
            }
            val chosen = checkNotNull(sample)
            assertTrue("Baseline channel was not visible", chosen.play in playLabels())
            if (searchField() == null) click("Search")
            for ((label, term) in listOf("artist" to chosen.artist, "song" to chosen.song)) {
                val unrelated = baseline.first { other -> other.play != chosen.play &&
                    listOf(other.play, other.song, other.artist).none { it.contains(term, ignoreCase = true) } }
                search(term)
                await("$label search retains matching channel and filters unrelated channel") {
                    val plays = playLabels()
                    chosen.play in plays && unrelated.play !in plays && rows().any { it.play == chosen.play &&
                        (if (label == "artist") it.artist else it.song).contains(term, ignoreCase = true) }
                }
                main { assertEquals("Searching must not tune audio", 0, RadioEngine.get(context).player.mediaItemCount) }
                search("")
                await("clear $label search restores catalog rows") { chosen.play in playLabels() && unrelated.play in playLabels() }
            }
            assertEquals(owner, RadioSecureStore.owner(context))
            assertEquals(region, JSONObject(RadioSecureStore.load(context)).getString("region"))
            main { assertEquals(0, RadioEngine.get(context).player.mediaItemCount) }
            instrumentation.sendStatus(0, Bundle().apply { putString("channelMetadataResult", JSONObject()
                .put("savedCookieUsed", true).put("actualLiveSongAndArtist", true).put("artistSearch", true).put("songSearch", true)
                .put("unmatchedChannelsFiltered", true).put("searchCleared", true).put("accountAndRegionPreserved", true)
                .put("playbackNotStarted", true).put("noSignInAttempted", true).toString()) })
        } finally {
            runCatching { if (searchField() != null) search("") }
            main {
                activity?.currentFocus?.let { focused ->
                    (context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(focused.windowToken, 0)
                    focused.clearFocus()
                }
                activity?.finish()
            }
        }
    }
}
