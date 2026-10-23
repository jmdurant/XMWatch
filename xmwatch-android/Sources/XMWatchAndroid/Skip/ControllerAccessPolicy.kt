package xmwatch.android

import android.content.Context
import android.content.pm.PackageManager
import android.os.Process
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaLibraryService.MediaLibrarySession
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

/** Identity comes from Media3's caller UID plus installed-package evidence,
 * never a connection hint or a caller-supplied package name alone. */
class ControllerAccessPolicy(
    private val ownUid: Int,
    private val lookup: (String) -> Identity?,
) {
    data class Identity(val uid: Int, val platformSigned: Boolean, val knownReleaseSigned: Boolean)

    /** Legacy onBind has not identified the browser yet. Selecting a session
     * for that internal sentinel grants no access: onConnectAsync must still
     * authenticate the real caller before the legacy root/token is returned. */
    fun canRoute(controller: MediaSession.ControllerInfo, servicePackage: String? = null): Boolean =
        (controller.uid == -1 && controller.packageName == MediaSession.ControllerInfo.LEGACY_CONTROLLER_PACKAGE_NAME &&
            controller.controllerVersion == MediaSession.ControllerInfo.LEGACY_CONTROLLER_VERSION) ||
        // Media3 creates this second routing placeholder inside onStartCommand
        // for a media key delivered to our private service by the protected
        // receiver. It does not represent an authenticated controller connection.
        (servicePackage != null && controller.uid == -1 && controller.packageName == servicePackage &&
            controller.controllerVersion == androidx.media3.common.MediaLibraryInfo.VERSION_INT &&
            controller.connectionHints.getString(androidx.media3.session.MediaSessionService.CONNECTION_HINT_KEY_CONTROLLER_INFO_TYPE) == android.content.Intent.ACTION_MEDIA_BUTTON) ||
        allows(controller)

    fun allows(controller: MediaSession.ControllerInfo): Boolean = allows(controller.uid, controller.packageName, controller.isTrusted)

    fun allows(uid: Int, packageName: String, trusted: Boolean): Boolean {
        if (uid < 0) return false
        // Internal notification controllers can use a synthetic package name.
        // The OS/Media3 caller UID still puts them in this app's sandbox.
        if (uid == ownUid) return true
        val identity = lookup(packageName) ?: return false
        if (identity.uid != uid) return false
        return uid == Process.SYSTEM_UID || trusted || identity.platformSigned || identity.knownReleaseSigned
    }

    companion object {
        // Release keys only, from Google's UAMP allowed_media_browser_callers.xml:
        // https://github.com/android/uamp/blob/main/common/src/main/res/xml/allowed_media_browser_callers.xml
        // Android's hasSigningCertificate verifies current certificates and
        // authenticated rotation history. Do not add simulator/development keys.
        val releaseCertificates = mapOf(
            "com.google.android.projection.gearhead" to setOf(
                "fdb00c43dbde8b51cb312aa81d3b5fa17713adb94b28f598d77f8eb89daceedf",
                "1ca8dcc0bed3cbd872d2cb791200c0292ca9975768a82d676b8b424fb65b5295"),
            "com.google.android.googlequicksearchbox" to setOf(
                "f0fd6c5b410f25cb25c3b53346c8972fae30f8ee7411df910480ad6b2d60db83"),
            "com.google.android.carassistant" to setOf(
                "74b6fbf710e8d90d44d340125889b42306a62c4379d0e5a66220e3a68abf90e2"),
            "com.google.android.wearable.app" to setOf(
                "85cd5973541be6f477d847a0bcc6aa2527684b819cd5968529664cb07157b6fe"),
        )

        fun matchesCertificate(packages: PackageManager, name: String, digests: Set<String>): Boolean =
            digests.any { digest ->
                if (digest.length != 64 || digest.any { it !in '0'..'9' && it !in 'a'..'f' }) false
                else packages.hasSigningCertificate(name,
                    digest.chunked(2).map { it.toInt(16).toByte() }.toByteArray(), PackageManager.CERT_INPUT_SHA256)
            }

        fun forContext(context: Context): ControllerAccessPolicy {
            val packages = context.packageManager
            return ControllerAccessPolicy(Process.myUid()) { name ->
                try {
                    val uid = packages.getApplicationInfo(name, 0).uid
                    val platform = packages.checkSignatures(name, "android") == PackageManager.SIGNATURE_MATCH
                    val release = releaseCertificates[name]?.let { matchesCertificate(packages, name, it) } == true
                    Identity(uid, platform, release)
                } catch (_: PackageManager.NameNotFoundException) { null }
                  catch (_: SecurityException) { null }
            }
        }
    }
}

/** Gate direct session-token connections as well as service-bound browsers.
 * Explicitly grant the standard commands to a validated release-signed caller
 * even if it lacks Android's privileged media-control permission. The player
 * still intersects these commands and validates every source/queue mutation. */
open class ControllerAccessCallback(private val access: ControllerAccessPolicy) : MediaLibrarySession.Callback {
    override fun onConnectAsync(session: MediaSession, controller: MediaSession.ControllerInfo): ListenableFuture<MediaSession.ConnectionResult> =
        Futures.immediateFuture(if (access.allows(controller)) MediaSession.ConnectionResult.accept(
            MediaSession.ConnectionResult.DEFAULT_SESSION_AND_LIBRARY_COMMANDS,
            MediaSession.ConnectionResult.DEFAULT_PLAYER_COMMANDS)
        else MediaSession.ConnectionResult.reject())
}
