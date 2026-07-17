// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Derived from BlackBerry-Dynamics-Android-Samples / 2-Features/OkHttpBD (Apache-2.0).
// Source: MainActivity.java + AsyncUseCaseActivity.java
// See templates/_LICENSE-NOTICE.md for full attribution.
//
// NOTE: Dynamics SDK exposes only Java APIs. BBCustomInterceptor is a Java class;
// Kotlin calls it as a platform type — handle as non-null in practice.
//
// INTERCEPTOR ORDERING: app-side interceptors FIRST, BBCustomInterceptor LAST.

package __APP_PACKAGE__

import com.blackberry.okhttpsupport.interceptor.BBCustomInterceptor
import okhttp3.Interceptor
import okhttp3.OkHttpClient

/**
 * Factory for OkHttpClient instances wired through BlackBerry Dynamics secure transport.
 */
object OkHttpDynamicsClient {

    /**
     * Builds an OkHttpClient with Dynamics interceptor wired.
     * Add app-side interceptors (logging, auth) as varargs — they run BEFORE BBCustomInterceptor.
     */
    // [BB_DYNAMICS-MIGRATION] OkHttpClient routes through Dynamics secure transport via BBCustomInterceptor.
    fun build(vararg appInterceptors: Interceptor): OkHttpClient {
        val bbCustomInterceptor = BBCustomInterceptor()
        return OkHttpClient().newBuilder().apply {
            // App interceptors first (auth headers, logging, retry, etc.)
            appInterceptors.forEach { addInterceptor(it) }
            // [BB_DYNAMICS-MIGRATION] Dynamics transport — must be the last interceptor.
            addInterceptor(bbCustomInterceptor)
        }.build()
    }
}
