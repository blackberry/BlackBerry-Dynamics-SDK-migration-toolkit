// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Provenance: kit-authored. License: Apache-2.0 — see templates/_LICENSE-NOTICE.md.
//
// Interim stop-gap adapter for Jetpack Compose clipboard call sites until
// BlackBerry Dynamics ships official Compose-native clipboard APIs.
// Routes plain-text copy/read through com.good.gd.content.ClipboardManager
// (DLP-enforced). Do not use androidx.compose.ui.platform.LocalClipboard*
// or Compose ClipboardManager for app-controlled copy/paste after migration.

package __APP_PACKAGE__

import android.content.ClipData
import android.content.Context
import com.good.gd.content.ClipboardManager

/**
 * Interim Compose clipboard adapter backed by Dynamics secure ClipboardManager.
 *
 * Use for deterministic plain-text copy/paste from @Composable code.
 * Rich ClipEntry payloads (URI, intent, HTML) are not supported — record a
 * high-priority manual remediation entry in migration-report.json instead.
 */
class GDClipboardAdapter(context: Context) {

    private val clipboard: ClipboardManager = ClipboardManager.getInstance(context)

    /** Copy plain text to the Dynamics secure clipboard (DLP-enforced). */
    fun setPlainText(text: CharSequence, label: String = DEFAULT_LABEL) {
        val clip = ClipData.newPlainText(label, text)
        clipboard.setPrimaryClip(clip)
    }

    /** Read plain text from the Dynamics secure clipboard, or null if empty. */
    fun getPlainText(): CharSequence? {
        if (!clipboard.hasPrimaryClip()) {
            return null
        }
        val clip = clipboard.primaryClip ?: return null
        if (clip.itemCount == 0) {
            return null
        }
        return clip.getItemAt(0).text
    }

    fun hasPlainText(): Boolean = clipboard.hasPrimaryClip()

    companion object {
        private const val DEFAULT_LABEL = "dynamics-clipboard"
    }
}
