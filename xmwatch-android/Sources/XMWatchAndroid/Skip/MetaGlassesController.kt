package xmwatch.android

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.registration.RegistrationRequest
import com.meta.wearable.dat.core.selectors.SpecificDeviceSelector
import com.meta.wearable.dat.core.session.DeviceSession
import com.meta.wearable.dat.core.session.DeviceSessionState
import com.meta.wearable.dat.core.types.*
import com.meta.wearable.dat.display.Display
import com.meta.wearable.dat.display.addDisplay
import com.meta.wearable.dat.display.types.DisplayState
import com.meta.wearable.dat.display.views.ActionRole
import com.meta.wearable.dat.display.views.ContentScope
import com.meta.wearable.dat.display.views.Direction
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArraySet

/** Optional DAT display companion. All SDK work is confined to the main dispatcher. */
object MetaGlassesController {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val operations = Mutex()
    private val listeners = CopyOnWriteArraySet<() -> Unit>()
    private var appContext: Context? = null
    private var initialized = false
    private var registration = "UNINITIALIZED"
    private var sessionState = "STOPPED"
    private var displayState = "STOPPED"
    private var status = "Open Meta glasses to set up an optional display."
    private var error = ""
    private val metadata = linkedMapOf<DeviceIdentifier, Device>()
    private val metadataJobs = mutableMapOf<DeviceIdentifier, Job>()
    private var provider: () -> JSONObject = { JSONObject() }
    private var command: (String) -> Unit = {}
    private var generation = 0L
    private var current: Attempt? = null
    @Volatile private var published = "{}"

    private class Attempt(val generation: Long, val session: DeviceSession) {
        var display: Display? = null
        val jobs = mutableListOf<Job>()
        var stopping = false
        var displayWasStarted = false
        var pending: String? = null
        var sent: String? = null
        val updates = Channel<Unit>(Channel.CONFLATED)
    }

    fun configure(snapshot: () -> JSONObject, command: (String) -> Unit) {
        scope.launch { provider = snapshot; this@MetaGlassesController.command = command }
    }

    // Captured only by the optional debug mock screen, so it restores the live player on exit.
    fun capturePlaybackBinding(): Pair<() -> JSONObject, (String) -> Unit> = Pair(provider, command)
    fun restorePlaybackBinding(binding: Pair<() -> JSONObject, (String) -> Unit>) {
        configure(binding.first, binding.second)
    }

