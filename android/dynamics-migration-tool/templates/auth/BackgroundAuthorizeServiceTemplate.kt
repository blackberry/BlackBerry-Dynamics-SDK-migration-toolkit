// [BB_DYNAMICS-MIGRATION] Background Authorize entry-point template (Kotlin).
// Derived from BlackBerry Dynamics Android API reference (GDAndroid).
// See steering/70-background-authorize.md and prompts/03c-background-authorize.md.
//
// HOW TO USE: see the matching .java template header — same placeholder set.

package __APP_PACKAGE__

import android.util.Log

import __ENTRY_POINT_BASE__

import com.good.gd.GDAndroid
import com.good.gd.error.GDInitializationError

// [BB_DYNAMICS-MIGRATION] Background service entry point prepared for Dynamics Background Authorize.
// Requires Application.onCreate() to have registered a singleton GDStateListener via
// GDAndroid.getInstance().setGDStateListener(...).
class __ENTRY_POINT_CLASS__ : __ENTRY_POINT_BASE__() {

    // [BB_DYNAMICS-MIGRATION] Set by serviceInit(this) in onCreate; gates every
    // secure-API access in the handler. @Volatile because the handler may run on
    // a different thread than onCreate (FCM dispatcher / JobScheduler thread).
    @Volatile
    private var dynamicsBackgroundAuthorizeStarted: Boolean = false

    override fun onCreate() {
        super.onCreate()

        try {
            if (!GDAndroid.getInstance().canAuthorizeAutonomously(this)) {
                // [BB_DYNAMICS-MIGRATION] Background Authorize cannot run now.
                // Do not touch GDFileSystem, secure SQLite, GDHttpClient, GDSocket,
                // policy APIs, or repositories that use them from this service.
                Log.i(TAG, "Dynamics autonomous authorization is not available; background work will be skipped/retried.")
                return
            }

            dynamicsBackgroundAuthorizeStarted = GDAndroid.getInstance().serviceInit(this)
            if (!dynamicsBackgroundAuthorizeStarted) {
                // [BB_DYNAMICS-MIGRATION] serviceInit returned false: no authorization callback will follow.
                Log.i(TAG, "Dynamics serviceInit returned false; background work will be skipped/retried.")
            }
        } catch (error: GDInitializationError) {
            // [BB_DYNAMICS-MIGRATION] Treat initialization failure as a safe no-op/retry path.
            Log.w(TAG, "Dynamics Background Authorize initialization failed.", error)
            dynamicsBackgroundAuthorizeStarted = false
        }
    }

    // Replace this with the real handler signature for __ENTRY_POINT_BASE__.
    // For FirebaseMessagingService: override fun onMessageReceived(message: RemoteMessage)
    // For JobIntentService:         override fun onHandleWork(intent: Intent)
    // For JobService:               override fun onStartJob(params: JobParameters): Boolean
    fun __HANDLER_METHOD__(payload: Any) {
        // [BB_DYNAMICS-MIGRATION] FCM-style payloads must remain metadata-only.
        // Do not put sensitive enterprise data directly in notification title/body/data.
        if (!dynamicsBackgroundAuthorizeStarted) {
            scheduleRetryWithoutSecureApiAccess(payload)
            return
        }

        // [BB_DYNAMICS-MIGRATION] Do not access secure APIs directly here unless
        // the app's singleton GDStateListener has observed onAuthorized().
        if (!__APP_CLASS__.isContainerAuthorized()) {
            __APP_CLASS__.runOnAuthorized(Runnable { handleAuthorizedWork(payload) })
            return
        }

        handleAuthorizedWork(payload)
    }

    private fun handleAuthorizedWork(payload: Any) {
        // [BB_DYNAMICS-MIGRATION] Safe only after Background Authorize/authorization completed.
        // Fetch enterprise data through migrated secure networking/storage paths here.
        // Example:
        //   repository.syncFromPush(payload)
    }

    private fun scheduleRetryWithoutSecureApiAccess(payload: Any) {
        // [BB_DYNAMICS-MIGRATION] Safe fallback path.
        // Use WorkManager/JobScheduler retry metadata only; do not read/write secure
        // container data or perform secure network calls here.
    }

    companion object {
        private const val TAG = "__ENTRY_POINT_CLASS__"
    }
}
