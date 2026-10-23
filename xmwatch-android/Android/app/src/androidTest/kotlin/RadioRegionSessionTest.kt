package xmwatch.android

import android.content.Context
import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class RadioRegionSessionTest {
    private fun fixture(block:(Context)->Unit) {
        val base=InstrumentationRegistry.getInstrumentation().targetContext;val prefix="test-owned-regions-${UUID.randomUUID()}-"
        val context=object:ContextWrapper(base) {
            override fun getSharedPreferences(name:String,mode:Int)=base.getSharedPreferences(prefix+name,mode)
        }
        try { block(context) } finally { listOf("radio-session","radio-region-US","radio-region-CA").forEach { base.deleteSharedPreferences(prefix+it) } }
    }
    private fun session(region:String)=JSONObject().put("version",1).put("region",region).put("deviceID","owned-device")
        .put("account",JSONObject().put("username","owned-$region")).put("cookies",org.json.JSONArray().put(JSONObject().put("value","owned-private-cookie-$region"))).toString()
    @Test fun bothRegionsRetainSeparateEncryptedCookiesAndUnknownRegionIsRejected() = fixture { context ->
        val us=session("US");val ca=session("CA")
        assertTrue(RadioSecureStore.save(context,us));assertTrue(RadioSecureStore.activateRegion(context,"CA"));assertEquals("",RadioSecureStore.load(context))
        assertTrue(RadioSecureStore.save(context,ca));assertTrue(RadioSecureStore.activateRegion(context,"US"));assertEquals(us,RadioSecureStore.load(context))
        assertTrue(RadioSecureStore.activateRegion(context,"CA"));assertEquals(ca,RadioSecureStore.load(context))
        assertFalse(RadioSecureStore.activateRegion(context,"invalid"));assertEquals(ca,RadioSecureStore.load(context))
        assertFalse(context.getSharedPreferences("radio-region-US",0).getString("ciphertext","")!!.contains("owned-private"))
    }
    @Test fun movingEncryptedUSCookieIntoCanadianSlotCannotChangeActiveSession() = fixture { context ->
        val us=session("US");assertTrue(RadioSecureStore.save(context,us));assertTrue(RadioSecureStore.activateRegion(context,"CA"));assertTrue(RadioSecureStore.activateRegion(context,"US"))
        val original=context.getSharedPreferences("radio-region-US",0);val target=context.getSharedPreferences("radio-region-CA",0)
        target.edit().putString("iv",original.getString("iv",null)).putString("ciphertext",original.getString("ciphertext",null)).commit()
        assertFalse(RadioSecureStore.activateRegion(context,"CA"));assertEquals(us,RadioSecureStore.load(context))
    }
    @Test fun signOutRemovesCurrentRegionCacheAndPreservesOtherRegion() = fixture { context ->
        val us=session("US");assertTrue(RadioSecureStore.save(context,us));assertTrue(RadioSecureStore.activateRegion(context,"CA"));assertTrue(RadioSecureStore.save(context,session("CA")))
        assertTrue(RadioSecureStore.activateRegion(context,"US"));assertTrue(RadioSecureStore.activateRegion(context,"CA"));RadioSecureStore.clear(context)
        assertEquals("",RadioSecureStore.load(context));assertTrue(RadioSecureStore.activateRegion(context,"US"));assertEquals(us,RadioSecureStore.load(context))
        assertTrue(RadioSecureStore.activateRegion(context,"CA"));assertEquals("",RadioSecureStore.load(context))
    }
}
