package xmwatch.android

import android.content.Intent
import android.graphics.Rect
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Assume
import org.junit.Test
import org.junit.runner.RunWith

/** Cookie-only US -> unsigned Canada -> saved US roundtrip, no provider login. */
@RunWith(AndroidJUnit4::class)
class RadioRegionLiveTest {
    private val instrumentation=InstrumentationRegistry.getInstrumentation()
    private val context=instrumentation.targetContext
    private fun waitFor(label:String,test:()->Boolean) {
        val end=SystemClock.elapsedRealtime()+45000
        while (SystemClock.elapsedRealtime()<end) { if (test()) return;Thread.sleep(100) }
        fail("Region roundtrip timed out: $label")
    }
    private fun root():AccessibilityNodeInfo? { instrumentation.uiAutomation.clearCache();return instrumentation.uiAutomation.rootInActiveWindow }
    private fun node(value:AccessibilityNodeInfo?,label:String):AccessibilityNodeInfo? {
        value ?: return null
        if (value.isVisibleToUser && (value.text?.toString()==label || value.contentDescription?.toString()==label)) return value
        for (i in 0 until value.childCount) node(value.getChild(i),label)?.let { return it }
        return null
    }
    private fun click(label:String) {
        instrumentation.sendStatus(0,android.os.Bundle().apply { putString("regionStage",label) })
        waitFor(label) { node(root(),label)!=null };Thread.sleep(250)
        val current=checkNotNull(node(root(),label));val bounds=Rect();current.getBoundsInScreen(bounds)
        instrumentation.uiAutomation.executeShellCommand("input tap ${bounds.centerX()} ${bounds.centerY()}").let { ParcelFileDescriptor.AutoCloseInputStream(it).use { input -> input.readBytes() } };Thread.sleep(500)
    }
    @Test fun regionRoundtripRestoresExistingUSCookieAndRegionPreferencesWithoutLogin() {
        Assume.assumeTrue(InstrumentationRegistry.getArguments().getString("allowRegionRoundtrip")=="true")
        val saved=RadioSecureStore.load(context);check(org.json.JSONObject(saved).getString("region")=="US")
        val owner=checkNotNull(RadioSecureStore.owner(context))
        // The test requires an unused Canadian slot; never clear an existing account.
        Assume.assumeTrue(context.getSharedPreferences("radio-region-CA",0).getString("ciphertext",null)==null)
        val before=context.getSharedPreferences("defaults",0).getString("xm.android.favorites",null)
        context.startActivity(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        waitFor("saved US channels") { node(root(),"Play SiriusXM Hits 1")!=null }
        click("Settings");click("United States");click("Canada")
        waitFor("Canada sign-in without US cookie") { node(root(),"Sign In")!=null && RadioSecureStore.load(context).isEmpty() }
        assertEquals("CA",context.getSharedPreferences("defaults",0).getString("xm.android.region",null))
        click("Canada");click("United States")
        waitFor("US cookie restores channels") { node(root(),"Play SiriusXM Hits 1")!=null }
        assertEquals(owner,RadioSecureStore.owner(context))
        assertEquals("US",context.getSharedPreferences("defaults",0).getString("xm.android.region",null))
        assertEquals(before ?: "[]",context.getSharedPreferences("defaults",0).getString("xm.android.favorites",null))
        instrumentation.runOnMainSync { assertTrue(RadioEngine.get(context).player.mediaItemCount==0) }
        instrumentation.sendStatus(0,android.os.Bundle().apply { putString("regionResult","{\"savedUSCookieRestored\":true,\"canadaDidNotReceiveUSCookie\":true,\"favoritesPreserved\":true,\"noCredentialsEntered\":true,\"playbackNotStarted\":true}") })
    }
}
