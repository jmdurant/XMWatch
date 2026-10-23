package xmwatch.android

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.FileNotFoundException
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class ControllerArtworkTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun poster(): File = File(File(context.cacheDir, "posters").apply { mkdirs() }, "${UUID.randomUUID()}.jpg").also { file ->
        val image = Bitmap.createBitmap(1400, 900, Bitmap.Config.ARGB_8888)
        try { image.eraseColor(android.graphics.Color.GREEN); file.outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) } }
        finally { image.recycle() }
    }
    private fun unavailable(block: () -> Unit) {
        try { block(); fail("Artwork must be unavailable") } catch (_: FileNotFoundException) { }
    }
    private fun read(store: ControllerArtwork, uri: Uri): ByteArray = ParcelFileDescriptor.AutoCloseInputStream(store.open(uri)).use { it.readBytes() }

    @Test fun lazyOpaqueCoversDecodeAsBoundedJpegAndExpireWhenSourceIsRemoved() {
        val file = poster(); var loads = 0
        val store = ControllerArtwork(context, owner = { "fixture-owner" }) { id, done ->
            assertEquals("media:v1:fixture", id); loads++; done(file.path)
        }
        try {
            val address = requireNotNull(store.address("media:v1:fixture")); val uri = Uri.parse(address)
            assertEquals(address, store.address("media:v1:fixture")); assertEquals(0, loads)
            assertEquals("content", uri.scheme); assertFalse(address.contains(file.name)); assertFalse(address.contains("fixture"))
            val bytes = read(store, uri)
            assertEquals(0xff, bytes[0].toInt() and 255); assertEquals(0xd8, bytes[1].toInt() and 255)
            assertTrue(bytes.size <= 256 * 1024)
            val bitmap = requireNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size))
            try { assertTrue(maxOf(bitmap.width, bitmap.height) <= 512) } finally { bitmap.recycle() }
            assertArrayEquals(bytes, read(store, uri)); assertEquals(2, loads)
            file.delete(); unavailable { read(store, uri) }
        } finally { file.delete() }
    }

    @Test fun accountChangeDuringResolutionAndForgedAddressesCannotReadCachedArt() {
        val file = poster(); var account: String? = "first"; var changeWhileLoading = false
        val store = ControllerArtwork(context, owner = { account }) { _, done ->
            if (changeWhileLoading) account = "second"
            done(file.path)
        }
        try {
            val uri = Uri.parse(requireNotNull(store.address("media:v1:item")))
            read(store, uri)
            for (invalid in listOf(uri.buildUpon().appendQueryParameter("token", "secret").build(),
                uri.buildUpon().fragment("other").build(), uri.buildUpon().authority("another.app").build(),
                Uri.parse("content://${context.packageName}.artwork/v1/../../private"))) unavailable { read(store, invalid) }
            changeWhileLoading = true; unavailable { read(store, uri) }
            val newURI = requireNotNull(store.address("media:v1:item")); assertNotEquals(uri.toString(), newURI)
            unavailable { read(store, uri) }
            account = null; assertNull(store.address("media:v1:item")); unavailable { read(store, Uri.parse(newURI)) }
        } finally { file.delete() }
    }

    @Test fun arbitraryFilesSymlinksAndNonImagesAreRejected() {
        val original = poster(); val private = File(context.cacheDir, "controller-private-${UUID.randomUUID()}")
        val link = File(original.parentFile, "${UUID.randomUUID()}.jpg")
        var path = private.path
        val store = ControllerArtwork(context, owner = { "fixture" }) { _, done -> done(path) }
        try {
            private.writeBytes(original.readBytes())
            val uri = Uri.parse(requireNotNull(store.address("media:v1:test")))
            unavailable { read(store, uri) }
            android.system.Os.symlink(private.path, link.path); path = link.path
            unavailable { read(store, uri) }
            original.writeText("not an image"); path = original.path; unavailable { read(store, uri) }
            assertNull(store.address("https://private.invalid/image?token=secret"))
            assertNull(store.address("file:///private/art.jpg"))
        } finally { link.delete(); private.delete(); original.delete() }
    }

    @Test fun parallelCoverLoadsQueueBehindBoundedWorkers() {
        val file = poster(); val workers = java.util.concurrent.Executors.newFixedThreadPool(8)
        val store = ControllerArtwork(context, owner = { "fixture" }) { _, done ->
            Thread { Thread.sleep(100); done(file.path) }.start()
        }
        try {
            val requests = (0..7).map { index ->
                val uri = Uri.parse(requireNotNull(store.address("media:v1:parallel$index")))
                workers.submit<Boolean> { read(store, uri).isNotEmpty() }
            }
            requests.forEach { assertTrue(it.get(10, java.util.concurrent.TimeUnit.SECONDS)) }
        } finally { workers.shutdownNow(); file.delete() }
    }
}
