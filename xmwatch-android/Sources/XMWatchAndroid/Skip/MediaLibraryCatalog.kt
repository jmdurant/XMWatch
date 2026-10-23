package xmwatch.android

import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.session.MediaSession
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService.LibraryParams
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.SettableFuture
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executor

/** A source-independent media browser boundary. The Swift adapter owns the
 * account/catalog; only metadata crosses into external media controllers. */
class MediaLibraryCatalog(
    private val artwork: (String) -> String? = { null },
    private val browse: (String, (String) -> Unit) -> Unit,
) : AutoCloseable {
    companion object {
        // MediaBrowseIdentifier.encode([]), deliberately available without
        // loading Swift or waiting for any network on legacy onGetRoot calls.
        const val ROOT_ID = "media:v1:W10"
        const val RESUME_ID = "media:v1:WyJyZXN1bWUiXQ"
        val root: MediaItem get() = MediaItem.Builder().setMediaId(ROOT_ID).setMediaMetadata(
            MediaMetadata.Builder().setTitle("XMWatch").setIsBrowsable(true).setIsPlayable(false)
                .setMediaType(MediaMetadata.MEDIA_TYPE_FOLDER_MIXED).build()).build()
    }
    private val handler = Handler(Looper.getMainLooper())
    private val pending = mutableSetOf<SettableFuture<*>>()
    private var closed = false

    fun item(id: String, params: LibraryParams?): ListenableFuture<LibraryResult<MediaItem>> = request(
        JSONObject().put("op", "item").put("id", id), LibraryResult.ofError(LibraryResult.RESULT_ERROR_BAD_VALUE)) { array ->
        require(array.length() == 1)
        LibraryResult.ofItem(metadata(array.getJSONObject(0)), params)
    }

    fun children(id: String, page: Int, pageSize: Int, params: LibraryParams?): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> {
        if (page < 0 || pageSize <= 0 || (pageSize > 100 && pageSize != Int.MAX_VALUE) ||
            (pageSize == Int.MAX_VALUE && page != 0)) {
            return com.google.common.util.concurrent.Futures.immediateFuture(LibraryResult.ofError(LibraryResult.RESULT_ERROR_BAD_VALUE))
        }
        // Legacy unpaged requests use MAX_VALUE. The Swift tree inserts range
        // folders so each complete child list fits within 100 entries.
        return request(JSONObject().put("op", "children").put("id", id).put("page", page)
            .put("pageSize", pageSize.coerceAtMost(100)), LibraryResult.ofError(LibraryResult.RESULT_ERROR_BAD_VALUE)) { array ->
            require(array.length() <= pageSize.coerceAtMost(100))
            LibraryResult.ofItemList((0 until array.length()).map { metadata(array.getJSONObject(it)) }, params)
        }
    }

    fun resumption(): ListenableFuture<MediaSession.MediaItemsWithStartPosition?> = request(
        JSONObject().put("op", "resumption"), null) { rows ->
        require(rows.length() == 1)
        val row = rows.getJSONObject(0)
        val position = row.getLong("positionMs")
        require(position >= 0)
        val decoded = metadata(row)
        require(decoded.mediaMetadata.isPlayable == true)
        val art = decoded.mediaMetadata.artworkUri?.takeIf { it.scheme == "content" }
        val item = decoded.buildUpon().setMediaMetadata(decoded.mediaMetadata.buildUpon().setArtworkUri(art).build()).build()
        MediaSession.MediaItemsWithStartPosition(listOf(item), 0, position)
    }

    fun searchCount(query: String): ListenableFuture<Int> = request(
        JSONObject().put("op", "searchCount").put("query", query), -1) { rows ->
        require(rows.length() == 1)
        val count = rows.getJSONObject(0).getInt("count")
        require(count >= 0)
        count
    }

    fun search(query: String, page: Int, pageSize: Int, params: LibraryParams?): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> {
        if (page < 0 || pageSize <= 0 || (pageSize > 100 && pageSize != Int.MAX_VALUE) ||
            (pageSize == Int.MAX_VALUE && page != 0)) return com.google.common.util.concurrent.Futures.immediateFuture(
                LibraryResult.ofError(LibraryResult.RESULT_ERROR_BAD_VALUE))
        return request(JSONObject().put("op", "search").put("query", query).put("page", page)
            .put("grouped", pageSize == Int.MAX_VALUE).put("pageSize", pageSize.coerceAtMost(100)), LibraryResult.ofError(LibraryResult.RESULT_ERROR_BAD_VALUE)) { rows ->
            require(rows.length() <= pageSize.coerceAtMost(100))
            LibraryResult.ofItemList((0 until rows.length()).map { metadata(rows.getJSONObject(it)) }, params)
        }
    }

    private fun <T> request(arguments: JSONObject, error: T, decode: (JSONArray) -> T): ListenableFuture<T> {
        val future = SettableFuture.create<T>()
        if (closed) { future.set(error); return future }
        val id = arguments.optString("id")
        val search = arguments.optString("op") in listOf("search", "searchCount")
        val query = arguments.optString("query")
        if (arguments.optString("op") != "resumption" &&
            (if (search) query.isBlank() || query.length > 256 else id.length > 4096 || !id.startsWith("media:v1:"))) {
            future.set(error); return future
        }
        pending.add(future)
        val timeout = Runnable { future.set(error) }
        handler.postDelayed(timeout, 20_000)
        future.addListener({ handler.removeCallbacks(timeout); pending.remove(future) }, Executor { handler.post(it) })
        try {
            browse(arguments.toString()) { result ->
                handler.post {
                    if (!future.isDone) {
                        try { future.set(decode(JSONArray(result))) }
                        catch (_: Exception) { future.set(error) }
                    }
                }
            }
        } catch (_: Exception) { future.set(error) }
        return future
    }

    private fun metadata(row: JSONObject): MediaItem {
        val id = row.getString("id")
        require(id.startsWith("media:v1:") && id.length <= 4096)
        val folder = row.getBoolean("browsable")
        val playable = row.getBoolean("playable")
        require(folder != playable)
        val metadata = MediaMetadata.Builder().setTitle(row.getString("title")).setArtist(row.optString("subtitle"))
            .setIsBrowsable(folder).setIsPlayable(playable)
            .setMediaType(if (folder) MediaMetadata.MEDIA_TYPE_FOLDER_MIXED else MediaMetadata.MEDIA_TYPE_MUSIC)
        artwork(row.optString("artworkID"))?.let { metadata.setArtworkUri(Uri.parse(it)) }
        // Explicitly do not accept a source URI, request headers or extras from
        // either the adapter or a requesting controller.
        return MediaItem.Builder().setMediaId(id).setMediaMetadata(metadata.build()).build()
    }

    override fun close() {
        closed = true
        pending.toList().forEach { it.cancel(false) }
        pending.clear()
    }
}
