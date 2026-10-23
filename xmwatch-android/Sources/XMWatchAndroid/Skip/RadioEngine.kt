package xmwatch.android

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.media3.common.*
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.hls.HlsMediaSource
import org.json.JSONObject

@UnstableApi
class RadioEngine private constructor(private val context: Context) {
    val player: ExoPlayer = ExoPlayer.Builder(context).build().apply {
        setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(), true)
        setHandleAudioBecomingNoisy(true)
        setWakeMode(C.WAKE_MODE_NETWORK)
    }
    val sessionPlayer by lazy { RadioSessionPlayer(this) }
    var preparing = false
    var revision = 0L
    private var failure = ""
    private var activePlan: RadioStreamPlan? = null
    var renewalCount = 0
        private set
    var metadataRevision = 0
        private set
    var commandHandler: ((String) -> Unit)? = null
    private fun artwork(address: String): android.net.Uri? = try {
        val uri = android.net.Uri.parse(address)
        ControllerArtwork.get(context).displayName(uri); uri
    } catch (_: Exception) { null }
    init {
        player.addListener(object : Player.Listener {
            override fun onPlayerError(error: PlaybackException) {
                preparing = player.playWhenReady
                failure = "Connection interrupted. Reconnecting…"
                Log.i("XMRadioPlayback", "error=${error.errorCodeName}")
            }
            override fun onPlayWhenReadyChanged(wants: Boolean, reason: Int) {
                if (!wants && (reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY ||
                    reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS)) noteInterruption("pause")
            }
            override fun onPlaybackStateChanged(state: Int) { Log.i("XMRadioPlayback", "state=$state playing=${player.isPlaying}") }
        })
    }
    fun begin(): Boolean = try {
        revision++; preparing = true; failure = ""; activePlan = null
        player.stop(); player.clearMediaItems()
        ContextCompat.startForegroundService(context, Intent().setClassName(context, "xmwatch.android.RadioPlaybackService").setAction("xmwatch.PREPARE"))
        true
    } catch (_: Exception) { preparing = false; failure = "Open XMWatch and try playback again."; false }
    fun load(json: String, id: String, title: String, category: String, art: String, play: Boolean = true): Boolean = try {
        val plan = RadioStreamPlan(json)
        val metadata = MediaMetadata.Builder().setTitle(title).setArtist(category).setIsPlayable(true)
        metadata.setArtworkUri(artwork(art))
        val item = MediaItem.Builder().setMediaId(id).setUri(plan.publicPlaylist)
            .setMimeType(MimeTypes.APPLICATION_M3U8).setMediaMetadata(metadata.build()).build()
        val source = HlsMediaSource.Factory(androidx.media3.datasource.DataSource.Factory { RadioStreamDataSource(plan) }).createMediaSource(item)
        activePlan = plan
        player.setMediaSource(source)
        preparing = false
        player.playWhenReady = play
        player.prepare()
        true
    } catch (_: Exception) { preparing = false; failure = "Could not open this radio channel."; false }
    fun noteInterruption(command: String) {
        revision++; preparing = false
        commandHandler?.invoke(command)
    }
    fun renew(json: String, expectedRevision: Long): Boolean = try {
        if (revision != expectedRevision) false else {
            checkNotNull(activePlan).renew(json)
            renewalCount++; Log.i("XMRadioPlayback", "sessionRenewed=$renewalCount")
            true
        }
    } catch (_: Exception) { false }
    fun updateMetadata(id: String, title: String, artist: String, art: String) {
        val item = player.currentMediaItem ?: return
        if (item.mediaId != id) return
        val builder = item.mediaMetadata.buildUpon().setTitle(title).setArtist(artist)
        builder.setArtworkUri(artwork(art))
        player.replaceMediaItem(player.currentMediaItemIndex, item.buildUpon().setMediaMetadata(builder.build()).build())
        metadataRevision++
    }
    fun pause() {
        RadioControllerPreparation.cancel()
        revision++; preparing = false; player.pause()
        if (player.playbackState == Player.STATE_IDLE) {
            context.stopService(Intent().setClassName(context, "xmwatch.android.RadioPlaybackService"))
        }
    }
    fun resume() { if (player.mediaItemCount > 0) player.play() }
    fun stop() {
        RadioControllerPreparation.cancel()
        revision++; preparing = false; activePlan = null; player.stop(); player.clearMediaItems()
        context.stopService(Intent().setClassName(context, "xmwatch.android.RadioPlaybackService"))
    }
    fun snapshot(): String = JSONObject().put("playing", player.isPlaying).put("wantsPlayback", player.playWhenReady)
        .put("buffering", preparing || player.playbackState == Player.STATE_BUFFERING)
        .put("audibleEpoch", if (player.currentLiveOffset != C.TIME_UNSET && player.currentLiveOffset >= 0) (System.currentTimeMillis() - player.currentLiveOffset) / 1000.0 else 0.0)
        .put("state", player.playbackState).put("hasSource", player.mediaItemCount > 0)
        .put("revision", revision).put("renewals", renewalCount).put("metadataRevision", metadataRevision)
        .put("position", player.currentPosition / 1000.0).put("error", failure)
        .put("renderedBuffers", player.audioDecoderCounters?.renderedOutputBufferCount ?: 0).toString()
    companion object {
        private var instance: RadioEngine? = null
        fun get(context: Context): RadioEngine = instance ?: RadioEngine(context.applicationContext).also { instance = it }
    }
}
