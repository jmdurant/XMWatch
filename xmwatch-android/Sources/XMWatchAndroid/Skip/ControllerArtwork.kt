package xmwatch.android

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileNotFoundException
import java.io.ByteArrayOutputStream
import java.util.UUID
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Local, opaque artwork handles. Swift resolves authenticated images only when
 * a controller opens a cover; browsing never waits for image downloads. */
class ControllerArtwork(
    private val context: Context,
    private val owner: () -> String? = { RadioSecureStore.owner(context) },
    private val loadPath: (String, (String) -> Unit) -> Unit = { id, done ->
        Handler(Looper.getMainLooper()).post { XMWatchAndroidAppDelegate.shared.onControllerArtwork(id, done) }
    },
) {
    private data class Source(val id: String, val owner: String, val key: String)
    private val lock = Any()
    private val slots = Semaphore(4)
    private val sources = mutableMapOf<String, Source>()
    private val identifiers = mutableMapOf<String, String>()
    private var scope: String? = null
    private val authority get() = context.packageName + ".artwork"
    private val cache get() = File(context.cacheDir, "controller-artwork").apply { mkdirs() }

    fun address(id: String): String? = synchronized(lock) {
        val account = owner()
        if (scope != account) { sources.clear(); identifiers.clear(); scope = account }
        if (account == null || !id.startsWith("media:v1:") || id.length > 4096) return null
        val key = identifiers[id] ?: run {
            if (sources.size >= 10000) return null
            UUID.randomUUID().toString().also {
                identifiers[id] = it; sources[it] = Source(id, account, it)
            }
        }
        uri(key).toString()
    }

    private fun uri(key: String): Uri = Uri.Builder().scheme("content").authority(authority)
        .appendPath("v1").appendPath(key).build()

    private fun resolve(uri: Uri): Source = synchronized(lock) {
        val parts = uri.pathSegments
        if (uri.scheme != "content" || uri.authority != authority || uri.query != null || uri.fragment != null ||
            parts.size != 2 || parts[0] != "v1") throw FileNotFoundException("Invalid artwork address")
        val source = sources[parts[1]] ?: throw FileNotFoundException("Artwork expired; refresh the library")
        if (uri(source.key) != uri || owner() != source.owner) throw FileNotFoundException("Artwork account changed")
        source
    }

    fun displayName(uri: Uri): String = resolve(uri).key + ".jpg"

    /** No filesystem or remote address is accepted from a controller. The path
     * comes back from our Swift catalog and must be an app-owned artwork file. */
    private fun sourceFile(path: String): File {
        val file = File(path)
        if (!file.isAbsolute) throw FileNotFoundException("Artwork path is not absolute")
        if (!file.isFile) throw FileNotFoundException("Artwork file is missing")
        if (file.length() !in 1..MAX_SOURCE_BYTES) throw FileNotFoundException("Artwork file size is invalid")
        // Android can give Context an alias for its private data directory.
        // Accept that base alias, but no symlinks or traversal inside our stores.
        fun owned(base: File, relative: String): Boolean {
            val expected = File(base.canonicalFile, relative)
            return expected.path == expected.canonicalPath && file.canonicalPath == expected.path &&
                file.absolutePath in listOf(File(base, relative).absolutePath, expected.path)
        }
        val poster = file.name.matches(Regex("[0-9A-Fa-f-]{36}\\.jpg")) && owned(context.cacheDir, "posters/${file.name}")
        if (!poster) throw FileNotFoundException("Invalid artwork source")
        return file.canonicalFile
    }

    fun open(uri: Uri): ParcelFileDescriptor {
        if (Looper.myLooper() == Looper.getMainLooper()) throw FileNotFoundException("Load artwork on a worker")
        val source = resolve(uri)
        if (!slots.tryAcquire(15, TimeUnit.SECONDS)) throw FileNotFoundException("Artwork busy; retry")
        try {
            val result = AtomicReference("")
            val ready = CountDownLatch(1)
            loadPath(source.id) { path -> result.set(path); ready.countDown() }
            if (!ready.await(15, TimeUnit.SECONDS)) throw FileNotFoundException("Artwork request timed out")
            val input = sourceFile(result.get())
            fun stamp(): String = MessageDigest.getInstance("SHA-256").digest(
                "${input.path}:${input.lastModified()}:${input.length()}".toByteArray()).joinToString("") { "%02x".format(it.toInt() and 255) }
            val revision = stamp()
            synchronized(lock) {
                resolve(uri)
                val output = File(cache, "${source.key}-$revision.jpg")
                if (!output.isFile) {
                    val bytes = input.inputStream().use { stream ->
                        val bytes = ByteArrayOutputStream(); val buffer = ByteArray(32768)
                        while (true) {
                            val count = stream.read(buffer); if (count < 0) break
                            if (bytes.size() + count > MAX_SOURCE_BYTES) throw FileNotFoundException("Artwork too large")
                            bytes.write(buffer, 0, count)
                        }
                        bytes.toByteArray()
                    }
                    val thumbnail = MediaArtwork.thumbnail(bytes) ?: throw FileNotFoundException("Unsupported artwork")
                    if (!input.isFile || revision != stamp()) throw FileNotFoundException("Artwork changed")
                    val temporary = File.createTempFile("cover-", ".tmp", cache)
                    try {
                        temporary.writeBytes(thumbnail)
                        if (!temporary.renameTo(output)) throw FileNotFoundException("Could not cache artwork")
                    } finally { temporary.delete() }
                }
                resolve(uri)
                output.setLastModified(System.currentTimeMillis())
                val descriptor = ParcelFileDescriptor.open(output, ParcelFileDescriptor.MODE_READ_ONLY)
                val files = cache.listFiles()?.filter { it.extension == "jpg" }?.sortedBy { it.lastModified() } ?: emptyList()
                var count = files.size; var bytes = files.sumOf { it.length() }
                for (file in files) {
                    if (count <= 64 && bytes <= 8 * 1024 * 1024) break
                    if (file == output) continue
                    val length = file.length()
                    if (file.delete()) { count--; bytes -= length }
                }
                return descriptor
            }
        } finally { slots.release() }
    }

    companion object {
        private const val MAX_SOURCE_BYTES = 8L * 1024 * 1024
        private var shared: ControllerArtwork? = null
        @Synchronized fun get(context: Context): ControllerArtwork = shared ?: ControllerArtwork(context.applicationContext).also { shared = it }
    }
}
