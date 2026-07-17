// [BB_DYNAMICS-MIGRATION] Background Authorize entry-point template (Java).
// Derived from BlackBerry Dynamics Android API reference (GDAndroid).
// See steering/70-background-authorize.md and prompts/03c-background-authorize.md.
//
// HOW TO USE:
//   1. Copy this file into the source tree of the entry point being migrated
//      (push service, JobIntentService/JobService, or BroadcastReceiver wrapper).
//   2. Replace __APP_PACKAGE__ with the entry point's package.
//   3. Replace __ENTRY_POINT_CLASS__ with the class name.
//   4. Replace __ENTRY_POINT_BASE__ with the matched base class
//      (e.g. com.google.firebase.messaging.FirebaseMessagingService,
//      androidx.core.app.JobIntentService, android.app.job.JobService).
//   5. Replace __APP_CLASS__ with your Application subclass (the one that
//      holds the singleton GDStateListener registered in onCreate() —
//      see DynamicsApplicationBase.java).
//   6. Replace __HANDLER_METHOD__ with the handler signature appropriate
//      for the base class (onMessageReceived(RemoteMessage),
//      onHandleWork(Intent), onStartJob(JobParameters), etc.).
//   7. Keep the canAuthorizeAutonomously -> serviceInit ordering. Keep
//      the dynamicsBackgroundAuthorizeStarted gate. Do not implement
//      GDStateListener on this class.

package __APP_PACKAGE__;

import android.util.Log;

import __ENTRY_POINT_BASE__;

import com.good.gd.GDAndroid;
import com.good.gd.error.GDInitializationError;

// [BB_DYNAMICS-MIGRATION] Background service entry point prepared for Dynamics Background Authorize.
// Requires Application.onCreate() to have registered a singleton GDStateListener via
// GDAndroid.getInstance().setGDStateListener(...).
public final class __ENTRY_POINT_CLASS__ extends __ENTRY_POINT_BASE__ {
    private static final String TAG = "__ENTRY_POINT_CLASS__";

    // [BB_DYNAMICS-MIGRATION] Set by serviceInit(this) in onCreate; gates every
    // secure-API access in the handler. volatile because the handler may run on
    // a different thread than onCreate (FCM dispatcher / JobScheduler thread).
    private volatile boolean dynamicsBackgroundAuthorizeStarted = false;

    @Override
    public void onCreate() {
        super.onCreate();

        try {
            if (!GDAndroid.getInstance().canAuthorizeAutonomously(this)) {
                // [BB_DYNAMICS-MIGRATION] Background Authorize cannot run now.
                // Do not touch GDFileSystem, secure SQLite, GDHttpClient, GDSocket,
                // policy APIs, or repositories that use them from this service.
                Log.i(TAG, "Dynamics autonomous authorization is not available; background work will be skipped/retried.");
                return;
            }

            dynamicsBackgroundAuthorizeStarted = GDAndroid.getInstance().serviceInit(this);
            if (!dynamicsBackgroundAuthorizeStarted) {
                // [BB_DYNAMICS-MIGRATION] serviceInit returned false: no authorization callback will follow.
                Log.i(TAG, "Dynamics serviceInit returned false; background work will be skipped/retried.");
            }
        } catch (GDInitializationError error) {
            // [BB_DYNAMICS-MIGRATION] Treat initialization failure as a safe no-op/retry path.
            Log.w(TAG, "Dynamics Background Authorize initialization failed.", error);
            dynamicsBackgroundAuthorizeStarted = false;
        }
    }

    // Replace this with the real handler signature for __ENTRY_POINT_BASE__.
    // For FirebaseMessagingService: public void onMessageReceived(RemoteMessage message)
    // For JobIntentService:         protected void onHandleWork(Intent intent)
    // For JobService:               public boolean onStartJob(JobParameters params)
    public void __HANDLER_METHOD__(Object payload) {
        // [BB_DYNAMICS-MIGRATION] FCM-style payloads must remain metadata-only.
        // Do not put sensitive enterprise data directly in notification title/body/data.
        if (!dynamicsBackgroundAuthorizeStarted) {
            scheduleRetryWithoutSecureApiAccess(payload);
            return;
        }

        // [BB_DYNAMICS-MIGRATION] Do not access secure APIs directly here unless
        // the app's singleton GDStateListener has observed onAuthorized().
        if (!__APP_CLASS__.isContainerAuthorized()) {
            __APP_CLASS__.runOnAuthorized(() -> handleAuthorizedWork(payload));
            return;
        }

        handleAuthorizedWork(payload);
    }

    private void handleAuthorizedWork(Object payload) {
        // [BB_DYNAMICS-MIGRATION] Safe only after Background Authorize/authorization completed.
        // Fetch enterprise data through migrated secure networking/storage paths here.
        // Example:
        //   repository.syncFromPush(payload);
    }

    private void scheduleRetryWithoutSecureApiAccess(Object payload) {
        // [BB_DYNAMICS-MIGRATION] Safe fallback path.
        // Use WorkManager/JobScheduler retry metadata only; do not read/write secure
        // container data or perform secure network calls here.
    }
}
