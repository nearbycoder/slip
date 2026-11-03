package app.slip.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.WifiTethering
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.slip.android.data.AndroidReceiveStorage
import app.slip.android.data.AppSettings
import app.slip.core.ServerState
import app.slip.core.SlipNode
import app.slip.core.net.NetworkUtil
import app.slip.core.server.SessionStatus
import kotlinx.coroutines.delay

@Composable
fun ReceiveScreen(vm: MainViewModel, node: SlipNode, settings: AppSettings) {
    val server by node.server.collectAsStateWithLifecycle()
    val session by node.receiver.session.collectAsStateWithLifecycle()
    var addresses by remember { mutableStateOf(NetworkUtil.localAddresses()) }
    LaunchedEffect(Unit) { while (true) { addresses = NetworkUtil.localAddresses(); delay(5_000) } }

    Column(
        Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        val running = server as? ServerState.Running
        Card(
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Box(
                    Modifier.size(96.dp).background(MaterialTheme.colorScheme.primary, CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        if (server is ServerState.Failed) Icons.Outlined.ErrorOutline else Icons.Outlined.WifiTethering,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onPrimary,
                        modifier = Modifier.size(48.dp),
                    )
                }
                Spacer(Modifier.size(16.dp))
                Text(
                    when (server) {
                        is ServerState.Running -> if (settings.discoverable) "Ready to receive" else "Receiving (hidden)"
                        is ServerState.Failed -> "Can't receive"
                        ServerState.Stopped -> "Starting…"
                    },
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onPrimaryContainer,
                )
                Text(
                    settings.alias,
                    style = MaterialTheme.typography.headlineMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onPrimaryContainer,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.size(8.dp))
                (server as? ServerState.Failed)?.let {
                    Text(it.message, color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center)
                }
                if (running != null) {
                    Text(
                        (addresses.ifEmpty { listOf("No network") }).joinToString("\n") { "$it:${running.port}" },
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onPrimaryContainer,
                        textAlign = TextAlign.Center,
                    )
                    Text(
                        (if (running.https) "HTTPS" else "HTTP") + " · saves to ${AndroidReceiveStorage.LOCATION_LABEL}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onPrimaryContainer,
                    )
                }
            }
        }

        Card(Modifier.fillMaxWidth()) {
            ToggleRow("Discoverable", "Let nearby devices see this phone", settings.discoverable) { on ->
                vm.updateSettings { it.copy(discoverable = on) }
            }
            HorizontalDivider()
            ToggleRow("Quick Save", "Accept incoming files without asking", settings.quickSave) { on ->
                vm.updateSettings { it.copy(quickSave = on) }
            }
        }

        session?.takeIf { it.status == SessionStatus.TRANSFERRING }?.let { s ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp)) {
                    Text("Receiving from ${s.sender.alias}", style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.size(8.dp))
                    LinearProgressIndicator(
                        progress = { if (s.totalBytes > 0) s.receivedBytes.toFloat() / s.totalBytes else 0f },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("${formatSize(s.receivedBytes)} of ${formatSize(s.totalBytes)}", Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
                        TextButton(onClick = vm::cancelReceive) { Text("Cancel") }
                    }
                }
            }
        }
    }
}

@Composable
fun ToggleRow(title: String, subtitle: String?, checked: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            if (subtitle != null) Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = checked, onCheckedChange = onChange, enabled = enabled)
    }
}
