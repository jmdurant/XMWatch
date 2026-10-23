package xmwatch.android

import android.net.Uri
import android.util.Base64
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.*
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.UUID

/** Every Media3-facing URI is opaque. Only this source maps it to provider URLs. */
@UnstableApi
class RadioStreamPlan(json: String) {
    private val values = JSONObject(json)
    var playlist = values.getString("playlistURL")
        private set
    var segments = values.getString("segmentBaseURL")
        private set
    var query = values.getString("authorizationQuery")
        private set
    var key = Base64.decode(values.getString("key"), Base64.DEFAULT)
        private set
    private val channelID = values.optString("channelID")
    private var keyGeneration = 1L
    private val keys = linkedMapOf(1L to key.clone())
    val publicRoot = "xmwatch://live/${UUID.randomUUID()}"
    val publicPlaylist = "$publicRoot/playlist.m3u8"
    init {
        require(key.size == 16)
        require(Uri.parse(playlist).scheme == "https" && Uri.parse(segments).scheme == "https")
        require(Uri.parse(playlist).host == Uri.parse(segments).host)
    }
    @Synchronized fun playlistRequest(): Pair<String, String> = Pair(playlist, "$publicRoot/key/$keyGeneration")
    @Synchronized fun keyBytes(uri: Uri): ByteArray {
        require(uri.toString().startsWith("$publicRoot/key/"))
        val generation = uri.lastPathSegment?.toLongOrNull() ?: throw IOException("Invalid radio key")
        return keys[generation]?.clone() ?: throw IOException("Radio key expired")
    }
    @Synchronized fun renew(json: String) {
        val updated = RadioStreamPlan(json)
        require(updated.channelID == channelID)
        if (!key.contentEquals(updated.key)) {
            keyGeneration++
            keys[keyGeneration] = updated.key.clone()
            while (keys.size > 8) keys.remove(keys.keys.first())
        }
        playlist = updated.playlist; segments = updated.segments; query = updated.query; key = updated.key
    }
    fun rewrite(text: String, keyAddress: String = playlistRequest().second): ByteArray {
        require(text.startsWith("#EXTM3U"))
        fun segment(address: String): String {
            val name = Uri.parse(address).lastPathSegment ?: throw IOException("Missing radio segment")
            require(name.matches(Regex("[A-Za-z0-9_.-]+")) && name != "." && name != "..")
            return "$publicRoot/segment/$name"
        }
        return text.lineSequence().map { line ->
            when {
                line.startsWith("#EXT-X-KEY:") -> line.replace(Regex("URI=\"[^\"]*\""), "URI=\"$keyAddress\"")
                line.startsWith("#EXT-X-MAP:") -> Regex("URI=\"([^\"]*)\"").replace(line) { "URI=\"${segment(it.groupValues[1])}\"" }
                line.isNotBlank() && !line.startsWith("#") -> segment(line.trim())
                else -> line
            }
        }.joinToString("\n").toByteArray(Charsets.UTF_8)
    }
    @Synchronized fun segmentURL(uri: Uri): String {
        require(uri.toString().startsWith("$publicRoot/segment/"))
        val name = uri.lastPathSegment ?: throw IOException("Missing radio segment")
        require(name.matches(Regex("[A-Za-z0-9_.-]+")) && name != "." && name != "..")
        return segments + name + query
    }
}

@UnstableApi
class RadioStreamDataSource(private val plan: RadioStreamPlan) : DataSource {
    private var source: DataSource? = null
    private var address: Uri? = null
    override fun addTransferListener(listener: TransferListener) {}
    override fun getUri(): Uri? = address
    override fun getResponseHeaders(): Map<String, List<String>> = emptyMap()
    private fun http(): HttpDataSource = DefaultHttpDataSource.Factory()
        .setUserAgent("Mozilla/5.0 XMWatch/Android")
        .setConnectTimeoutMs(15000).setReadTimeoutMs(20000).createDataSource()
    override fun open(spec: DataSpec): Long {
        address = spec.uri
        try {
            val bytes: ByteArray? = when (spec.uri.toString()) {
                plan.publicPlaylist -> {
                    val upstream = http()
                    try {
                        val request = plan.playlistRequest()
                        upstream.open(DataSpec(Uri.parse(request.first)))
                        val output = ByteArrayOutputStream()
                        val buffer = ByteArray(16384)
                        while (true) {
                            val read = upstream.read(buffer, 0, buffer.size)
                            if (read == C.RESULT_END_OF_INPUT) break
                            if (output.size() + read > 2097152) throw IOException("Radio playlist too large")
                            output.write(buffer, 0, read)
                        }
                        plan.rewrite(output.toString("UTF-8"), request.second)
                    } finally { upstream.close() }
                }
                else -> if (spec.uri.toString().startsWith("${plan.publicRoot}/key/")) plan.keyBytes(spec.uri) else null
            }
            val delegate = if (bytes != null) ByteArrayDataSource(bytes) else http()
            source = delegate
            val target = if (bytes != null) spec else spec.buildUpon().setUri(plan.segmentURL(spec.uri)).build()
            return delegate.open(target)
        } catch (error: HttpDataSource.InvalidResponseCodeException) {
            throw IOException("Radio stream HTTP ${error.responseCode}")
        } catch (_: Exception) { throw IOException("Radio stream unavailable") }
    }
    override fun read(buffer: ByteArray, offset: Int, length: Int): Int = try {
        source?.read(buffer, offset, length) ?: C.RESULT_END_OF_INPUT
    } catch (_: Exception) { throw IOException("Radio stream interrupted") }
    override fun close() { try { source?.close() } finally { source = null; address = null } }
}
