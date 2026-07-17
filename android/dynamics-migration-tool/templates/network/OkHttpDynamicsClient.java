// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Derived from BlackBerry-Dynamics-Android-Samples / 2-Features/OkHttpBD (Apache-2.0).
// Source: MainActivity.java + AsyncUseCaseActivity.java
// See templates/_LICENSE-NOTICE.md for full attribution.
//
// HOW TO USE:
//   1. Replace __APP_PACKAGE__ with your application package.
//   2. Find every place in your app that creates an OkHttpClient (or OkHttpClient.Builder).
//   3. For EACH construction site, chain .addInterceptor(new BBCustomInterceptor())
//      as shown in buildClient() below.
//   4. INTERCEPTOR ORDERING: BBCustomInterceptor must be added AFTER any app-side
//      interceptors (auth headers, logging, retry). The ordering is:
//        app interceptors → BBCustomInterceptor (last)
//   5. All network calls MUST happen after onAuthorized() fires.

package __APP_PACKAGE__;

import com.blackberry.okhttpsupport.interceptor.BBCustomInterceptor;

import okhttp3.OkHttpClient;

/**
 * Factory for OkHttpClient instances wired through BlackBerry Dynamics secure transport.
 *
 * BBCustomInterceptor routes all OkHttp requests through the Dynamics container,
 * enforcing UEM proxy policy, certificate trust, and DLP controls.
 *
 * BBCookieJar is optional — include it when your app uses cookie-based sessions
 * that need to be managed by the Dynamics container.
 */
public final class OkHttpDynamicsClient {

    private OkHttpDynamicsClient() {}

    /**
     * Builds an OkHttpClient with the Dynamics interceptor wired.
     * Replace the comment below with any app-side interceptors your app needs
     * (logging, auth headers, retry logic) — add them BEFORE bbCustomInterceptor.
     */
    // [BB_DYNAMICS-MIGRATION] OkHttpClient now routes through Dynamics secure transport via BBCustomInterceptor.
    public static OkHttpClient build() {
        BBCustomInterceptor bbCustomInterceptor = new BBCustomInterceptor();

        return new OkHttpClient().newBuilder()
                // TODO: Add app-side interceptors here (logging, auth headers, etc.)
                //       They must come BEFORE bbCustomInterceptor.
                .addInterceptor(bbCustomInterceptor)  // [BB_DYNAMICS-MIGRATION] Dynamics transport — must be last interceptor.
                .build();
    }

    /**
     * Builds an OkHttpClient with an app-side interceptor AND the Dynamics interceptor.
     * Shows the correct ordering: app interceptor first, BB interceptor last.
     */
    public static OkHttpClient buildWithAppInterceptor(okhttp3.Interceptor appInterceptor) {
        BBCustomInterceptor bbCustomInterceptor = new BBCustomInterceptor();

        return new OkHttpClient().newBuilder()
                .addInterceptor(appInterceptor)        // App interceptor FIRST.
                .addInterceptor(bbCustomInterceptor)   // [BB_DYNAMICS-MIGRATION] BB interceptor LAST.
                .build();
    }
}
