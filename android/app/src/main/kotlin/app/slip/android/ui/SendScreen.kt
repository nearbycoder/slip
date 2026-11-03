package app.slip.android.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Lan
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.TextFields
import androidx.compose.material.icons.outlined.Radar
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.slip.android.SelectionKind
import app.slip.core.SlipNode

@Composable
fun SendScreen(vm: MainViewModel, node: SlipNode) {
    val selection by vm.selection.collectAsStateWithLifecycle()
    val peers by node.peers.peers.collectAsStateWithLifecycle()
    val settings by node.settings.collectAsStateWithLifecycle()
    var showText by remember { mutableStateOf(false) }
    var showManual by remember { mutableStateOf(false) }

    val media = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { vm.addUris(it, SelectionKind.MEDIA) }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { vm.addUris(it) }
    val folder = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { vm.addFolder(it) }

    LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            Text("Selection", style = MaterialTheme.typography.titleMedium)
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                AssistChip(onClick = { files.launch(arrayOf("*/*")) }, label = { Text("File") }, leadingIcon = { Icon(Icons.Outlined.Description, null) })
                AssistChip(onClick = { media.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)) }, label = { Text("Media") }, leadingIcon = { Icon(Icons.Outlined.Image, null) })
                AssistChip(onClick = { folder.launch(null) }, label = { Text("Folder") }, leadingIcon = { Icon(Icons.Outlined.Folder, null) })
                AssistChip(onClick = { showText = true }, label = { Text("Text") }, leadingIcon = { Icon(Icons.Outlined.TextFields, null) })
                AssistChip(onClick = vm::paste, label = { Text("Paste") }, leadingIcon = { Icon(Icons.Outlined.ContentPaste, null) })
            }
        }
        if (selection.isNotEmpty()) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    val total = selection.sumOf { it.size }
                    val count = selection.sumOf { it.sources.size }
                    Text("$count item${if (count == 1) "" else "s"} · ${formatSize(total)}", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                    TextButton(onClick = vm::clearSelection) { Text("Clear") }
                }
            }
            items(selection, key = { it.id }) { item ->
                OutlinedCard(Modifier.fillMaxWidth()) {
                    ListItem(
                        leadingContent = {
                            Icon(
                                when (item.kind) {
                                    SelectionKind.FILE -> Icons.Outlined.Description
                                    SelectionKind.MEDIA -> Icons.Outlined.Image
                                    SelectionKind.FOLDER -> Icons.Outlined.Folder
                                    SelectionKind.TEXT -> Icons.Outlined.TextFields
                                },
                                null,
                            )
                        },
                        headlineContent = { Text(item.label, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        supportingContent = {
                            Text(
                                when (item.kind) {
                                    SelectionKind.FOLDER -> "${item.sources.size} files · ${formatSize(item.size)}"
                                    SelectionKind.TEXT -> "Text · ${formatSize(item.size)}"
                                    else -> formatSize(item.size)
                                },
                            )
                        },
                        trailingContent = { IconButton(onClick = { vm.remove(item.id) }) { Icon(Icons.Outlined.Close, "Remove") } },
                    )
                }
            }
        }
        item {
            Row(Modifier.padding(top = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Nearby devices", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
                IconButton(onClick = vm::scan) { Icon(Icons.Outlined.Radar, "Scan network") }
                IconButton(onClick = vm::refresh) { Icon(Icons.Outlined.Refresh, "Refresh") }
            }
        }
        if (peers.isEmpty()) {
            item {
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp)) {
                        Text("Looking for devices…", style = MaterialTheme.typography.bodyLarge)
                        Text(
                            "Make sure the other device runs Slip or LocalSend on the same Wi-Fi. Tap scan to probe the network.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }
        items(peers, key = { it.fingerprint }) { peer ->
            Card(Modifier.fillMaxWidth().clickable { vm.sendTo(peer.address, peer.info.alias) }) {
                ListItem(
                    leadingContent = { Icon(deviceIcon(peer.info.type), null, Modifier.size(32.dp)) },
                    headlineContent = { Text(peer.info.alias) },
                    supportingContent = { Text(listOfNotNull(peer.info.deviceModel, "${peer.ip}:${peer.info.port}").joinToString(" · ")) },
                )
            }
        }
        item {
            TextButton(onClick = { showManual = true }) {
                Icon(Icons.Outlined.Lan, null)
                Text("  Send to IP address")
            }
        }
    }

    if (showText) TextComposeDialog(onDismiss = { showText = false }, onAdd = vm::addText)
    if (showManual) ManualSendDialog(settings.https, onDismiss = { showManual = false }, onSend = vm::sendToManual)
}
