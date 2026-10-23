package xmwatch.android

import android.os.Handler
import android.os.Looper
import androidx.media3.common.*
import androidx.media3.session.MediaSession
import com.google.common.util.concurrent.*
import java.util.UUID
import java.util.concurrent.Executor

/** The Swift catalog owns station selection. Controller metadata is untrusted. */
object RadioControllerPreparation {
    private val handler = Handler(Looper.getMainLooper())
    private var token = ""
    private var pending: SettableFuture<MediaSession.MediaItemsWithStartPosition>? = null
    fun isCurrent(value: String) = value.isNotBlank() && value == token && pending?.isDone == false
    fun select(items: List<MediaItem>, index: Int, position: Long): ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
        val id = items.singleOrNull()?.mediaId ?: ""
        val query = items.singleOrNull()?.requestMetadata?.searchQuery?.trim() ?: ""
        if (items.size != 1 || index !in listOf(0, C.INDEX_UNSET) ||
            !(id.startsWith("media:v1:") && id.length <= 4096 || id.isEmpty() && query.isNotEmpty() && query.length <= 256) ||
            position !in listOf(C.TIME_UNSET, 0L))
            return Futures.immediateFailedFuture(IllegalArgumentException("Choose a channel from XMWatch"))
        cancel()
        val next = UUID.randomUUID().toString()
        val future = SettableFuture.create<MediaSession.MediaItemsWithStartPosition>()
        token = next; pending = future
        val timeout = Runnable {
            if (isCurrent(next)) {
                complete(next, false)
                RadioEngine.get(checkNotNull(context)).let { it.noteInterruption("pause"); it.pause() }
            }
        }
        handler.postDelayed(timeout, 60_000)
        future.addListener({ handler.removeCallbacks(timeout); if (pending === future) { pending = null; token = "" } }, Executor { handler.post(it) })
        XMWatchAndroidAppDelegate.shared.onPrepareLibrary(id, if (id.isEmpty()) query else "", next)
        return future
    }
    private var context: android.content.Context? = null
    fun initialize(value: android.content.Context) { context = value.applicationContext }
    fun complete(value: String, success: Boolean) {
        if (!isCurrent(value)) return
        val engine = RadioEngine.get(checkNotNull(context))
        val item = engine.player.currentMediaItem
        if (!success || item == null || engine.preparing) pending?.setException(IllegalStateException("Channel unavailable; open XMWatch to reconnect"))
        else pending?.set(MediaSession.MediaItemsWithStartPosition(listOf(item), 0, engine.player.currentPosition.coerceAtLeast(0)))
    }
    fun cancel() { token = ""; pending?.cancel(false); pending = null }
}
