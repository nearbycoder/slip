package app.slip.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Card
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.unit.dp
import android.os.Build
import app.slip.android.BuildConfig
import app.slip.android.data.AndroidReceiveStorage
import app.slip.android.data.AppSettings
import app.slip.android.data.ThemeMode
import app.slip.core.SlipConstants
import app.slip.core.SlipNode

@Composable
fun SettingsScreen(vm: MainViewModel, node: SlipNode, settings: AppSettings) {
    Column(
        Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Device", style = MaterialTheme.typography.titleMedium)
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                CommitField("Alias", settings.alias) { v -> vm.updateSettings { it.copy(alias = v) } }
                CommitField("Device model", settings.deviceModel) { v -> vm.updateSettings { it.copy(deviceModel = v.ifBlank { AppSettings.defaultModel() }) } }
            }
        }

        Text("Receiving", style = MaterialTheme.typography.titleMedium)
        Card(Modifier.fillMaxWidth()) {
            ToggleRow("Quick Save", "Accept transfers automatically", settings.quickSave) { on -> vm.updateSettings { it.copy(quickSave = on) } }
            HorizontalDivider()
            ToggleRow("Discoverable", "Announce this device and answer discovery", settings.discoverable) { on -> vm.updateSettings { it.copy(discoverable = on) } }
            HorizontalDivider()
            ToggleRow("Require PIN", "Senders must enter this PIN", settings.pinEnabled) { on -> vm.updateSettings { it.copy(pinEnabled = on) } }
            if (settings.pinEnabled) {
                Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                    CommitField("PIN", settings.pin, keyboard = KeyboardType.NumberPassword) { v -> vm.updateSettings { it.copy(pin = v) } }
                }
            }
            HorizontalDivider()
            Column(Modifier.padding(16.dp)) {
                Text("Save location", style = MaterialTheme.typography.bodyLarge)
                Text(
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) AndroidReceiveStorage.LOCATION_LABEL else "${AndroidReceiveStorage.LOCATION_LABEL} (needs storage permission on this Android version)",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        Text("Network", style = MaterialTheme.typography.titleMedium)
        Card(Modifier.fillMaxWidth()) {
            ToggleRow("Encryption (HTTPS)", "Turn off only for peers that use HTTP mode", settings.https) { on -> vm.updateSettings { it.copy(https = on) } }
            HorizontalDivider()
            Column(Modifier.padding(16.dp)) {
                CommitField("Port", settings.port.toString(), keyboard = KeyboardType.Number) { v ->
                    v.toIntOrNull()?.takeIf { it in 1024..65535 }?.let { p -> vm.updateSettings { it.copy(port = p) } }
                        ?: vm.toast("Port must be 1024–65535")
                }
                Text("Default ${SlipConstants.DEFAULT_PORT}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }

        Text("Appearance", style = MaterialTheme.typography.titleMedium)
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp)) {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    ThemeMode.entries.forEachIndexed { i, mode ->
                        SegmentedButton(
                            selected = settings.theme == mode,
                            onClick = { vm.updateSettings { it.copy(theme = mode) } },
                            shape = SegmentedButtonDefaults.itemShape(i, ThemeMode.entries.size),
                        ) { Text(mode.name.lowercase().replaceFirstChar { it.uppercase() }) }
                    }
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                HorizontalDivider()
                ToggleRow("Dynamic color", "Use colors from your wallpaper", settings.dynamicColor) { on -> vm.updateSettings { it.copy(dynamicColor = on) } }
            }
        }

        Text("About", style = MaterialTheme.typography.titleMedium)
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Slip ${BuildConfig.VERSION_NAME} · LocalSend protocol v${SlipConstants.PROTOCOL_VERSION}")
                Text("Fingerprint", style = MaterialTheme.typography.labelMedium)
                Text(node.identity.fingerprint(settings.https), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** A text field that commits on focus loss / IME done rather than on every keystroke. */
@Composable
private fun CommitField(label: String, value: String, keyboard: KeyboardType = KeyboardType.Text, onCommit: (String) -> Unit) {
    var text by remember(value) { mutableStateOf(value) }
    var hadFocus by remember { mutableStateOf(false) }
    OutlinedTextField(
        value = text,
        onValueChange = { text = it },
        label = { Text(label) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = keyboard, imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { if (text != value) onCommit(text) }),
        modifier = Modifier.fillMaxWidth().onFocusChanged { state ->
            if (hadFocus && !state.isFocused && text != value) onCommit(text)
            hadFocus = state.isFocused
        },
    )
}
