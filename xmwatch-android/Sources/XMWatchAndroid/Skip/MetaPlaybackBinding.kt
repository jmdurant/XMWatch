package xmwatch.android

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.media3.common.util.UnstableApi
import org.json.JSONObject

/** Reuses the radio session's authenticated channel-selection command path. */
@UnstableApi
object MetaPlaybackBinding {
    private val main = Handler(Looper.getMainLooper())
    fun configure(context: Context) {
        val application = context.applicationContext
        MetaGlassesController.configure(
            snapshot = {
                check(Looper.myLooper() == Looper.getMainLooper())
                JSONObject(MetaPlaybackState.shared.snapshot())
            },
            command = { action ->
                main.post {
                    val metadata = JSONObject(MetaPlaybackState.shared.snapshot())
                    val engine = RadioEngine.get(application)
                    val session = engine.sessionPlayer
                    when (action) {
                        "playPause" -> if (metadata.optBoolean("canPlayPause")) {
                            if (metadata.optBoolean("playing") || engine.player.playWhenReady || engine.preparing) {
                                // A pending tune may not yet have playWhenReady set;
                                // explicitly cancel it using the same native handler.
                                if (engine.preparing && !engine.player.playWhenReady) {
                                    engine.noteInterruption("pause")
                                    engine.pause()
                                } else {
                                    session.pause()
                                }
                            } else {
                                session.play()
                            }
                        }
                        "previous" -> if (metadata.optBoolean("canPrevious")) session.seekToPreviousMediaItem()
                        "next" -> if (metadata.optBoolean("canNext")) session.seekToNextMediaItem()
                        // Live radio deliberately exposes no seek or rate controls.
                    }
                }
            }
        )
    }

}
