package xmwatch.android

import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Process
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaLibraryService.MediaLibrarySession
import androidx.media3.session.SessionCommand
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class ControllerAccessPolicyTest {
    private val ownUid = Process.myUid()
    private val otherUid = ownUid + 5000
    private fun caller(name: String = "untrusted.client", uid: Int = otherUid, trusted: Boolean = false,
                       hints: Bundle = Bundle.EMPTY, verified: Boolean = false) =
        MediaSession.ControllerInfo.createTestOnlyControllerInfo(name, Process.myPid(), uid, 1, 1, trusted, hints, verified)
    private fun identity(uid: Int = otherUid, platform: Boolean = false, release: Boolean = false) =
        ControllerAccessPolicy.Identity(uid, platform, release)

    @Test fun ownSandboxAllowsInternalNamesButUnknownUidNeverDoes() {
        var lookups = 0
        val policy = ControllerAccessPolicy(ownUid) { lookups++; null }
        assertTrue(policy.allows(caller("synthetic.notification", ownUid)))
        assertFalse(policy.allows(caller("android", -1, trusted = true)))
        assertEquals(0, lookups)
        val placeholder = MediaSession.ControllerInfo.createTestOnlyControllerInfo(
            MediaSession.ControllerInfo.LEGACY_CONTROLLER_PACKAGE_NAME, -1, -1,
            MediaSession.ControllerInfo.LEGACY_CONTROLLER_VERSION, 0, false, Bundle.EMPTY, false)
        assertTrue("Legacy bootstrap must be able to select its session", policy.canRoute(placeholder))
        assertFalse("Session routing must not authenticate the anonymous placeholder", policy.allows(placeholder))
        val mediaButton = MediaSession.ControllerInfo.createTestOnlyControllerInfo(
            "xmwatch.fixture", -1, -1, androidx.media3.common.MediaLibraryInfo.VERSION_INT, 1, false,
            Bundle().apply { putString(androidx.media3.session.MediaSessionService.CONNECTION_HINT_KEY_CONTROLLER_INFO_TYPE,
                android.content.Intent.ACTION_MEDIA_BUTTON) }, false)
        assertTrue(policy.canRoute(mediaButton, "xmwatch.fixture"))
        assertFalse(policy.canRoute(mediaButton, "another.package"))
        assertFalse(policy.canRoute(mediaButton))
        assertFalse("Routing a media key must not authenticate an unknown controller", policy.allows(mediaButton))
        assertFalse(policy.canRoute(caller("android", -1, trusted = true)))
        assertFalse(policy.allows(caller()))
        assertEquals(1, lookups)
    }

    @Test fun forgedNamesUidsVerificationFlagsAndHintsCannotGrantAccess() {
        val policy = ControllerAccessPolicy(ownUid) { identity(uid = otherUid + 1, platform = true, release = true) }
        val hints = Bundle().apply {
            putInt("uid", ownUid); putBoolean("trusted", true)
            putString("packageName", "com.google.android.projection.gearhead")
        }
        assertFalse(policy.allows(caller("com.google.android.projection.gearhead", trusted = true, hints = hints, verified = true)))
        val absent = ControllerAccessPolicy(ownUid) { null }
        assertFalse(absent.allows(caller("android", Process.SYSTEM_UID, trusted = true)))
        assertFalse(absent.allows(caller(hints = hints, verified = true)))
    }

    @Test fun installedIdentityAllowsTrustedSystemAndPlatformCallers() {
        val plain = ControllerAccessPolicy(ownUid) { identity() }
        assertFalse(plain.allows(caller(verified = true)))
        assertTrue(plain.allows(caller(trusted = true)))
        // Older platform controllers may not have Media3's verified-name flag;
        // the installed-package UID lookup still supplies verified identity.
        assertTrue(plain.allows(caller(trusted = true, verified = false)))
        val platform = ControllerAccessPolicy(ownUid) { identity(platform = true) }
        assertTrue(platform.allows(caller()))
        val system = ControllerAccessPolicy(ownUid) { identity(uid = Process.SYSTEM_UID) }
        assertTrue(system.allows(caller("android", Process.SYSTEM_UID)))
    }

    @Test fun knownReleaseEvidenceAllowsCompanionsWithoutPrivilegedPermissions() {
        val known = ControllerAccessPolicy(ownUid) { name -> identity(release = name == "signed.companion") }
        assertTrue(known.allows(caller("signed.companion")))
        assertFalse(known.allows(caller("unsigned.companion", verified = true)))
        val wrongCertificate = ControllerAccessPolicy(ownUid) { identity() }
        assertFalse(wrongCertificate.allows(caller("com.google.android.projection.gearhead", verified = true)))
    }

    @Test fun pinsContainPublishedReleaseKeysAndExcludeDevelopmentKeys() {
        val pins = ControllerAccessPolicy.releaseCertificates
        assertEquals(setOf("com.google.android.projection.gearhead", "com.google.android.googlequicksearchbox",
            "com.google.android.carassistant", "com.google.android.wearable.app"), pins.keys)
        assertEquals(setOf("fdb00c43dbde8b51cb312aa81d3b5fa17713adb94b28f598d77f8eb89daceedf",
            "1ca8dcc0bed3cbd872d2cb791200c0292ca9975768a82d676b8b424fb65b5295"), pins["com.google.android.projection.gearhead"])
        assertTrue(pins.values.flatten().all { it.matches(Regex("[0-9a-f]{64}")) })
        assertFalse(pins.values.flatten().contains("1975b2f17177bc89a5dff31f9e64a6cae281a53dc1d1d59b1d147fe1c82afa00"))
        assertFalse(pins.containsKey("com.google.android.autosimulator"))
    }

    @Test fun realPackageManagerChecksIdentityAndActualCertificateBytes() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val access = ControllerAccessPolicy.forContext(context)
        assertTrue(access.allows(caller("android", Process.SYSTEM_UID)))
        assertFalse(access.allows(caller("android", otherUid, trusted = true, verified = true)))
        assertFalse(access.allows(caller("missing.controller.fixture", otherUid, trusted = true)))
        val packages = context.packageManager
        val info = packages.getPackageInfo(context.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        val bytes = requireNotNull(info.signingInfo).apkContentsSigners.single().toByteArray()
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        assertTrue(ControllerAccessPolicy.matchesCertificate(packages, context.packageName, setOf(digest)))
        assertFalse(ControllerAccessPolicy.matchesCertificate(packages, context.packageName, setOf("0".repeat(64))))
        assertFalse(ControllerAccessPolicy.matchesCertificate(packages, context.packageName, setOf("not-a-certificate")))
    }

    @Test fun sessionCallbackRejectsUnknownTokensAndGrantsValidatedCompanionCommands() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        lateinit var player: ExoPlayer
        lateinit var session: MediaLibrarySession
        val policy = ControllerAccessPolicy(ownUid) { name -> identity(release = name == "signed.companion") }
        val callback = ControllerAccessCallback(policy)
        instrumentation.runOnMainSync {
            player = ExoPlayer.Builder(instrumentation.targetContext).build()
            session = MediaLibrarySession.Builder(instrumentation.targetContext, player, callback).setId(UUID.randomUUID().toString()).build()
        }
        try {
            val rejected = callback.onConnectAsync(session, caller()).get(5, TimeUnit.SECONDS)
            assertFalse(rejected.isAccepted)
            val accepted = callback.onConnectAsync(session, caller("signed.companion")).get(5, TimeUnit.SECONDS)
            assertTrue(accepted.isAccepted)
            assertTrue(accepted.availablePlayerCommands.contains(Player.COMMAND_PLAY_PAUSE))
            assertTrue(accepted.availablePlayerCommands.contains(Player.COMMAND_SET_MEDIA_ITEM))
            assertTrue(accepted.availableSessionCommands.contains(SessionCommand.COMMAND_CODE_LIBRARY_GET_CHILDREN))
        } finally { instrumentation.runOnMainSync { session.release(); player.release() } }
    }
}
