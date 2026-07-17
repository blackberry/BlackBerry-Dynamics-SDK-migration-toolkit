// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Derived from BlackBerry-Dynamics-Android-Samples / Dynamics-GettingStarted (Apache-2.0).
// See templates/_LICENSE-NOTICE.md for full attribution.
//
// HOW TO USE:
//   1. Replace __APP_PACKAGE__ with your application package.
//   2. Rename DynamicsApplicationBase to your application class name
//      (e.g., MyApplication, MyApp).
//   3. In AndroidManifest.xml, set android:name=".YourApplicationClass"
//      on the <application> element.
//   4. For Activities classified "main" in bootstrap.json processModel, ensure
//      GDAndroid.getInstance().activityInit(this) in onCreate(). Do NOT call
//      activityInit() on auxiliary-process Activities (see steering/22-multi-process-app-handling.md).
//   5. Remove any TODO markers once you have wired your real startup logic.

package __APP_PACKAGE__;

import android.app.Application;
import android.os.Build;
import android.os.Process;

import androidx.lifecycle.LiveData;
import androidx.lifecycle.MutableLiveData;

import com.good.gd.GDAndroid;
import com.good.gd.GDStateListener;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

// [BB_DYNAMICS-MIGRATION] Application class implements GDStateListener for global Dynamics auth lifecycle.
public class DynamicsApplicationBase extends Application implements GDStateListener {

    // [BB_DYNAMICS-MIGRATION] Container authorization state — read-only outside this class.
    private static volatile boolean isContainerAuthorized = false;

    // [BB_DYNAMICS-MIGRATION] LiveData for reactive authorization — observe in ViewModels.
    private final MutableLiveData<Boolean> authorized = new MutableLiveData<>(false);

    // [BB_DYNAMICS-MIGRATION] Callbacks queued before onAuthorized() fires.
    private final List<Runnable> pendingAuthorizedCallbacks = new ArrayList<>();

    // [BB_DYNAMICS-MIGRATION] UEM application config cache — refresh in onUpdateConfig only.
    private static volatile Map<String, Object> cachedApplicationConfig;

    // [BB_DYNAMICS-MIGRATION] UEM application policy cache — refresh in onUpdatePolicy only.
    private static volatile Map<String, Object> cachedApplicationPolicy;

    public static Map<String, Object> getCachedApplicationConfig() {
        return cachedApplicationConfig;
    }

    public static Map<String, Object> getCachedApplicationPolicy() {
        return cachedApplicationPolicy;
    }

    public static boolean isContainerAuthorized() {
        return isContainerAuthorized;
    }

    public LiveData<Boolean> getAuthorizedLiveData() {
        return authorized;
    }

    // [BB_DYNAMICS-MIGRATION] Queue a callback to run once the container is authorized.
    // If already authorized, runs immediately on the calling thread.
    // NOTE: callbacks that mutate Activity UI must still be lifecycle-safe.
    // Do not directly commit Fragment transactions from this callback path
    // without an Activity-side isStateSaved/onPostResume guard.
    public synchronized void runOnAuthorized(Runnable callback) {
        if (isContainerAuthorized) {
            callback.run();
        } else {
            pendingAuthorizedCallbacks.add(callback);
        }
    }

    // [BB_DYNAMICS-MIGRATION] Dynamics setup runs only in the main process.
    private boolean isMainProcess() {
        if (Build.VERSION.SDK_INT >= 28) {
            return getPackageName().equals(Application.getProcessName());
        }
        String proc = Application.getProcessName();
        return proc == null || proc.equals(getPackageName());
    }

    @Override
    public void onCreate() {
        super.onCreate();
        if (!isMainProcess()) {
            return;
        }
        // [BB_DYNAMICS-MIGRATION] Register global GDStateListener before any Activity starts.
        // This MUST happen in Application.onCreate() in the main process only.
        GDAndroid.getInstance().setGDStateListener(this);
        // TODO: Add any non-Dynamics initialization here (crash reporters, analytics, etc.)
    }

