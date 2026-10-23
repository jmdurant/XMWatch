package xmwatch.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Only encrypted session cookies/account identity reach disk; never passwords. */
object RadioSecureStore {
    /** Stable across cookie renewal; account identity never enters public IDs. */
    fun owner(context: Context): String? = try {
        val value = org.json.JSONObject(load(context))
        val account = value.getJSONObject("account")
        val identity = org.json.JSONArray().put(value.getString("region"))
            .put(account.getString("username")).put(account.optString("identifier")).toString()
        java.security.MessageDigest.getInstance("SHA-256").digest(identity.toByteArray())
            .joinToString("") { "%02x".format(it.toInt() and 255) }
    } catch (_: Exception) { null }
    private const val ALIAS = "xmwatch.radio.session.v1"
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
            generateKey()
        }
    }
    @Synchronized fun save(context: Context, json: String): Boolean = try {
        require(json.toByteArray().size <= 131072)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        cipher.updateAAD(ALIAS.toByteArray())
        val bytes = cipher.doFinal(json.toByteArray(Charsets.UTF_8))
        val prefs=context.getSharedPreferences("radio-session", Context.MODE_PRIVATE)
        val previousIV=prefs.getString("iv",null)
        val previousCiphertext=prefs.getString("ciphertext",null)
        val committed=try {
            prefs.edit().putString("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
                .putString("ciphertext", Base64.encodeToString(bytes, Base64.NO_WRAP)).commit()
        } catch (_: Exception) { false }
        if (!committed) {
            // SharedPreferences can publish new values in memory before its
            // disk write fails. Restore both fields before another reader runs.
            try { prefs.edit().putString("iv",previousIV).putString("ciphertext",previousCiphertext).commit() }
            catch (_: Exception) { /* The in-memory editor still restores the old values. */ }
        }
        committed
    } catch (_: Exception) { false }
    @Synchronized fun load(context: Context): String { return try {
        val prefs = context.getSharedPreferences("radio-session", Context.MODE_PRIVATE)
        val encoded = prefs.getString("ciphertext", null) ?: return ""
        require(encoded.length <= 180000)
        val iv = Base64.decode(prefs.getString("iv", ""), Base64.NO_WRAP)
        require(iv.size == 12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv)) }
        cipher.updateAAD(ALIAS.toByteArray())
        String(cipher.doFinal(Base64.decode(encoded, Base64.NO_WRAP)), Charsets.UTF_8)
    } catch (_: Exception) { "" } }
    private fun regionContext(context:Context,region:String):Context {
        require(region in setOf("US","CA"))
        return object:android.content.ContextWrapper(context) {
            override fun getSharedPreferences(name:String,mode:Int)=context.getSharedPreferences(if (name=="radio-session") "radio-region-$region" else name,mode)
        }
    }
    /** Cache the old region before replacing the active cookie. The cookie JSON
     * remains bound to its region, even if encrypted preference files are moved. */
    @Synchronized fun activateRegion(context:Context,target:String):Boolean = try {
        require(target in setOf("US","CA"))
        val current=load(context)
        val currentRegion=try { org.json.JSONObject(current).getString("region") } catch (_:Exception) { "" }
        if (currentRegion==target) true
        else {
            if (current.isNotEmpty()) {
                require(currentRegion in setOf("US","CA"))
                check(save(regionContext(context,currentRegion),current))
            }
            val cached=load(regionContext(context,target))
            if (cached.isNotEmpty()) {
                require(org.json.JSONObject(cached).getString("region")==target)
                save(context,cached)
            } else {
                val prefs=context.getSharedPreferences("radio-session",Context.MODE_PRIVATE)
                val oldIV=prefs.getString("iv",null);val oldCipher=prefs.getString("ciphertext",null)
                val committed=try { prefs.edit().clear().commit() } catch (_:Exception) { false }
                if (!committed) try { prefs.edit().putString("iv",oldIV).putString("ciphertext",oldCipher).commit() } catch (_:Exception) {}
                committed
            }
        }
    } catch (_:Exception) { false }
    @Synchronized fun clear(context: Context) {
        val region=try { org.json.JSONObject(load(context)).getString("region") } catch (_:Exception) { "" }
        if (region in setOf("US","CA")) regionContext(context,region).getSharedPreferences("radio-session",Context.MODE_PRIVATE).edit().clear().commit()
        context.getSharedPreferences("radio-session", Context.MODE_PRIVATE).edit().clear().commit()
    }
}
