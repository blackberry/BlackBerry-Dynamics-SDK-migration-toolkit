// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Derived from BlackBerry-Dynamics-Android-Samples / Dynamics-GettingStarted (Apache-2.0).
// See templates/_LICENSE-NOTICE.md for full attribution.
//
// NOTE: Dynamics SDK exposes only Java APIs. All com.good.gd.* types are
// Java platform types in Kotlin (suffix '!', i.e. neither nullable nor non-null
// is guaranteed by the compiler). Handle nulls explicitly; avoid !! operators.
//
// HOW TO USE:
//   1. Replace __APP_PACKAGE__ with your application package.
//   2. Rename DynamicsApplicationBase to your application class name.
//   3. In AndroidManifest.xml, set android:name=".YourApplicationClass"
//      on the <application> element.
//   4. Remove TODO markers once real startup logic is wired.

package __APP_PACKAGE__

import android.app.Application
import android.os.Build
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import com.good.gd.GDAndroid
import com.good.gd.GDStateListener

// [BB_DYNAMICS-MIGRATION] Application class implements GDStateListener for global Dynamics auth lifecycle.
class DynamicsApplicationBase : Application(), GDStateListener {

    // [BB_DYNAMICS-MIGRATION] Container authorization state — read-only outside this class.
    @Volatile
    var isContainerAuthorized: Boolean = false
        private set

    // [BB_DYNAMICS-MIGRATION] LiveData for reactive authorization — observe in ViewModels.
    private val _authorized = MutableLiveData(false)
    val authorized: LiveData<Boolean> = _authorized

    // [BB_DYNAMICS-MIGRATION] Callbacks queued before onAuthorized() fires.
    private val pendingAuthorizedCallbacks = mutableListOf<Runnable>()

    companion object {
        // [BB_DYNAMICS-MIGRATION] UEM config/policy caches — readers use getters; never call GDAndroid from UI.
        @Volatile
        var cachedApplicationConfig: MutableMap<String, Any>? = null
            private set

        @Volatile
        var cachedApplicationPolicy: MutableMap<String, Any>? = null
            private set
    }

    // [BB_DYNAMICS-MIGRATION] Queue a callback to run once the container is authorized.
    // If already authorized, runs immediately on the calling thread.
    // NOTE: callbacks that mutate Activity UI must still be lifecycle-safe.
    // Do not directly commit Fragment transactions from this callback path
    // without an Activity-side isStateSaved/onPostResume guard.
    @Synchronized
    fun runOnAuthorized(callback: Runnable) {
        if (isContainerAuthorized) {
            callback.run()
        } else {
            pendingAuthorizedCallbacks.add(callback)
        }
    }

    // [BB_DYNAMICS-MIGRATION] Dynamics setup runs only in the main process.
    private fun isMainProcess(): Boolean {
        val processName = if (Build.VERSION.SDK_INT >= 28) {
            Application.getProcessName()
        } else {
            Application.getProcessName()
        }
        return processName == null || processName == packageName
    }

    override fun onCreate() {
        super.onCreate()
        if (!isMainProcess()) {
            return
        }
        // [BB_DYNAMICS-MIGRATION] Register global GDStateListener before any Activity starts.
        GDAndroid.getInstance().setGDStateListener(this)
        // TODO: Add non-Dynamics initialization here (crash reporters, analytics, etc.)
    }

    // -------------------------------------------------------------------------
    // GDStateListener — all 7 callbacks required. Signatures MUST match the SDK.
    // Dynamics SDK = Java API. Kotlin parameter types shown are platform types.
    // Verify exact signatures with:
    //   javap -classpath <path-to-gd.jar> com.good.gd.GDStateListener
    // -------------------------------------------------------------------------

    override fun onAuthorized() {
        // [BB_DYNAMICS-MIGRATION] Container unlocked — safe to access secure APIs from here.
        // Keep auth-state and queue-drain under one monitor to avoid future race-prone edits.
        val callbacks = synchronized(this) {
            isContainerAuthorized = true
            pendingAuthorizedCallbacks.toList().also { pendingAuthorizedCallbacks.clear() }
        }
        _authorized.postValue(true)
        callbacks.forEach { it.run() }

        refreshApplicationConfig(null)
        refreshApplicationPolicy(null)

        // TODO: One-time post-authorization initialization (open DB, start sync, etc.)
    }

    private fun refreshApplicationConfig(fromCallback: MutableMap<String, Any>?) {
        try {
            @Suppress("UNCHECKED_CAST")
            cachedApplicationConfig = fromCallback
                ?: GDAndroid.getInstance().getApplicationConfig() as? MutableMap<String, Any>
        } catch (_: com.good.gd.error.GDNotAuthorizedError) {
            cachedApplicationConfig = null
        }
    }

    private fun refreshApplicationPolicy(fromCallback: MutableMap<String, Any>?) {
        try {
            @Suppress("UNCHECKED_CAST")
            cachedApplicationPolicy = fromCallback
                ?: GDAndroid.getInstance().getApplicationPolicy() as? MutableMap<String, Any>
        } catch (_: com.good.gd.error.GDNotAuthorizedError) {
            cachedApplicationPolicy = null
        }
    }

    override fun onLocked() {
        // [BB_DYNAMICS-MIGRATION] Container locked — stop all secure API access.
        synchronized(this) {
            isContainerAuthorized = false
        }
        _authorized.postValue(false)
        // TODO: Clear in-memory sensitive data, cancel background tasks.
    }

    override fun onWiped() {
        // [BB_DYNAMICS-MIGRATION] Remote wipe received — container data erased.
        synchronized(this) {
            isContainerAuthorized = false
        }
        _authorized.postValue(false)
        // TODO: Clear in-memory state and restart the app if needed.
    }

    // NOTE: Parameter type is Map<String, Any>? in Kotlin (Java platform type).
    // The actual runtime type is java.util.Map<String, Object> — non-null in practice.
    override fun onUpdateConfig(settings: MutableMap<String, Any>) {
        // [BB_DYNAMICS-MIGRATION] Dynamics container configuration updated by UEM.
        refreshApplicationConfig(settings)
        // TODO: Apply new config values from cachedApplicationConfig.
    }

    override fun onUpdatePolicy(policyValues: MutableMap<String, Any>) {
        // [BB_DYNAMICS-MIGRATION] App policy updated by UEM.
        refreshApplicationPolicy(policyValues)
        // TODO: Apply new policy values from cachedApplicationPolicy.
    }

    override fun onUpdateServices() {
        // [BB_DYNAMICS-MIGRATION] Available AppKinetics services changed.
        // TODO: Re-query service availability if your app uses AppKinetics.
    }

    override fun onUpdateEntitlements() {
        // [BB_DYNAMICS-MIGRATION] User entitlements changed in UEM.
        // TODO: Re-check entitlement-gated features if your app uses them.
    }
}
