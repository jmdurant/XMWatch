package xmwatch.android

import androidx.media3.common.util.UnstableApi
import androidx.media3.common.ForwardingSimpleBasePlayer
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

/** Explicit remote Pause/Stop must also cancel pending Swift renewals/recovery. */
@UnstableApi
class RadioSessionPlayer(private val engine: RadioEngine) : ForwardingSimpleBasePlayer(engine.player) {
    override fun getState(): SimpleBasePlayer.State {
        val state = super.getState()
        val commands = state.availableCommands.buildUpon()
            .add(Player.COMMAND_SET_MEDIA_ITEM).remove(Player.COMMAND_CHANGE_MEDIA_ITEMS)
        if (state.playlist.isNotEmpty()) {
            commands.add(Player.COMMAND_SEEK_TO_NEXT).add(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
                .add(Player.COMMAND_SEEK_TO_PREVIOUS).add(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
        }
        return state.buildUpon().setAvailableCommands(commands.build()).build()
    }
    // The session callback has installed a privately resolved source. A caller's
    // URI/headers/extras must never replace that decoder source.
    override fun handleSetMediaItems(items: List<androidx.media3.common.MediaItem>, index: Int, position: Long): ListenableFuture<*> = Futures.immediateVoidFuture()

    // A radio channel change asks Swift for a fresh authenticated stream; the
    // decoder's one-item playlist cannot implement these transport commands.
    override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
        when (seekCommand) {
            Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM -> engine.noteInterruption("next")
            Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> engine.noteInterruption("previous")
            else -> return super.handleSeek(mediaItemIndex, positionMs, seekCommand)
        }
        return Futures.immediateVoidFuture()
    }

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
        if (!playWhenReady) { RadioControllerPreparation.cancel(); engine.noteInterruption("pause") }
        val result = super.handleSetPlayWhenReady(playWhenReady)
        if (playWhenReady) engine.commandHandler?.invoke("resume")
        return result
    }
    override fun handleStop(): ListenableFuture<*> {
        RadioControllerPreparation.cancel()
        engine.noteInterruption("stop")
        return super.handleStop()
    }
}
