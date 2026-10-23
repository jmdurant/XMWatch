package xmwatch.android

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.media.session.MediaSessionManager
import android.net.Uri
import android.os.Binder
import android.os.ParcelFileDescriptor
import android.os.Process
import android.provider.OpenableColumns

/** Uses the same caller policy as the media library, including real UID checks. */
class RadioArtworkProvider : ContentProvider() {
    private val access by lazy { ControllerAccessPolicy.forContext(requireNotNull(context)) }
    private val artwork get() = ControllerArtwork.get(requireNotNull(context))
    override fun onCreate() = true
    private fun authorize() {
        val uid = Binder.getCallingUid()
        if (uid == Process.myUid()) return
        val name = callingPackage ?: throw SecurityException("Unknown artwork caller")
        val manager = requireNotNull(context).getSystemService(MediaSessionManager::class.java)
        val trusted = manager.isTrustedForMediaControl(MediaSessionManager.RemoteUserInfo(name, Binder.getCallingPid(), uid))
        if (!access.allows(uid, name, trusted)) throw SecurityException("Artwork requires an approved media client")
    }
    override fun getTypeAnonymous(uri: Uri): String? = null
    override fun getType(uri: Uri): String { authorize(); artwork.displayName(uri); return "image/jpeg" }
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        authorize()
        if (mode != "r") throw SecurityException("Artwork is read-only")
        return try { artwork.open(uri) }
        catch (error: java.io.FileNotFoundException) { throw error }
        catch (error: Exception) { throw java.io.FileNotFoundException("Artwork unavailable").apply { initCause(error) } }
    }
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        authorize()
        val name = artwork.displayName(uri)
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        require(columns.all { it == OpenableColumns.DISPLAY_NAME || it == OpenableColumns.SIZE })
        return MatrixCursor(columns).apply { addRow(columns.map { if (it == OpenableColumns.DISPLAY_NAME) name else null }.toTypedArray()) }
    }
    override fun insert(uri: Uri, values: ContentValues?): Uri = throw SecurityException("Artwork is read-only")
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = throw SecurityException("Artwork is read-only")
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = throw SecurityException("Artwork is read-only")
}
