package xmwatch.android

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.MediaRouter2
import android.os.Build
import android.provider.Settings
import android.widget.Toast

/** An explicit user action opens Android's media output UI; playback stays owned by the session. */
object AudioOutput {
    fun open(context: Context): String {
        if (Build.VERSION.SDK_INT >= 34) {
            val shown = try {
                MediaRouter2.getInstance(context).showSystemOutputSwitcher()
            } catch (_: Exception) {
                false
            } catch (_: LinkageError) {
                false
            }
            if (shown) return "systemSwitcher"
        }
        if (openSettings(context, Settings.ACTION_BLUETOOTH_SETTINGS)) return "bluetoothSettings"
        if (openSettings(context, Settings.ACTION_SOUND_SETTINGS)) return "soundSettings"
        try {
            Toast.makeText(context, "Audio output settings are unavailable on this device.", Toast.LENGTH_LONG).show()
        } catch (_: Exception) { }
        return "unavailable"
    }

    private fun openSettings(context: Context, action: String): Boolean = try {
        val intent = Intent(action)
        if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        true
    } catch (_: Exception) {
        false
    }
}
