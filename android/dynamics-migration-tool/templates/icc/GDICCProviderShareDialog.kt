// [BB_DYNAMICS-MIGRATION] This file was added as part of BlackBerry Dynamics migration.
// Provenance: kit-authored. License: Apache-2.0 — see templates/_LICENSE-NOTICE.md.
//
// Compose-first ICC provider chooser for TransferFile / AppKinetics sharing.
// Replaces View-system MaterialAlertDialogBuilder / AlertDialog.Builder chooser
// wiring in @Composable screens. Secure transfer still uses GDServiceClient.sendTo
// (or your TransferFileService helper sendFiles) on a background thread.

package __APP_PACKAGE__

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Display row for a Dynamics share target discovered via getServiceProvidersFor.
 * Map from [com.good.gd.GDServiceProvider] in your coordinator before showing the dialog.
 */
data class ICCProviderOption(
    val displayName: String,
    val targetAddress: String,
)

/**
 * Compose provider chooser for ICC TransferFile sharing.
 *
 * Use from a @Composable screen instead of MaterialAlertDialogBuilder in
 * TransferFileService.showShareChooser(). On selection, call your existing
 * sendFiles(targetAddress, gdContainerPaths) on a background executor.
 */
@Composable
fun GDICCProviderShareDialog(
    title: String,
    providers: List<ICCProviderOption>,
    onProviderSelected: (ICCProviderOption) -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            if (providers.isEmpty()) {
                Text("No compatible Dynamics apps available for sharing.")
            } else {
                Column {
                    providers.forEach { provider ->
                        Text(
                            text = provider.displayName,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { onProviderSelected(provider) }
                                .padding(vertical = 12.dp),
                        )
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        },
    )
}
