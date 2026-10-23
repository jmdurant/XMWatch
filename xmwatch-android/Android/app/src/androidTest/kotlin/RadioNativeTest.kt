package xmwatch.android

import android.content.Context
import android.content.ContextWrapper
import android.net.Uri
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSpec
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@UnstableApi
class RadioNativeTest {
    @Test fun failedSessionCommitRestoresPreviousCredentials() {
        val base=InstrumentationRegistry.getInstrumentation().targetContext
        val prefs=base.getSharedPreferences("test-owned-failed-session",Context.MODE_PRIVATE)
        var failureMode=0
        val context=object: ContextWrapper(base) {
            override fun getSharedPreferences(name:String,mode:Int):android.content.SharedPreferences =
                object: android.content.SharedPreferences by prefs {
                    override fun edit():android.content.SharedPreferences.Editor {
                        val delegate=prefs.edit()
                        return object: android.content.SharedPreferences.Editor by delegate {
                            override fun putString(key:String,value:String?):android.content.SharedPreferences.Editor { delegate.putString(key,value);return this }
                            override fun remove(key:String):android.content.SharedPreferences.Editor { delegate.remove(key);return this }
                            override fun clear():android.content.SharedPreferences.Editor { delegate.clear();return this }
                            override fun commit():Boolean {
                                val written=delegate.commit()
                                // A failed disk outcome can still expose the new
                                // preference values to readers in this process.
                                if (failureMode==2) throw java.io.IOException("fixture failed disk commit")
                                return written && failureMode==0
                            }
                        }
                    }
                }
        }
        try {
            assertTrue(RadioSecureStore.save(context,"fixture-previous-credentials"))
            for (mode in 1..2) {
                failureMode=mode
                assertFalse(RadioSecureStore.save(context,"fixture-replacement-credentials"))
                assertEquals("fixture-previous-credentials",RadioSecureStore.load(context))
            }
        } finally { failureMode=0;RadioSecureStore.clear(context) }
    }

    private fun planJSON(keyByte: Int = 3, auth: String = "fixture") = JSONObject().put("playlistURL", "https://radio.example.com/live.m3u8?private=fixture")
        .put("segmentBaseURL", "https://radio.example.com/audio/").put("authorizationQuery", "?private=$auth")
        .put("key", android.util.Base64.encodeToString(ByteArray(16) { keyByte.toByte() }, android.util.Base64.NO_WRAP)).toString()
    private fun plan() = RadioStreamPlan(planJSON())

    @Test fun opaquePlaylistRoutesKeysAndSegmentsWithoutExportingCredentials() {
        val plan = plan()
        val text = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key/1\"\n#EXTINF:4,\nchannel_001.aac\n"
        val result = String(plan.rewrite(text), Charsets.UTF_8)
        assertTrue(result.contains("${plan.publicRoot}/key/1"))
        assertTrue(result.contains("${plan.publicRoot}/segment/channel_001.aac"))
        assertFalse(result.contains("private=fixture"))
        assertEquals("https://radio.example.com/audio/channel_001.aac?private=fixture",
            plan.segmentURL(Uri.parse("${plan.publicRoot}/segment/channel_001.aac")))
    }

    @Test fun media3ReadsActualAESKeyBytesWithOpaqueURI() {
        val plan = plan()
        val source = RadioStreamDataSource(plan)
        try {
            assertEquals(16L, source.open(DataSpec(Uri.parse("${plan.publicRoot}/key/1"))))
            val bytes = ByteArray(16)
            assertEquals(16, source.read(bytes, 0, bytes.size))
            assertArrayEquals(ByteArray(16) { 3 }, bytes)
            assertFalse(source.uri.toString().contains("example.com"))
        } finally { source.close() }
    }