    // -------------------------------------------------------------------------
    // GDStateListener — all 7 callbacks required. Signatures MUST match the SDK.
    // Verify with:
    //   javap -classpath <path-to-gd.jar> com.good.gd.GDStateListener
    // -------------------------------------------------------------------------

    @Override
    public void onAuthorized() {
        // [BB_DYNAMICS-MIGRATION] Container unlocked — safe to access secure APIs from here.
        // Keep auth-state and queue-drain under one monitor to avoid future race-prone edits.
        List<Runnable> callbacks;
        synchronized (this) {
            isContainerAuthorized = true;
            callbacks = new ArrayList<>(pendingAuthorizedCallbacks);
            pendingAuthorizedCallbacks.clear();
        }
        authorized.postValue(true);
        for (Runnable cb : callbacks) {
            cb.run();
        }

        // [BB_DYNAMICS-MIGRATION] Seed config/policy caches once when the container unlocks.
        refreshApplicationConfig(null);
        refreshApplicationPolicy(null);

        // TODO: Perform any one-time post-authorization initialization here
        //       (e.g., open secure database, start background sync).
    }

    // [BB_DYNAMICS-MIGRATION] Refresh config cache from callback map or GDAndroid.
    private void refreshApplicationConfig(Map<String, Object> fromCallback) {
        try {
            if (fromCallback != null) {
                cachedApplicationConfig = fromCallback;
            } else {
                cachedApplicationConfig = GDAndroid.getInstance().getApplicationConfig();
            }
        } catch (com.good.gd.error.GDNotAuthorizedError e) {
            cachedApplicationConfig = null;
        }
    }

    // [BB_DYNAMICS-MIGRATION] Refresh policy cache from callback map or GDAndroid.
    private void refreshApplicationPolicy(Map<String, Object> fromCallback) {
        try {
            if (fromCallback != null) {
                cachedApplicationPolicy = fromCallback;
            } else {
                cachedApplicationPolicy = GDAndroid.getInstance().getApplicationPolicy();
            }
        } catch (com.good.gd.error.GDNotAuthorizedError e) {
            cachedApplicationPolicy = null;
        }
    }

    @Override
    public void onLocked() {
        // [BB_DYNAMICS-MIGRATION] Container locked — stop all secure API access.
        synchronized (this) {
            isContainerAuthorized = false;
        }
        authorized.postValue(false);
        // TODO: Clear any in-memory sensitive data, cancel background tasks.
    }

    @Override
    public void onWiped() {
        // [BB_DYNAMICS-MIGRATION] Remote wipe received — container data erased.
        synchronized (this) {
            isContainerAuthorized = false;
        }
        authorized.postValue(false);
        // TODO: Clear any in-memory state and restart the app if needed.
    }

    @Override
    public void onUpdateConfig(Map<String, Object> settings) {
        // [BB_DYNAMICS-MIGRATION] Dynamics container configuration updated by UEM.
        refreshApplicationConfig(settings);
        // TODO: Apply new config values to feature flags / server URLs your app reads from cache.
    }

    @Override
    public void onUpdatePolicy(Map<String, Object> policyValues) {
        // [BB_DYNAMICS-MIGRATION] App policy updated by UEM.
        refreshApplicationPolicy(policyValues);
        // TODO: Apply new policy values from getCachedApplicationPolicy().
    }

    @Override
    public void onUpdateServices() {
        // [BB_DYNAMICS-MIGRATION] Available AppKinetics services changed.
        // TODO: Re-query service availability if your app uses AppKinetics.
    }

    @Override
    public void onUpdateEntitlements() {
        // [BB_DYNAMICS-MIGRATION] User entitlements changed in UEM.
        // TODO: Re-check entitlement-gated features if your app uses them.
    }
}