    fun open(context: Context) {
        context.startActivity(Intent().setClassName(context, "xmwatch.android.MetaGlassesActivity")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP))
    }

    fun addStateListener(listener: () -> Unit) { listeners.add(listener) }
    fun removeStateListener(listener: () -> Unit) { listeners.remove(listener) }
    fun stateSnapshot(): String = published
    fun hasBluetoothPermission(context: Context): Boolean = Build.VERSION.SDK_INT < 31 ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    fun initialize(context: Context) {
        scope.launch {
            appContext = context.applicationContext
            if (initialized) return@launch
            if (!hasBluetoothPermission(context)) {
                status = "Allow Nearby devices in Meta glasses settings to discover glasses."
                publish(); return@launch
            }
            try {
                val result = Wearables.initialize(context.applicationContext)
                // MockDeviceKit and another optional DAT entry point may already own initialization.
                // The SDK returns ALREADY_INITIALIZED only when its singleton instance exists.
                if (result.isFailure && result.errorOrNull() != WearablesError.ALREADY_INITIALIZED) {
                    report("Meta glasses setup: ${result.errorOrNull()}"); return@launch
                }
                initialized = true
                error = ""
                status = "Register with Meta AI, then choose a connected display device."
                scope.launch(start = CoroutineStart.UNDISPATCHED) {
                    Wearables.registrationState.collect {
                        registration = it.name
                        if (it != RegistrationState.REGISTERED && current != null) disconnectDisplay()
                        publish()
                    }
                }
                scope.launch(start = CoroutineStart.UNDISPATCHED) {
                    Wearables.registrationErrorStream.collect { report("Registration: $it") }
                }
                scope.launch(start = CoroutineStart.UNDISPATCHED) {
                    Wearables.devices.collect { identifiers ->
                        (metadataJobs.keys - identifiers).forEach { metadataJobs.remove(it)?.cancel(); metadata.remove(it) }
                        identifiers.forEach { id ->
                            if (id !in metadataJobs) {
                                Wearables.devicesMetadata[id]?.let { flow ->
                                    metadataJobs[id] = scope.launch {
                                        flow.collect { device -> metadata[id] = device; publish() }
                                    }
                                }
                            }
                        }
                        publish()
                    }
                }
                publish()
            } catch (failure: Exception) { report("Meta glasses setup failed: ${failure.message}") }
        }
    }

    fun register(activity: Activity) {
        initialize(activity)
        scope.launch {
            if (initialized && hasBluetoothPermission(activity)) {
                try { Wearables.startRegistration(activity) } catch (e: Exception) { report("Registration failed: ${e.message}") }
            }
        }
    }

    fun unregister(activity: Activity) {
        disconnectDisplay()
        scope.launch {
            if (initialized) try { Wearables.startUnregistration(activity) }
            catch (e: Exception) { report("Unregistration failed: ${e.message}") }
        }
    }

    /** Only the SDK's Meta AI initiated registration request activates DAT from an app intent. */
    fun handleIntent(activity: Activity, intent: Intent): Boolean {
        if (intent.getStringExtra("com.meta.wearable.dat.extra.MWA_INITIATED_DAT_ACTION") != "beginRegistration") return false
        if (!hasBluetoothPermission(activity)) {
            activity.startActivity(Intent(intent).setClassName(activity, "xmwatch.android.MetaGlassesActivity")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP))
            return true
        }
        initialize(activity)
        scope.launch {
            if (!initialized) return@launch
            try {
                val result = Wearables.handleIntent(intent) { request ->
                    showRegistrationRequest(activity, request)
                }
                if (result.isFailure) report("Meta AI request: ${result.errorOrNull()}")
            } catch (e: Exception) { report("Meta AI request failed: ${e.message}") }
        }
        return true
    }

    /** The SDK consumes request extras before invoking us, so every dismissed host must answer. */
    private fun showRegistrationRequest(activity: Activity, request: RegistrationRequest) {
        val owner = activity as? LifecycleOwner
        var answered = false
        var dialog: AlertDialog? = null
        lateinit var observer: DefaultLifecycleObserver
        fun answer(accept: Boolean) {
            if (answered) return
            answered = true
            owner?.lifecycle?.removeObserver(observer)
            try {
                val result = if (accept) request.continueRegistration(activity) else request.cancelRegistration()
                if (result.isFailure) report("Registration: ${result.errorOrNull()}")
            } catch (e: Exception) { report("Registration response failed: ${e.message}") }
        }
        observer = object : DefaultLifecycleObserver {
            override fun onDestroy(owner: LifecycleOwner) {
                answer(false)
                dialog?.dismiss()
            }
        }
        if (owner == null || owner.lifecycle.currentState == Lifecycle.State.DESTROYED || activity.isFinishing || activity.isDestroyed) {
            answer(false)
            return
        }
        val requestDialog = AlertDialog.Builder(activity).setTitle("Connect to Meta glasses?")
            .setMessage("Meta AI is requesting registration for this app's optional glasses display.")
            .setPositiveButton("Continue") { _, _ -> answer(true) }
            .setNegativeButton("Cancel") { _, _ -> answer(false) }
            .setOnCancelListener { answer(false) }
            .create()
        dialog = requestDialog
        requestDialog.setOnDismissListener { answer(false) }
        owner.lifecycle.addObserver(observer)
        try { requestDialog.show() }
        catch (e: Exception) { answer(false); requestDialog.dismiss(); report("Meta AI request dialog failed: ${e.message}") }
    }

    fun updateFirmware(activity: Activity) {
        scope.launch {
            if (!initialized) return@launch
            status = "Update glasses firmware in Meta AI, then reconnect the display."; publish()
            try { val result = Wearables.openFirmwareUpdate(activity)
                if (result.isFailure) report("Open Meta AI and update glasses firmware: ${result.errorOrNull()}")
            } catch (e: Exception) { report("Open Meta AI to update glasses firmware. ${e.message}") }
        }
    }

    fun updateGlassesApp(activity: Activity) {
        scope.launch {
            if (!initialized) return@launch
            status = "Update the DAT app on the glasses in Meta AI, then reconnect."; publish()
            try { val result = Wearables.openDATGlassesAppUpdate(activity)
                if (result.isFailure) report("Update the DAT glasses app in Meta AI: ${result.errorOrNull()}")
            } catch (e: Exception) { report("Open Meta AI to update the DAT glasses app. ${e.message}") }
        }
    }

    fun connectDisplay(deviceID: String? = null) {
        scope.launch {
            val token = ++generation
            operations.withLock {
                if (!stopCurrent()) return@withLock
                if (token != generation) return@withLock
                val context = appContext
                if (!initialized || context == null || !hasBluetoothPermission(context)) {
                    report("Open Meta glasses settings and allow Nearby devices first."); return@withLock
                }
                if (Wearables.registrationState.value != RegistrationState.REGISTERED) {
                    report("Register this app with Meta AI before connecting a display."); return@withLock
                }
                val entry = metadata.entries.firstOrNull { (id, device) ->
                    (deviceID == null || id.identifier == deviceID) && eligible(device)
                }
                if (entry == null) {
                    report("No connected, compatible display glasses. Standard Ray-Ban Meta glasses can play phone audio over Bluetooth; continue playback on your phone.")
                    return@withLock
                }
                val created = try { Wearables.createSession(SpecificDeviceSelector(entry.key)) }
                    catch (e: Exception) { report("Display session failed: ${e.message}"); return@withLock }
                val session = created.getOrNull()
                if (session == null) { report("Display session: ${created.errorOrNull()}"); return@withLock }
                val attempt = Attempt(token, session)
                current = attempt; error = ""; status = "Connecting to ${entry.value.name}…"
                sessionState = "STARTING"; displayState = "STOPPED"; publish()
                attempt.jobs += scope.launch(start = CoroutineStart.UNDISPATCHED) {
                    session.errors.collect { if (active(attempt)) reportSessionError(it) }
                }
                attempt.jobs += scope.launch(start = CoroutineStart.UNDISPATCHED) {
                    session.state.collect { state ->
                        if (current === attempt && attempt.stopping && state == DeviceSessionState.STOPPED) {
                            scope.launch { operations.withLock { if (current === attempt) stopCurrent() } }
                        }
                        if (!active(attempt)) return@collect
                        sessionState = state.name; publish()
                        when (state) {
                            DeviceSessionState.STARTED -> {
                                if (attempt.display == null) attachDisplay(attempt)
                                else {
                                    attempt.sent = null
                                    if (attempt.display?.state?.value == DisplayState.STARTED) status = "Glasses display connected."
                                    attempt.updates.trySend(Unit); publish()
                                }
                            }
                            DeviceSessionState.PAUSED -> { status = "Glasses session paused; waiting to resume."; publish() }
                            DeviceSessionState.STOPPED -> terminate(attempt, "Glasses session ended. Reconnect when ready.")
                            else -> Unit
                        }
                    }
                }
                attempt.jobs += scope.launch {
                    delay(30_000)
                    if (active(attempt) && !attempt.displayWasStarted) terminate(attempt, "Display connection timed out. Check Meta AI and try again.")
                }
                try { session.start() } catch (e: Exception) { terminate(attempt, "Display connection failed: ${e.message}") }
            }
        }
    }

    fun disconnectDisplay() {
        scope.launch {
            ++generation
            operations.withLock {
                if (stopCurrent()) { status = "Glasses display disconnected. Phone playback continues."; publish() }
            }
        }
    }

    private fun active(attempt: Attempt) = current === attempt && attempt.generation == generation && !attempt.stopping
    private fun eligible(device: Device) = device.linkState == LinkState.CONNECTED &&
        device.compatibility == DeviceCompatibility.COMPATIBLE && device.isDisplayCapable()

    private fun attachDisplay(attempt: Attempt) {
        val added = try { attempt.session.addDisplay() }
            catch (e: Exception) { terminate(attempt, "Display capability failed: ${e.message}"); return }
        val display = added.getOrNull()
        if (display == null) { terminate(attempt, "Display capability: ${added.errorOrNull()}"); return }
        attempt.display = display
        attempt.jobs += scope.launch(start = CoroutineStart.UNDISPATCHED) {
            display.state.collect { state ->
                if (!active(attempt)) return@collect
                displayState = state.name
                if (state == DisplayState.STARTED) {
                    attempt.displayWasStarted = true; attempt.sent = null; status = "Glasses display connected. Tap the primary action to play or pause."
                    attempt.updates.trySend(Unit)
                } else if (attempt.displayWasStarted && (state == DisplayState.STOPPED || state == DisplayState.CLOSED)) {
                    terminate(attempt, "Glasses display ended. Reconnect when ready.")
                }
                publish()
            }
        }
        // Polling and sending are separate: while a send suspends, only the newest snapshot is retained.
        attempt.jobs += scope.launch {
            while (active(attempt)) {
                if (display.state.value == DisplayState.STARTED && attempt.session.state.value == DeviceSessionState.STARTED) {
                    try { attempt.pending = provider().toString(); attempt.updates.trySend(Unit) }
                    catch (e: Exception) { report("Playback display snapshot: ${e.message}") }
                }
                delay(1_000)
            }
        }
        attempt.jobs += scope.launch {
            for (ignored in attempt.updates) {
                if (!active(attempt) || display.state.value != DisplayState.STARTED ||
                    attempt.session.state.value != DeviceSessionState.STARTED) continue
                val payload = attempt.pending ?: continue
                if (payload == attempt.sent) continue
                try {
                    val model = JSONObject(payload)
                    val result = display.sendContent { render(model, attempt) }
                    if (!active(attempt)) continue
                    if (result.getOrNull() == true) { attempt.sent = payload; if (error.startsWith("Display content")) { error = ""; publish() } }
                    else report("Display content: ${result.errorOrNull() ?: "not accepted; retrying"}")
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (e: Exception) { if (active(attempt)) report("Display content failed; retrying: ${e.message}") }
            }
        }
    }

    private fun ContentScope.render(model: JSONObject, attempt: Attempt) {
        fun act(name: String) { scope.launch { if (active(attempt) && attempt.session.state.value == DeviceSessionState.STARTED &&
            attempt.display?.state?.value == DisplayState.STARTED) command(name) } }
        flexBox(direction = Direction.COLUMN, gap = 8, padding = 12) {
            text(model.optString("title", "Now playing").take(120))
            model.optString("subtitle").takeIf { it.isNotBlank() }?.let { text(it.take(120)) }
            model.optString("detail").takeIf { it.isNotBlank() }?.let { text(it.take(180)) }
            text("${time(model.optLong("positionMS"))} / ${time(model.optLong("durationMS"))}")
            text(if (model.optBoolean("buffering")) "Buffering…" else model.optString("status", if (model.optBoolean("playing")) "Playing" else "Paused"))
            if (model.optBoolean("canPlayPause")) button(
                if (model.optBoolean("playing")) "Pause" else "Play",
                onClick = { act("playPause") }, actionRole = ActionRole.PRIMARY)
            flexBox(direction = Direction.ROW, wrap = true, gap = 6) {
                if (model.optBoolean("canPrevious")) button("Previous", onClick = { act("previous") })
                if (model.optBoolean("canNext")) button("Next", onClick = { act("next") })
                if (model.optBoolean("canSeek")) {
                    button("−${model.optInt("seekBackSeconds", 15)}s", onClick = { act("seekBack") })
                    button("+${model.optInt("seekForwardSeconds", 30)}s", onClick = { act("seekForward") })
                }
                if (model.optBoolean("canChangeRate")) button("${model.optDouble("rate", 1.0)}×", onClick = { act("rate") })
            }
        }
    }

    private fun terminate(attempt: Attempt, reason: String) {
        if (!active(attempt)) return
        ++generation
        status = reason; publish()
        scope.launch { operations.withLock { if (current === attempt) stopCurrent() } }
    }

    /** A replacement must never overlap a session which has not reached STOPPED. */
    private suspend fun stopCurrent(): Boolean {
        val attempt = current ?: return true
        attempt.stopping = true
        displayState = "STOPPING"; sessionState = "STOPPING"; publish()
        try {
            attempt.display?.stop()
            attempt.session.stop()
            withTimeout(10_000) { attempt.session.state.first { it == DeviceSessionState.STOPPED } }
        } catch (cancelled: CancellationException) {
            if (cancelled !is TimeoutCancellationException) throw cancelled
            report("Glasses cleanup is still pending. Wait, then try disconnecting again."); return false
        } catch (e: Exception) { report("Glasses cleanup failed: ${e.message}"); return false }
        attempt.jobs.forEach { it.cancel() }
        attempt.updates.close()
        runCatching { attempt.display?.close() }
        current = null; sessionState = "STOPPED"; displayState = "STOPPED"; publish()
        return true
    }

    private fun reportSessionError(value: DeviceSessionError) {
        report(when (value) {
            DeviceSessionError.DAT_APP_ON_THE_GLASSES_UPDATE_REQUIRED -> "Update the DAT glasses app in Meta AI, then reconnect."
            DeviceSessionError.INSUFFICIENT_SDK_VERSION -> "This app needs a newer Meta DAT SDK. Update this phone app."
            else -> "Glasses session: $value"
        })
    }
    private fun report(message: String) { error = message; status = message; publish() }
    private fun publish() {
        published = JSONObject().put("initialized", initialized).put("registration", registration)
            .put("session", sessionState).put("display", displayState).put("status", status).put("error", error)
            .put("devices", JSONArray().apply { metadata.forEach { (id, device) -> put(JSONObject()
                .put("id", id.identifier).put("name", device.name).put("linkState", device.linkState.name)
                .put("compatibility", device.compatibility.name).put("displayCapable", device.isDisplayCapable())
                .put("eligible", eligible(device)).put("batteryLevel", device.batteryLevel).put("firmware", device.firmwareInfo)) } })
            .toString()
        listeners.forEach { runCatching { it() } }
    }
    private fun time(milliseconds: Long): String {
        val seconds = milliseconds.coerceAtLeast(0) / 1_000
        return if (seconds >= 3_600) "%d:%02d:%02d".format(seconds / 3_600, seconds / 60 % 60, seconds % 60)
        else "%d:%02d".format(seconds / 60, seconds % 60)
    }
}
