package xmwatch.android

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.net.Uri
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID

/** Public launcher/automation contract; never accepts credentials or media URLs. */
object PhoneAutomation {
    const val ACTION = "xmwatch.android.action.AUTOMATION"
    private val commands = setOf("pick", "tune", "pause", "resume", "next", "previous")
    private val keys = setOf("channelID", "number", "query", "region")
    data class Request(val command: String, val channelID: String? = null, val number: String? = null,
        val query: String? = null, val region: String? = null) {
        fun json(): JSONObject = JSONObject().put("command", command).apply {
            channelID?.let { put("channelID", it) }; number?.let { put("number", it) }
            query?.let { put("query", it) }; region?.let { put("region", it) }
        }
    }
    fun parse(intent: Intent?): Request? { return try {
        require(intent != null && intent.action in setOf(ACTION, Intent.ACTION_VIEW))
        val uri = intent.data ?: return null
        require(uri.toString().length <= 1024 && uri.isHierarchical && uri.scheme == "xmwatch" && uri.host == "automation")
        require(uri.port == -1 && uri.userInfo == null && uri.fragment == null)
        val command = uri.path?.removePrefix("/") ?: return null
        require(command in commands && uri.path == "/$command")
        require(uri.queryParameterNames.all { it in keys })
        require(uri.queryParameterNames.all { uri.getQueryParameters(it).size == 1 })
        val id = uri.getQueryParameter("channelID")
        val number = uri.getQueryParameter("number")
        val query = uri.getQueryParameter("query")
        val region = uri.getQueryParameter("region")
        require(id == null || id.matches(Regex("[A-Za-z0-9_-]{1,128}")))
        require(number == null || number.matches(Regex("[0-9]{1,5}")))
        require(query == null || (query.isNotBlank() && query.length <= 160 && query.none { it.isISOControl() } &&
            !query.contains("://") && !query.contains('@') && !query.contains('=') && !query.contains('/')))
        require(region == null || region in setOf("US", "CA"))
        val selectors = listOfNotNull(id, number, query).size
        when (command) {
            "tune" -> require(selectors == 1)
            "pick" -> require(id == null && number == null)
            else -> require(selectors == 0)
        }
        Request(command, id, number, query, region)
    } catch (_: Exception) { null } }

    private const val DELIVERY = "xmwatch.android.automation.DELIVERY"
    data class Delivery(val id: String, val fingerprint: String)
    fun fingerprint(intent: Intent?): String? {
        if (parse(intent) == null) return null
        return MessageDigest.getInstance("SHA-256").digest((intent!!.action + "|" + intent.dataString).toByteArray())
            .joinToString("") { "%02x".format(it.toInt() and 255) }
    }
    /** Clean before execution. Fresh incoming intents remain valid on a restored task. */
    fun consume(intent: Intent?, previous: Delivery? = null): Request? {
        val incoming = intent ?: return null
        val request = parse(incoming) ?: return null
        val fingerprint = fingerprint(incoming) ?: return null
        val delivery = runCatching { incoming.getStringExtra(DELIVERY) }.getOrNull()
        val replay = (delivery != null && delivery == previous?.id) ||
            (incoming.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0 && fingerprint == previous?.fingerprint)
        if (delivery == null) incoming.putExtra(DELIVERY, UUID.randomUUID().toString())
        incoming.action = Intent.ACTION_MAIN
        incoming.data = null
        return request.takeUnless { replay }
    }
    fun handleIntent(activity: Activity, intent: Intent?, previous: Delivery? = null): Delivery? {
        val fingerprint = fingerprint(intent) ?: return previous
        val request = consume(intent, previous)
        val delivery = Delivery(runCatching { intent!!.getStringExtra(DELIVERY) }.getOrNull() ?: UUID.randomUUID().toString(), fingerprint)
        if (request != null) {
            val payload = request.json().put("requestID", delivery.id)
            XMWatchAndroidAppDelegate.shared.onPhoneAutomation(payload.toString())
        }
        return delivery
    }
    fun channelIntent(context: Context, region: String, id: String): Intent = Intent(ACTION,
        Uri.Builder().scheme("xmwatch").authority("automation").appendPath("tune")
            .appendQueryParameter("channelID", id).appendQueryParameter("region", region).build())
        .setClassName(context.packageName, "xmwatch.android.MainActivity")
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    fun shortcutID(region: String, id: String): String = "channel-$region-" + MessageDigest.getInstance("SHA-256")
        .digest(id.toByteArray()).take(12).joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun shortcut(context: Context, region: String, id: String, name: String, number: String): ShortcutInfo =
        ShortcutInfo.Builder(context, shortcutID(region, id)).setShortLabel(name.take(40))
            .setLongLabel("Channel $number · $name".take(80))
            .setIcon(Icon.createWithResource(context, context.applicationInfo.icon))
            .setIntent(channelIntent(context, region, id)).build()
    fun pin(context: Context, region: String, id: String, name: String, number: String): Boolean = try {
        val intent = channelIntent(context, region, id)
        require(parse(intent) != null && name.isNotBlank() && name.length <= 256 && number.matches(Regex("[0-9]{1,5}")))
        val manager = context.getSystemService(ShortcutManager::class.java)
        manager.isRequestPinShortcutSupported && manager.requestPinShortcut(shortcut(context, region, id, name, number), null)
    } catch (_: Exception) { false }

    private var lastPublished: String? = null
    /** Only public current-region channel metadata reaches the launcher. */
    @Synchronized fun synchronize(context: Context, json: String) {
        try {
            val value = JSONObject(json)
            val region = value.getString("region")
            require(region in setOf("US", "CA"))
            val channels = value.getJSONArray("channels")
            val allowed = mutableSetOf<String>()
            val favorites = mutableListOf<ShortcutInfo>()
            for (index in 0 until minOf(channels.length(), 5000)) {
                val channel = channels.getJSONObject(index)
                val id = channel.getString("id"); val number = channel.getString("number"); val name = channel.getString("name")
                require(parse(channelIntent(context, region, id)) != null && name.isNotBlank() && number.matches(Regex("[0-9]{1,5}")))
                allowed.add(shortcutID(region, id))
                if (channel.optBoolean("favorite") && favorites.size < 2) favorites.add(shortcut(context, region, id, name, number))
            }
            val signature = region + allowed.sorted().joinToString() + favorites.joinToString { it.id + it.shortLabel + it.longLabel }
            if (signature == lastPublished) return
            val manager = context.getSystemService(ShortcutManager::class.java)
            val pinned = manager.pinnedShortcuts.filter { it.id.startsWith("channel-") }
            val invalid = pinned.filter { it.id !in allowed }.map { it.id }
            if (invalid.isNotEmpty()) manager.disableShortcuts(invalid, "Open XMWatch in this channel's region with a saved session.")
            val valid = pinned.filter { it.id in allowed }.map { it.id }
            if (valid.isNotEmpty()) manager.enableShortcuts(valid)
            if (manager.setDynamicShortcuts(favorites.take((manager.maxShortcutCountPerActivity - manager.manifestShortcuts.size).coerceAtLeast(0)))) {
                lastPublished = signature
            }
        } catch (_: Exception) { /* Launcher failures never affect radio playback. */ }
    }
}
