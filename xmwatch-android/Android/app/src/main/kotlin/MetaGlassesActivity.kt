package xmwatch.android

import android.Manifest
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import org.json.JSONObject

/** Native optional-feature settings. Leaving this screen keeps an active display session alive. */
class MetaGlassesActivity : ComponentActivity() {
    private lateinit var statusView: TextView
    private lateinit var devicesView: LinearLayout
    private lateinit var permissionButton: Button
    private lateinit var registerButton: Button
    private lateinit var unregisterButton: Button
    private lateinit var disconnectButton: Button
    private lateinit var firmwareButton: Button
    private lateinit var glassesAppButton: Button
    private val stateListener: () -> Unit = { runOnUiThread { refresh() } }
    private var pendingPermissionAction: (() -> Unit)? = null
    private val permissionRequest = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val pending = pendingPermissionAction
        pendingPermissionAction = null
        if (granted) { activate(); pending?.invoke() } else refresh()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android can restore this screen after process death without recreating MainActivity.
        MetaPlaybackBinding.configure(applicationContext)
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val pad = (20 * resources.displayMetrics.density).toInt()
            setPadding(pad, pad, pad, pad)
        }
        setContentView(ScrollView(this).apply { addView(content) })
        fun text(value: String, size: Float = 16f): TextView = TextView(this).apply {
            text = value; textSize = size; setPadding(0, 12, 0, 12); content.addView(this)
        }
        fun button(label: String, action: () -> Unit): Button = Button(this).apply {
            text = label; setOnClickListener { action() }; content.addView(this)
        }
        text("Meta glasses", 26f)
        text("Show the current player and playback controls on compatible Meta display glasses. Register this app in Meta AI, put on connected glasses, then select Connect display.")
        if (usesDeveloperModeConfiguration()) {
            text("This build uses Meta Developer Mode. Enable Developer Mode in Meta AI before registering.")
        }
        statusView = text("Checking glasses setup…")
        permissionButton = button("Allow Nearby devices") { requestPermission() }
        registerButton = button("Register with Meta AI") { withPermission { MetaGlassesController.register(this) } }
        unregisterButton = button("Unregister this app") { MetaGlassesController.unregister(this) }
        disconnectButton = button("Disconnect display") { MetaGlassesController.disconnectDisplay() }
        text("Discovered glasses", 20f)
        devicesView = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; content.addView(this) }
        text("Firmware updates change the glasses system software. A DAT glasses app update is separate and may be required before this app can use the display.")
        firmwareButton = button("Update glasses firmware in Meta AI") { MetaGlassesController.updateFirmware(this) }
        glassesAppButton = button("Update DAT glasses app in Meta AI") { MetaGlassesController.updateGlassesApp(this) }
        text("Standard Ray-Ban Meta glasses do not have a display. Pair them in Meta AI and Android Bluetooth, then play audio from your phone and choose the glasses as the audio output. Phone playback stays available regardless of display setup.")
        button("Open Bluetooth settings") { startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS)) }
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            runCatching { Class.forName("xmwatch.android.MetaGlassesMockActivity") }.getOrNull()?.let { mockClass ->
                button("Open mock glasses lab") { startActivity(Intent(this, mockClass)) }
            }
        }
        button("Done") { finish() }
        if (MetaGlassesController.hasBluetoothPermission(this)) activate()
        else if (savedInstanceState == null) requestPermission()
        refresh()
    }

    override fun onStart() {
        super.onStart()
        MetaGlassesController.addStateListener(stateListener)
        refresh()
    }

    override fun onResume() {
        super.onResume()
        if (MetaGlassesController.hasBluetoothPermission(this)) activate()
        refresh()
    }

    override fun onStop() {
        MetaGlassesController.removeStateListener(stateListener)
        super.onStop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (MetaGlassesController.hasBluetoothPermission(this)) activate() else requestPermission()
    }

    private fun requestPermission() {
        if (MetaGlassesController.hasBluetoothPermission(this)) activate()
        else permissionRequest.launch(Manifest.permission.BLUETOOTH_CONNECT)
    }

    private fun withPermission(action: () -> Unit) {
        if (MetaGlassesController.hasBluetoothPermission(this)) {
            MetaGlassesController.initialize(this); action()
        } else { pendingPermissionAction = action; requestPermission() }
    }

    private fun usesDeveloperModeConfiguration(): Boolean = runCatching {
        val metadata = packageManager.getApplicationInfo(packageName, PackageManager.GET_META_DATA).metaData
        metadata?.get("com.meta.wearable.mwdat.APPLICATION_ID")?.toString() == "0" &&
            metadata?.get("com.meta.wearable.mwdat.CLIENT_TOKEN")?.toString() == "0"
    }.getOrDefault(false)

    private fun activate() {
        MetaGlassesController.initialize(this)
        MetaGlassesController.handleIntent(this, intent)
    }

    private fun refresh() {
        if (!::statusView.isInitialized) return
        val permission = MetaGlassesController.hasBluetoothPermission(this)
        val state = runCatching { JSONObject(MetaGlassesController.stateSnapshot()) }.getOrDefault(JSONObject())
        val initialized = state.optBoolean("initialized")
        permissionButton.visibility = if (permission) View.GONE else View.VISIBLE
        registerButton.isEnabled = permission && initialized && state.optString("registration") !in listOf("REGISTERED", "REGISTERING", "UNREGISTERING")
        unregisterButton.isEnabled = initialized && state.optString("registration") == "REGISTERED"
        disconnectButton.isEnabled = state.optString("session", "STOPPED") != "STOPPED"
        firmwareButton.isEnabled = permission && initialized
        glassesAppButton.isEnabled = permission && initialized
        statusView.text = if (!permission) "Allow Nearby devices to use the optional glasses display. You can continue phone playback."
            else "${state.optString("status", "Open Meta glasses to begin.")}\nRegistration: ${state.optString("registration", "UNINITIALIZED")}\nSession: ${state.optString("session", "STOPPED")} · Display: ${state.optString("display", "STOPPED")}"
        devicesView.removeAllViews()
        val devices = state.optJSONArray("devices")
        if (devices == null || devices.length() == 0) {
            devicesView.addView(TextView(this).apply { text = "No glasses discovered. Connect glasses in Meta AI and keep Bluetooth enabled." })
        } else for (index in 0 until devices.length()) {
            val device = devices.getJSONObject(index)
            val compatible = device.optString("compatibility")
            val guidance = when {
                !device.optBoolean("displayCapable") -> "No display — use Bluetooth phone audio."
                compatible == "DEVICE_UPDATE_REQUIRED" -> "Update glasses firmware in Meta AI."
                compatible == "SDK_UPDATE_REQUIRED" -> "Update this phone app to a newer Meta DAT SDK."
                device.optString("linkState") != "CONNECTED" -> "Connect these glasses in Meta AI first."
                else -> "Ready for the optional display."
            }
            devicesView.addView(TextView(this).apply {
                text = "${device.optString("name", "Meta glasses")} · ${device.optString("linkState")}\n$guidance\nBattery: ${device.optInt("batteryLevel")}% · Firmware: ${device.optString("firmware")}"
                setPadding(0, 12, 0, 8)
            })
            if (device.optBoolean("displayCapable")) devicesView.addView(Button(this).apply {
                text = "Connect display"
                isEnabled = permission && device.optBoolean("eligible") && state.optString("registration") == "REGISTERED"
                setOnClickListener { MetaGlassesController.connectDisplay(device.getString("id")) }
            })
        }
    }
}
