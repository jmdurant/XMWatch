package xmwatch.android

import android.content.Intent
import android.os.SystemClock
import android.webkit.WebView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.meta.wearable.dat.mockdevice.MockDeviceKit
import com.meta.wearable.dat.mockdevice.api.GlassesModel
import org.json.JSONObject
import org.json.JSONTokener
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Opt-in integration checks through DAT 1.0.1's real session, renderer and input path. */
@RunWith(AndroidJUnit4::class)
class MetaGlassesDisplayTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private fun state(): JSONObject {
        var value = "{}"
        main { value = MetaGlassesController.stateSnapshot() }
        return JSONObject(value)
    }
    private fun await(message: String, predicate: () -> Boolean) {
        val until = SystemClock.elapsedRealtime() + 20_000
        while (SystemClock.elapsedRealtime() < until) {
            if (predicate()) return
            SystemClock.sleep(100)
        }
        fail("$message; controller=${state()}")
    }
    private fun js(view: WebView, script: String): String {
        val done = CountDownLatch(1)
        var result = "null"
        main { view.evaluateJavascript(script) { result = it; done.countDown() } }
        assertTrue("SDK preview JavaScript timed out", done.await(5, TimeUnit.SECONDS))
        return JSONTokener(result).nextValue().toString()
    }
    private fun text(view: WebView) = js(view, "document.body.innerText")

    private fun retainRenderedInput(view: WebView) {
        // Keep the real last SDK-rendered DOM and its own click handlers while
        // the controller tears down its session. Only incoming preview painting
        // is paused; the SDK's outgoing native input bridge stays intact.
        assertEquals("retained", js(view, """(() => {
            const bridge = window.MockDisplayBridge;
            if (!bridge || typeof bridge.onmessage !== 'function') return 'missing SDK preview bridge';
            bridge.onmessage = () => {};
            return 'retained';
        })()"""))
    }

    // DOM activation uses the SDK-rendered button's own onClick. The SDK assigns
    // and forwards its identifier; this test neither predicts nor invents IDs.
    private fun click(view: WebView, title: String) {
        val quoted = JSONObject.quote(title)
        val script = """(() => {
            const label = $quoted;
            const nodes = Array.from(document.querySelectorAll('button,[role="button"]'));
            const matches = nodes.filter(e => [e.innerText,e.textContent,e.getAttribute('aria-label'),e.getAttribute('title')]
                .some(v => v && v.trim() === label));
            if (matches.length !== 1) return 'matches:' + matches.length + ':' + nodes.map(e=>e.outerHTML).join('\n');
            matches[0].click(); return 'clicked';
        })()"""
        await("SDK-rendered button missing: $title") { js(view, script) == "clicked" }
    }
    private fun withMock(test: (MetaGlassesMockActivity) -> Unit) {
        assumeTrue("Requires the account-preserving Meta SDK fixture harness",
            InstrumentationRegistry.getArguments().getString("allowMetaGlassesFixture") == "true")
        val activity = instrumentation.startActivitySync(Intent(context, MetaGlassesMockActivity::class.java)
            .setAction(MetaGlassesMockActivity.ENABLE_MOCK)
            .putExtra(MetaGlassesMockActivity.FIXTURE, true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MetaGlassesMockActivity
        try {
            await("Mock device did not become eligible") {
                val devices = state().optJSONArray("devices")
                state().optString("registration") == "REGISTERED" && devices != null &&
                    (0 until devices.length()).any { devices.getJSONObject(it).optBoolean("eligible") }
            }
            test(activity)
        } finally {
            main { activity.finish() }
            await("MockDeviceKit survived activity teardown") { !MockDeviceKit.getInstance(context).isEnabled }
            instrumentation.waitForIdleSync()
            assertFalse("MockDeviceKit survived activity teardown", MockDeviceKit.getInstance(context).isEnabled)
            assertEquals("Session teardown did not finish", "STOPPED", state().optString("session"))
            assertEquals("Display teardown did not finish", "STOPPED", state().optString("display"))
        }
    }
    private fun started(activity: MetaGlassesMockActivity): WebView {
        main { activity.connect() }
        await("Real DAT display did not START") { state().optString("display") == "STARTED" }
        val view = activity.preview!!
        await("SDK renderer did not show current metadata") { text(view).contains("SDK fixture episode") && text(view).contains("SDK fixture creator") }
        return view
    }

    @Test fun realSDKRendersMetadataAndEveryControlDispatchesExactlyOnce() = withMock { activity ->
        val view = started(activity)
        val buttons = listOf("Previous" to "previous", "Pause" to "playPause", "Next" to "next",
            "−15s" to "seekBack", "+15s" to "seekForward", "1.0×" to "rate")
        val expected = mutableListOf<String>()
        for ((title, command) in buttons) {
            click(view, title)
            expected.add(command)
            await("$title did not reach the owned playback callback") {
                var actual = emptyList<String>(); main { actual = activity.commands.toList() }; actual == expected
            }
        }
        main { activity.playback.put("title", "Updated SDK metadata").put("subtitle", "Updated creator") }
        await("Display did not refresh playback metadata") { text(view).contains("Updated SDK metadata") && text(view).contains("Updated creator") }
        SystemClock.sleep(600)
        main { assertEquals(expected, activity.commands) }
    }

    @Test fun sessionReplacementDisconnectAndReconnectDiscardOldCallbacks() = withMock { activity ->
        val oldView = started(activity)
        retainRenderedInput(oldView)
        val old = activity.glasses!!
        main { activity.pair(GlassesModel.META_RAYBAN_DISPLAY) }
        await("Replacement device did not become eligible") {
            val devices = state().optJSONArray("devices")
            devices != null && (0 until devices.length()).any {
                devices.getJSONObject(it).optString("id") == activity.glasses!!.deviceIdentifier.identifier &&
                    devices.getJSONObject(it).optBoolean("eligible")
            }
        }
        main { activity.connect() }
        await("Replacement display did not START") { state().optString("display") == "STARTED" }
        await("Replacement did not render") { text(activity.preview!!).contains("SDK fixture episode") }
        click(oldView, "Next")
        SystemClock.sleep(600)
        main { assertTrue("Old SDK preview dispatched into replacement", activity.commands.isEmpty()) }
        main { old.doff(); old.powerOff() }
        SystemClock.sleep(600)
        assertEquals("Old session state stopped the replacement", "STARTED", state().optString("display"))
        click(activity.preview!!, "Next")
        await("Replacement input failed") { var count = 0; main { count = activity.commands.size }; count == 1 }
        val disconnectedView = activity.preview!!
        retainRenderedInput(disconnectedView)
        main { MetaGlassesController.disconnectDisplay() }
        await("Disconnect retained the session") {
            state().optString("session") == "STOPPED" && state().optString("display") == "STOPPED"
        }
        click(disconnectedView, "Next")
        SystemClock.sleep(600)
        main { assertEquals("Disconnected SDK preview dispatched playback", listOf("next"), activity.commands) }
        main { activity.showPreview(activity.glasses!!) }
        started(activity)
        click(activity.preview!!, "Next")
        await("Reconnect input failed") { var count = 0; main { count = activity.commands.size }; count == 2 }
        SystemClock.sleep(600)
        main { assertEquals(listOf("next", "next"), activity.commands) }
    }

    @Test fun standardRayBanCannotStartDisplayOrDispatchPlayback() = withMock { activity ->
        main {
            val kit = MockDeviceKit.getInstance(context)
            kit.unpairDevice(activity.glasses!!)
            activity.pair(GlassesModel.RAYBAN_META)
        }
        await("Standard Ray-Ban metadata missing") {
            val devices = state().optJSONArray("devices")
            devices != null && devices.length() == 1 && !devices.getJSONObject(0).optBoolean("displayCapable", true)
        }
        main { activity.connect() }
        SystemClock.sleep(1000)
        assertNotEquals("STARTED", state().optString("display"))
        main { assertTrue("Standard glasses changed phone playback", activity.commands.isEmpty()) }
    }

    @Test fun unregistrationClosesActiveDisplayAndDropsInput() = withMock { activity ->
        val view = started(activity)
        retainRenderedInput(view)
        // DAT 1.0.1's FakeIntentLauncher unregisters synchronously and returns
        // AlreadyHandled. UNREGISTERING can be conflated before observation.
        // Its registrar monitor yields UNAVAILABLE on this hardware-free AVD;
        // AVAILABLE requires the SDK's real device detection provider to find
        // a target. simulateRegistrationOutcome configures the next operation.
        main {
            MockDeviceKit.getInstance(context).simulateRegistrationOutcome(true)
            MetaGlassesController.unregister(activity)
        }
        await("SDK did not finish unregistration") { state().optString("registration") == "UNAVAILABLE" }
        await("Unregistration retained discovered devices") { state().optJSONArray("devices")?.length() == 0 }
        await("Unregistration retained an active session") {
            state().optString("session") == "STOPPED" && state().optString("display") == "STOPPED"
        }
        click(view, "Next")
        SystemClock.sleep(600)
        main { assertTrue(activity.commands.isEmpty()) }
    }
}
