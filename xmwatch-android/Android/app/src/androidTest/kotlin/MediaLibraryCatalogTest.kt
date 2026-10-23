package xmwatch.android

import android.content.ComponentName
import androidx.media3.common.Player
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaBrowser
import androidx.media3.session.SessionToken
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class MediaLibraryCatalogTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun <T> main(block: () -> T): T {
        var result: T? = null
        instrumentation.runOnMainSync { result = block() }
        @Suppress("UNCHECKED_CAST") return result as T
    }

    @Test fun metadataBoundaryDoesNotForwardSourcesHeadersExtrasOrLocalArtwork() {
        val catalog = main { MediaLibraryCatalog { _, done ->
            done("""[{"id":"media:v1:WyJhIl0","title":"Song","subtitle":"Artist","browsable":false,"playable":true,
                "artworkURL":"file:///private/art.jpg","uri":"https://example.com/private?token=secret",
                "headers":{"Cookie":"secret"},"extras":{"token":"secret"}}]""")
        } }
        try {
            val result = main { catalog.item("media:v1:WyJhIl0", null) }.get(5, TimeUnit.SECONDS)
            assertEquals(LibraryResult.RESULT_SUCCESS, result.resultCode)
            val item = requireNotNull(result.value)
            assertNull(item.localConfiguration)
            assertTrue(item.requestMetadata.extras == null || item.requestMetadata.extras!!.isEmpty)
            assertTrue(item.mediaMetadata.extras == null || item.mediaMetadata.extras!!.isEmpty)
            assertNull(item.mediaMetadata.artworkUri)
            assertEquals("Song", item.mediaMetadata.title.toString())
            assertEquals(true, item.mediaMetadata.isPlayable)
        } finally { main { catalog.close() } }
    }

    @Test fun malformedRequestsNeverReachProviderAndClosingCancelsPendingRequests() {
        var calls = 0
        var late: ((String) -> Unit)? = null
        val catalog = main { MediaLibraryCatalog { _, done -> calls++; late = done } }
        try {
            for (request in listOf(
                main { catalog.children(MediaLibraryCatalog.ROOT_ID, -1, 10, null) },
                main { catalog.children(MediaLibraryCatalog.ROOT_ID, 0, 0, null) },
                main { catalog.children(MediaLibraryCatalog.ROOT_ID, 0, 101, null) },
                main { catalog.children(MediaLibraryCatalog.ROOT_ID, 1, Int.MAX_VALUE, null) },
                main { catalog.item("https://example.com/private", null) }
            )) assertEquals(LibraryResult.RESULT_ERROR_BAD_VALUE, request.get(5, TimeUnit.SECONDS).resultCode)
            assertEquals(0, calls)
            val pending = main { catalog.item(MediaLibraryCatalog.ROOT_ID, null) }
            assertEquals(1, calls)
            main { catalog.close() }
            assertTrue(pending.isCancelled)
            main { late?.invoke("[]") }
            assertTrue(pending.isCancelled)
        } finally { main { catalog.close() } }
    }

    @Test fun oversizedProviderListsFailInsteadOfTruncatingAndLegacyRequestsAreBounded() {
        var requested = 0
        val catalog = main { MediaLibraryCatalog { request, done ->
            requested = org.json.JSONObject(request).getInt("pageSize")
            val rows = org.json.JSONArray()
            repeat(101) { index -> rows.put(org.json.JSONObject().put("id", "media:v1:item$index")
                .put("title", "Item $index").put("browsable", false).put("playable", true)) }
            done(rows.toString())
        } }
        try {
            val result = main { catalog.children(MediaLibraryCatalog.ROOT_ID, 0, Int.MAX_VALUE, null) }.get(5, TimeUnit.SECONDS)
            assertEquals(100, requested)
            assertEquals(LibraryResult.RESULT_ERROR_BAD_VALUE, result.resultCode)
            assertNull(result.value)
        } finally { main { catalog.close() } }
    }

    @Test fun invalidProviderOutputReturnsAnErrorWithoutPublishingAnItem() {
        val catalog = main { MediaLibraryCatalog { _, done -> done("{\"error\":\"unavailable\"}") } }
        try {
            val result = main { catalog.item(MediaLibraryCatalog.ROOT_ID, null) }.get(5, TimeUnit.SECONDS)
            assertEquals(LibraryResult.RESULT_ERROR_BAD_VALUE, result.resultCode)
            assertNull(result.value)
        } finally { main { catalog.close() } }
    }

}
