package xmwatch.android

import android.app.Activity
import android.os.Bundle
import android.view.View
import android.webkit.WebView
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import com.meta.wearable.dat.mockdevice.MockDeviceKit
import com.meta.wearable.dat.mockdevice.api.GlassesModel
import com.meta.wearable.dat.mockdevice.api.MockDeviceKitConfig
import com.meta.wearable.dat.mockdevice.api.MockGlasses
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject

/** Debug-only host for the real DAT MockDeviceKit renderer. No mock is enabled by app launch. */
class MetaGlassesMockActivity : Activity() {
    companion object {
        const val ENABLE_MOCK = "xmwatch.android.action.ENABLE_META_SDK_MOCK"
        const val FIXTURE = "allowMetaGlassesFixture"
    }

    private val kit by lazy { MockDeviceKit.getInstance(this) }
    private lateinit var content: LinearLayout
    private var ownsMock = false
    private var ownsBinding = false
    private var originalBinding: Pair<() -> JSONObject, (String) -> Unit>? = null
    // This scope deliberately survives onDestroy until the SDK session is terminal.
    private val cleanupScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val retainedPreviews = mutableListOf<WebView>()
    var glasses: MockGlasses? = null
        private set
    var preview: WebView? = null
        private set
    val commands = mutableListOf<String>()
    var playback = JSONObject()
        private set

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        setContentView(content)
        content.addView(TextView(this).apply { text = "DAT 1.0.1 SDK display preview. Audio stays in XMWatch's phone playback route." })
        content.addView(Button(this).apply {
            text = "Start Meta Ray-Ban Display mock"
            setOnClickListener { startMock(false) }
        })
        if (intent.action == ENABLE_MOCK) startMock(intent.getBooleanExtra(FIXTURE, false))
    }

    fun startMock(fixture: Boolean) {
        check(!kit.isEnabled) { "A mock session is already owned by another caller" }
        if (fixture) {
            originalBinding = MetaGlassesController.capturePlaybackBinding()
            playback = JSONObject().put("title", "SDK fixture episode").put("subtitle", "SDK fixture creator")
                .put("detail", "Podcast · 1×").put("status", "Playing").put("playing", true)
                .put("positionMS", 42_000).put("durationMS", 600_000).put("rate", 1.0)
                .put("buffering", false).put("canPlayPause", true).put("canPrevious", true)
                .put("canNext", true).put("canSeek", true).put("canChangeRate", true)
                .put("seekBackSeconds", 15).put("seekForwardSeconds", 15)
            MetaGlassesController.configure(snapshot = { JSONObject(playback.toString()) }, command = { commands.add(it) })
            ownsBinding = true
        } else MetaPlaybackBinding.configure(applicationContext)
        kit.enable(MockDeviceKitConfig(initiallyRegistered = true, initialPermissionsGranted = true))
        ownsMock = true
        MetaGlassesController.initialize(this)
        pair(GlassesModel.META_RAYBAN_DISPLAY)
    }

    fun pair(model: GlassesModel): MockGlasses {
        val device = kit.pairGlasses(model).getOrThrow()
        glasses = device
        device.powerOn(); device.unfold(); device.don()
        showPreview(device)
        return device
    }

    fun showPreview(device: MockGlasses) {
        // Keep old preview bridges attached until session teardown. Instrumentation
        // can activate their real rendered buttons to verify stale input rejection.
        preview?.let {
            it.layoutParams = LinearLayout.LayoutParams(-1, 1)
            retainedPreviews.add(it)
        }
        val view: View = device.services.display.createPreviewView(this)
        check(view is WebView) { "SDK preview no longer uses WebView; update the renderer test adapter" }
        preview = view
        content.addView(view, LinearLayout.LayoutParams(-1, 0, 1f))
    }

    fun connect() = MetaGlassesController.connectDisplay(glasses!!.deviceIdentifier.identifier)

    private fun removePreview() {
        preview?.let { content.removeView(it); it.destroy() }
        preview = null
        retainedPreviews.forEach { content.removeView(it); it.destroy() }
        retainedPreviews.clear()
    }

    override fun onDestroy() {
        cleanupScope.launch {
            try {
                if (ownsMock) {
                    MetaGlassesController.disconnectDisplay()
                    val stopped = withTimeoutOrNull(15_000) {
                        while (true) {
                            val state = JSONObject(MetaGlassesController.stateSnapshot())
                            if (state.optString("session") == "STOPPED" && state.optString("display") == "STOPPED") break
                            delay(50)
                        }
                        true
                    } == true
                    // Keep SDK transport alive if teardown did not finish; the
                    // instrumentation timeout reports the stuck terminal state.
                    if (stopped) {
                        removePreview()
                        kit.pairedDevices.toList().forEach { kit.unpairDevice(it) }
                        kit.disable()
                        ownsMock = false
                    }
                }
            } finally {
                if (ownsBinding) {
                    originalBinding?.let { MetaGlassesController.restorePlaybackBinding(it) }
                    originalBinding = null
                    ownsBinding = false
                }
                cleanupScope.cancel()
            }
        }
        super.onDestroy()
    }
}