    @Test fun renewalKeepsOpaqueRootAndOldKeysWhileNewRequestsUseFreshCredentials() {
        val plan = plan()
        val root = plan.publicRoot
        val original = plan.playlistRequest()
        plan.renew(planJSON(7, "renewed"))
        val renewed = plan.playlistRequest()
        assertEquals(root, plan.publicRoot)
        assertNotEquals(original.second, renewed.second)
        assertArrayEquals(ByteArray(16) { 3 }, plan.keyBytes(Uri.parse(original.second)))
        assertArrayEquals(ByteArray(16) { 7 }, plan.keyBytes(Uri.parse(renewed.second)))
        assertTrue(plan.segmentURL(Uri.parse("$root/segment/fixture.aac")).endsWith("?private=renewed"))
        val oldPlaylist = String(plan.rewrite("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key/1\"", original.second))
        assertTrue(oldPlaylist.contains(original.second))
    }

    @Test fun remotePauseInvalidatesPendingRenewalWithoutLoadingMedia() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val result = java.util.concurrent.atomic.AtomicBoolean(false)
        instrumentation.runOnMainSync {
            val engine = RadioEngine.get(instrumentation.targetContext)
            val previous = engine.commandHandler
            var command = ""
            engine.commandHandler = { command = it }
            try {
                engine.player.playWhenReady = true
                val revision = engine.revision
                engine.sessionPlayer.pause()
                result.set(engine.revision > revision && command == "pause" && !engine.renew(planJSON(), revision))
            } finally { engine.stop(); engine.commandHandler = previous }
        }
        assertTrue("Pause must invalidate late credential updates", result.get())
    }

    @Test fun remoteChannelCommandsReachSwiftWithoutSeekingTheDecoder() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            RadioEngine.get(instrumentation.targetContext).player.setMediaItem(
                androidx.media3.common.MediaItem.Builder().setMediaId("fixture-channel")
                    .setUri("https://fixture.invalid/live.m3u8").build())
        }
        // ForwardingSimpleBasePlayer observes the decoder through posted listener
        // events. Let those events reach an existing session before issuing keys.
        instrumentation.waitForIdleSync()
        instrumentation.runOnMainSync {
            val engine = RadioEngine.get(instrumentation.targetContext)
            val previous = engine.commandHandler
            val commands = mutableListOf<String>()
            engine.commandHandler = { commands.add(it) }
            try {
                val player = engine.sessionPlayer
                assertTrue(player.isCommandAvailable(androidx.media3.common.Player.COMMAND_SEEK_TO_NEXT))
                assertTrue(player.isCommandAvailable(androidx.media3.common.Player.COMMAND_SEEK_TO_PREVIOUS))
                assertFalse(player.isCommandAvailable(androidx.media3.common.Player.COMMAND_CHANGE_MEDIA_ITEMS))
                val revision = engine.revision
                player.seekToNext(); player.seekToPrevious()
                player.seekToNextMediaItem(); player.seekToPreviousMediaItem()
                assertEquals(listOf("next", "previous", "next", "previous"), commands)
                assertEquals(revision + 4, engine.revision)
                assertEquals("fixture-channel", engine.player.currentMediaItem?.mediaId)
                assertEquals(1, engine.player.mediaItemCount)
            } finally { engine.stop(); engine.commandHandler = previous }
        }
    }

    @Test fun secureSessionRoundTripAndTamperDetectionUseOwnedPreferences() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val context = object : ContextWrapper(base) {
            override fun getSharedPreferences(name: String, mode: Int) = base.getSharedPreferences("test-owned-$name", mode)
        }
        val fixture = "{\"cookies\":\"secret-fixture\"}"
        try {
            assertTrue(RadioSecureStore.save(context, fixture))
            assertEquals(fixture, RadioSecureStore.load(context))
            val prefs = context.getSharedPreferences("radio-session", Context.MODE_PRIVATE)
            val encrypted = prefs.getString("ciphertext", "")!!
            assertFalse(encrypted.contains("secret-fixture"))
            prefs.edit().putString("ciphertext", encrypted.reversed()).commit()
            assertEquals("", RadioSecureStore.load(context))
        } finally { RadioSecureStore.clear(context) }
    }
}
