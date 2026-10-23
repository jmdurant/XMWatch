package xmwatch.android

import android.content.ComponentName
import android.content.Intent
import android.graphics.Rect
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.media3.common.MediaItem
import androidx.media3.session.MediaBrowser
import androidx.media3.session.MediaLibraryService.LibraryParams
import androidx.media3.session.SessionToken
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.TimeUnit

/** Uses the saved cookie, changes only a reversible local favorite, never tunes. */
@RunWith(AndroidJUnit4::class)
class RadioCatalogUpdatesLiveTest {
    private val instrumentation=InstrumentationRegistry.getInstrumentation()
    private val context=instrumentation.targetContext
    private fun <T> main(block:()->T):T { var value:T?=null;instrumentation.runOnMainSync { value=block() };@Suppress("UNCHECKED_CAST") return value as T }
    private fun waitFor(label:String,test:()->Boolean) {
        val end=SystemClock.elapsedRealtime()+30000
        while (SystemClock.elapsedRealtime()<end) { if (test()) return;Thread.sleep(100) }
        fail("Catalog notification check timed out: $label")
    }
    private fun root():AccessibilityNodeInfo? { instrumentation.uiAutomation.clearCache();return instrumentation.uiAutomation.rootInActiveWindow }
    private fun node(value:AccessibilityNodeInfo?,label:String):AccessibilityNodeInfo? {
        value ?: return null
        if (value.isVisibleToUser && (value.text?.toString()==label || value.contentDescription?.toString()==label)) return value
        for (i in 0 until value.childCount) node(value.getChild(i),label)?.let { return it }
        return null
    }
    private fun click(label:String) {
        waitFor(label) { node(root(),label)!=null };Thread.sleep(300)
        val current=checkNotNull(node(root(),label));val bounds=Rect();current.getBoundsInScreen(bounds)
        instrumentation.uiAutomation.executeShellCommand("input tap ${bounds.centerX()} ${bounds.centerY()}").let { ParcelFileDescriptor.AutoCloseInputStream(it).use { stream -> stream.readBytes() } }
        Thread.sleep(350)
    }
    @Test fun subscribedFavoritesRefreshWithoutReconnectingAndUnsubscribeStopsUpdates() {
        Assume.assumeTrue(InstrumentationRegistry.getArguments().getString("allowCatalogUpdates")=="true")
        assertTrue(RadioSecureStore.load(context).isNotBlank())
        val events=ConcurrentLinkedQueue<Pair<String,Int>>()
        val listener=object:MediaBrowser.Listener {
            override fun onChildrenChanged(browser:MediaBrowser,parentId:String,itemCount:Int,params:LibraryParams?) { events.add(parentId to itemCount) }
        }
        val browser=main { MediaBrowser.Builder(context,SessionToken(context,ComponentName(context,RadioPlaybackService::class.java))).setListener(listener).buildAsync() }.get(20,TimeUnit.SECONDS)
        fun children(id:String):List<MediaItem> {
            val result=main { browser.getChildren(id,0,100,null) }.get(40,TimeUnit.SECONDS)
            assertEquals(0,result.resultCode);return checkNotNull(result.value).toList()
        }
        try {
            val folders=children(MediaLibraryCatalog.ROOT_ID)
            val favoriteID=folders.single { it.mediaMetadata.title.toString()=="Favorites" }.mediaId
            val before=children(favoriteID).size
            assertEquals(0,main { browser.subscribe(favoriteID,null) }.get(20,TimeUnit.SECONDS).resultCode)
            waitFor("initial subscribed child count") { events.any { it.first==favoriteID && it.second==before } }
            events.clear()
            context.startActivity(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            click("Channels")
            click("Favorite SiriusXM Hits 1")
            waitFor("favorite addition/removal delivered to connected browser") { events.any { it.first==favoriteID && kotlin.math.abs(it.second-before)==1 } }
            val after=children(favoriteID).size;assertEquals(1,kotlin.math.abs(after-before))
            assertTrue(main { RadioEngine.get(context).player.mediaItemCount==0 })
            click("Favorite SiriusXM Hits 1")
            waitFor("favorite undo delivered to same browser") { events.any { it.first==favoriteID && it.second==before } }
            assertEquals(before,children(favoriteID).size)
            assertEquals(0,main { browser.unsubscribe(favoriteID) }.get(20,TimeUnit.SECONDS).resultCode)
            events.clear();main { RadioCatalogUpdates.changed() };Thread.sleep(700)
            assertFalse(events.any { it.first==favoriteID })
            instrumentation.sendStatus(0,android.os.Bundle().apply { putString("catalogUpdatesResult",JSONObject().put("savedCookieUsed",true).put("sameBrowserReceivedFavoriteChange",true).put("favoriteRestored",true).put("unsubscribeStoppedNotifications",true).put("playbackNotStarted",true).toString()) })
        } finally { main { browser.release() } }
    }
}
