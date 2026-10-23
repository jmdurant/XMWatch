package xmwatch.android

import android.content.Intent
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** No account, HTTP, launcher mutations or playback required. */
@RunWith(AndroidJUnit4::class)
class PhoneAutomationIntentTest {
    private fun intent(path: String) = Intent(PhoneAutomation.ACTION, Uri.parse("xmwatch://automation/$path"))
    @Test fun acceptsOnlyPublicBoundedCommandSelectors() {
        assertEquals("42", PhoneAutomation.parse(intent("tune?number=42&region=CA"))?.number)
        assertEquals("hits", PhoneAutomation.parse(intent("tune?channelID=hits&region=US"))?.channelID)
        assertEquals("Classic Rock", PhoneAutomation.parse(intent("pick?query=Classic%20Rock"))?.query)
        for (command in listOf("pause", "resume", "next", "previous")) {
            assertEquals(command, PhoneAutomation.parse(intent(command))?.command)
        }
        assertEquals("pick", PhoneAutomation.parse(intent("pick").setAction(Intent.ACTION_VIEW))?.command)
        for (path in listOf("tune", "tune?number=42&channelID=hits", "tune?number=42&number=43",
            "tune?number=42&region=GB", "tune?query=", "pick?channelID=hits", "pause?query=hits",
            "pick?query=https%3A%2F%2Fexample.com", "pick?query=user%40example.com", "pick?query=password%3Dsecret",
            "pick?query=%0A", "pick?token=secret", "pick/extra", "unknown", "pick?query=" + "x".repeat(161))) {
            assertNull(path, PhoneAutomation.parse(intent(path)))
        }
        for (uri in listOf("https://automation/pick", "xmwatch://other/pick", "xmwatch://user@automation/pick",
            "xmwatch://automation:80/pick", "xmwatch://automation/pick#extra")) {
            assertNull(uri, PhoneAutomation.parse(Intent(PhoneAutomation.ACTION, Uri.parse(uri))))
        }
        assertNull(PhoneAutomation.parse(intent("pause").setAction(Intent.ACTION_SEND)))
    }
    @Test fun consumedLaunchCannotReplayButFreshRestoredTaskDeliveryCanRun() {
        val incoming = intent("pause")
        val fingerprint = checkNotNull(PhoneAutomation.fingerprint(incoming))
        assertEquals("pause", PhoneAutomation.consume(incoming)?.command)
        assertNull(incoming.data)
        assertEquals(Intent.ACTION_MAIN, incoming.action)
        assertNull(PhoneAutomation.consume(incoming))
        val previous = PhoneAutomation.Delivery("old-delivery", fingerprint)
        // Saved Activity state does not imply a newly delivered deep link was consumed.
        assertEquals("pause", PhoneAutomation.consume(intent("pause"), previous)?.command)
        assertEquals("pick", PhoneAutomation.consume(intent("pick"), previous)?.command)
        assertNull(PhoneAutomation.consume(intent("pause").addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY), previous))
        // A history launch with a different command is not the old playback intent.
        assertEquals("pick", PhoneAutomation.consume(intent("pick").addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY), previous)?.command)
    }
    @Test fun publishedChannelIdentityIsExplicitRegionalAndContainsNoAccountData() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val us = PhoneAutomation.channelIntent(context, "US", "hits")
        assertEquals("xmwatch.android.MainActivity", us.component?.className)
        assertEquals(context.packageName, us.component?.packageName)
        assertEquals(PhoneAutomation.Request("tune", channelID = "hits", region = "US"), PhoneAutomation.parse(us))
        assertTrue(us.flags and Intent.FLAG_ACTIVITY_SINGLE_TOP != 0)
        assertEquals(PhoneAutomation.shortcutID("US", "hits"), PhoneAutomation.shortcutID("US", "hits"))
        assertNotEquals(PhoneAutomation.shortcutID("US", "hits"), PhoneAutomation.shortcutID("CA", "hits"))
        assertTrue(PhoneAutomation.shortcutID("US", "hits").matches(Regex("channel-US-[a-f0-9]{24}")))
        assertNull(us.extras)
    }
}
