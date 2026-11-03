package app.slip.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.slip.core.SlipNode
import app.slip.core.server.IncomingRequest

/** Incoming transfer prompt, text-message viewer and PIN prompt — shown over any tab. */
@Composable
fun IncomingDialogs(vm: MainViewModel, node: SlipNode) {
    val pending by node.receiver.pending.collectAsStateWithLifecycle()
    val message by vm.unseenMessage.collectAsStateWithLifecycle()
    val pin by vm.pinPrompt.collectAsStateWithLifecycle()

    pending?.let { IncomingDialog(it, onAccept = vm::accept, onDecline = { vm.decline() }) }
    if (pending == null) message?.let { msg ->
        AlertDialog(
            onDismissRequest = vm::dismissMessage,
            title = { Text("Message from ${msg.sender.alias}") },
            text = {
                SelectionContainer(Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState())) { Text(msg.text) }
            },
            confirmButton = { TextButton(onClick = { vm.copy(msg.text); vm.dismissMessage() }) { Text("Copy") } },
            dismissButton = { TextButton(onClick = vm::dismissMessage) { Text("Close") } },
        )
    }
    pin?.let { prompt ->
        var value by remember(prompt) { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { prompt.answer.complete(null) },
            title = { Text("PIN required") },
            text = {
                Column {
                    Text(if (prompt.attempt == 1) "${prompt.target} requires a PIN." else "Wrong PIN, try again.")
                    Spacer(Modifier.size(12.dp))
                    OutlinedTextField(
                        value = value, onValueChange = { value = it }, singleLine = true, label = { Text("PIN") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                    )
                }
            },
            confirmButton = { TextButton(onClick = { prompt.answer.complete(value) }, enabled = value.isNotEmpty()) { Text("Send") } },
            dismissButton = { TextButton(onClick = { prompt.answer.complete(null) }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun IncomingDialog(request: IncomingRequest, onAccept: (Set<String>?) -> Unit, onDecline: () -> Unit) {
    var chosen by remember(request.id) { mutableStateOf(request.files.map { it.id }.toSet()) }
    AlertDialog(
        onDismissRequest = {},
        icon = { Icon(deviceIcon(request.sender.type), contentDescription = null) },
        title = { Text("${request.sender.alias} wants to send") },
        text = {
            Column {
                Text(
                    listOfNotNull(request.sender.deviceModel, request.senderIp).joinToString(" · ") +
                        "\n${request.files.size} file${if (request.files.size == 1) "" else "s"} · ${formatSize(request.totalSize)}",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.size(8.dp))
                LazyColumn(Modifier.heightIn(max = 280.dp)) {
                    items(request.files, key = { it.id }) { f ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            if (request.files.size > 1) {
                                Checkbox(checked = f.id in chosen, onCheckedChange = { on -> chosen = if (on) chosen + f.id else chosen - f.id })
                            }
                            Column(Modifier.weight(1f)) {
                                Text(f.fileName, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
                                Text(formatSize(f.size), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onAccept(if (chosen.size == request.files.size) null else chosen) }, enabled = chosen.isNotEmpty()) {
                Text("Accept")
            }
        },
        dismissButton = { TextButton(onClick = onDecline) { Text("Decline") } },
    )
}

@Composable
fun TextComposeDialog(onDismiss: () -> Unit, onAdd: (String) -> Unit) {
    var text by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Text message") },
        text = {
            OutlinedTextField(value = text, onValueChange = { text = it }, minLines = 3, maxLines = 8, modifier = Modifier.fillMaxWidth(), placeholder = { Text("Type or paste text") })
        },
        confirmButton = { TextButton(onClick = { onAdd(text); onDismiss() }, enabled = text.isNotBlank()) { Text("Add") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
fun ManualSendDialog(defaultHttps: Boolean, onDismiss: () -> Unit, onSend: (String, Boolean) -> Unit) {
    var address by remember { mutableStateOf("") }
    var https by remember { mutableStateOf(defaultHttps) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Send to address") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = address, onValueChange = { address = it.trim() }, singleLine = true,
                    label = { Text("IP or IP:port") }, placeholder = { Text("192.168.1.20:53317") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("HTTPS", Modifier.weight(1f))
                    Switch(checked = https, onCheckedChange = { https = it })
                }
            }
        },
        confirmButton = { TextButton(onClick = { onSend(address, https); onDismiss() }, enabled = address.isNotBlank()) { Text("Send") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
fun Gap(width: Int = 0, height: Int = 0) = Spacer(Modifier.width(width.dp).size(width.dp, height.dp))
