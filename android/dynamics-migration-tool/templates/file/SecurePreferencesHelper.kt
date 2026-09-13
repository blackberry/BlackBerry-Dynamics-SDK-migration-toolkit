// [BB_DYNAMICS-MIGRATION] Preference key-value storage inside the Dynamics
// secure container. Replaces steady-state SharedPreferences persistence.
//
// Copy into the app (replace __APP_PACKAGE__) during prompt 05c.
// Pair with call-site deferral (Pattern 13): launch Activities must still
// not treat pre-auth defaults as stored values.
//
// Fail-closed: constructing com.good.gd.file.File before onAuthorized()
// throws GDNotAuthorizedError (or GDNotAuthorizedErrorBridge). Reads return
// empty/default without caching; writes are no-ops until authorized.
//
// Do NOT gate I/O on Application.isContainerAuthorized. onLocked() (idle
// lock) sets that flag false while GD File still works — a flag gate would
// break biometric/theme reads after idle lock. Catch the SDK not-authorized
// error instead.

package __APP_PACKAGE__

import com.good.gd.error.GDNotAuthorizedError
import com.good.gd.file.File
import org.json.JSONArray
import org.json.JSONObject

object SecurePreferencesHelper {

    private const val DIR = "secure_prefs"
    private const val FILE_NAME = "prefs.json"

    private val lock = Any()
    private var cache: JSONObject? = null

    private fun prefsFile(): File {
        val dir = File(DIR)
        if (!dir.exists()) dir.mkdirs()
        return File(dir, FILE_NAME)
    }

    private fun isNotAuthorized(error: Throwable): Boolean {
        var cur: Throwable? = error
        while (cur != null) {
            if (cur is GDNotAuthorizedError) return true
            val name = cur.javaClass.name
            if (name.contains("GDNotAuthorized") || name.contains("NotAuthorized")) {
                return true
            }
            cur = cur.cause
        }
        return false
    }

    private fun load(): JSONObject =
        synchronized(lock) {
            cache?.let { return it }
            try {
                val file = prefsFile()
                val obj =
                    if (file.exists()) {
                        val text = file.readText()
                        if (text.isBlank()) JSONObject() else JSONObject(text)
                    } else JSONObject()
                cache = obj
                obj
            } catch (e: Throwable) {
                if (isNotAuthorized(e)) JSONObject() else throw e
            }
        }

    private fun persist(obj: JSONObject) {
        synchronized(lock) {
            try {
                prefsFile().writeText(obj.toString())
                cache = obj
            } catch (e: Throwable) {
                if (!isNotAuthorized(e)) throw e
            }
        }
    }

    fun invalidateMemoryCache() {
        synchronized(lock) { cache = null }
    }

    fun contains(key: String): Boolean = load().has(key)

    fun remove(key: String) {
        val obj = load()
        obj.remove(key)
        persist(obj)
    }

    fun clear() {
        persist(JSONObject())
    }

    fun getString(key: String, defaultValue: String?): String? {
        if (!load().has(key)) return defaultValue
        return load().opt(key)?.toString() ?: defaultValue
    }

    fun putString(key: String, value: String?) {
        val obj = load()
        if (value == null) obj.remove(key) else obj.put(key, value)
        persist(obj)
    }

    fun getInt(key: String, defaultValue: Int): Int {
        if (!load().has(key)) return defaultValue
        return load().optInt(key, defaultValue)
    }

    fun putInt(key: String, value: Int) {
        val obj = load()
        obj.put(key, value)
        persist(obj)
    }

    fun getBoolean(key: String, defaultValue: Boolean): Boolean {
        if (!load().has(key)) return defaultValue
        return load().optBoolean(key, defaultValue)
    }

    fun putBoolean(key: String, value: Boolean) {
        val obj = load()
        obj.put(key, value)
        persist(obj)
    }

    fun getStringSet(key: String, defaultValue: Set<String>?): Set<String>? {
        if (!load().has(key)) return defaultValue
        val raw = load().opt(key) ?: return defaultValue
        if (raw is JSONArray) {
            return (0 until raw.length()).map { raw.getString(it) }.toSet()
        }
        return defaultValue
    }

    fun putStringSet(key: String, value: Set<String>?) {
        val obj = load()
        if (value == null) {
            obj.remove(key)
        } else {
            obj.put(key, JSONArray(value.toList()))
        }
        persist(obj)
    }
}

private fun File.readText(): String =
    com.good.gd.file.FileInputStream(this).use { it.readBytes().toString(Charsets.UTF_8) }

private fun File.writeText(text: String) {
    com.good.gd.file.FileOutputStream(this).use { it.write(text.toByteArray(Charsets.UTF_8)) }
}
