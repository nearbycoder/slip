package app.slip.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.OpenInNew
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.slip.core.SlipNode
import app.slip.core.client.SendFileStatus
import app.slip.core.client.SendJob
import app.slip.core.client.SendStatus
import app.slip.core.server.FileStatus
import app.slip.core.server.ReceiveSession
import app.slip.core.server.SessionStatus
import kotlinx.coroutines.delay
import java.text.DateFormat
import java.util.Date

@Composable
fun TransfersScreen(vm: MainViewModel, node: SlipNode) {
    val jobs by node.sender.jobs.collectAsStateWithLifecycle()
    val current by node.receiver.session.collectAsStateWithLifecycle()
    val history by node.receiver.history.collectAsStateWithLifecycle()
    val texts by node.receiver.textHistory.collectAsStateWithLifecycle()
    val active = current?.takeIf { it.status == SessionStatus.TRANSFERRING }

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (active == null && jobs.isEmpty() && history.isEmpty() && texts.isEmpty()) {
            item { Text("No transfers yet.", color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        if (active != null) {
            item { SectionTitle("Receiving") }
            item { ReceiveCard(active, vm) }
        }
        if (jobs.isNotEmpty()) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SectionTitle("Sent", Modifier.weight(1f))
                    TextButton(onClick = { vm.clearFinishedSends() }) { Text("Clear finished") }
                }
            }
            items(jobs, key = { it.id }) { SendCard(it, vm) }
        }
        val ended = history.filter { it.status != SessionStatus.DECLINED || it.files.values.any { f -> f.status == FileStatus.DONE } }
        if (ended.isNotEmpty()) {
            item { SectionTitle("Received") }
            items(ended, key = { it.id }) { ReceiveCard(it, vm) }
        }
        if (texts.isNotEmpty()) {
            item { SectionTitle("Messages") }
            items(texts, key = { it.receivedAt.toString() + it.text.hashCode() }) { msg ->
                Card(Modifier.fillMaxWidth()) {
                    Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("${msg.sender.alias} · ${DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(msg.receivedAt))}", style = MaterialTheme.typography.labelMedium)
                            Text(msg.text, maxLines = 6, overflow = TextOverflow.Ellipsis)
                        }
                        IconButton(onClick = { vm.copy(msg.text) }) { Icon(Icons.Outlined.ContentCopy, "Copy") }
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionTitle(text: String, modifier: Modifier = Modifier) =
    Text(text, modifier.padding(top = 8.dp), style = MaterialTheme.typography.titleMedium)

@Composable
private fun SendCard(job: SendJob, vm: MainViewModel) {
    val s by job.state.collectAsStateWithLifecycle()
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(s.status) { while (!s.status.isTerminal) { now = System.currentTimeMillis(); delay(500) } }
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("To ${s.targetAlias ?: s.target.host}", style = MaterialTheme.typography.titleSmall)
                    Text(
                        when (s.status) {
                            SendStatus.PREPARING -> "Preparing…"
                            SendStatus.WAITING -> "Waiting for ${s.targetAlias ?: "receiver"} to accept…"
                            SendStatus.AWAITING_PIN -> "PIN required"
                            SendStatus.SENDING -> "${formatSize(s.sentBytes)} of ${formatSize(s.totalBytes)} · ${formatSpeed(s.speed(now))}"
                            SendStatus.DONE -> if (s.isText) "Message delivered" else "Sent ${formatSize(s.sentBytes)} · ${formatSpeed(s.speed())}"
                            SendStatus.DECLINED -> "Declined"
                            SendStatus.BUSY -> "Receiver is busy"
                            SendStatus.PIN_REQUIRED -> "PIN required"
                            SendStatus.TOO_MANY_REQUESTS -> "Too many requests"
                            SendStatus.CANCELLED -> "Cancelled"
                            SendStatus.FAILED -> s.error ?: "Failed"
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = if (s.status == SendStatus.FAILED) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                if (!s.status.isTerminal) TextButton(onClick = { vm.cancelSend(job) }) { Text("Cancel") }
            }
            if (s.status == SendStatus.SENDING) {
                LinearProgressIndicator(
                    progress = { if (s.totalBytes > 0) s.sentBytes.toFloat() / s.totalBytes else 0f },
                    modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                )
            }
            if (!s.isText) s.files.take(20).forEach { f ->
                Row(Modifier.padding(top = 4.dp)) {
                    Text(f.fileName, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.MiddleEllipsis, style = MaterialTheme.typography.bodySmall)
                    Text(
                        when (f.status) {
                            SendFileStatus.QUEUED -> "Queued"
                            SendFileStatus.SENDING -> if (f.size > 0) "${(f.sent * 100 / f.size)}%" else formatSize(f.sent)
                            SendFileStatus.DONE -> "✓"
                            SendFileStatus.SKIPPED -> "Skipped"
                            SendFileStatus.FAILED -> "Failed"
                            SendFileStatus.CANCELLED -> "Cancelled"
                        },
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }
    }
}

@Composable
private fun ReceiveCard(s: ReceiveSession, vm: MainViewModel) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("From ${s.sender.alias}", style = MaterialTheme.typography.titleSmall)
                    Text(
                        when (s.status) {
                            SessionStatus.TRANSFERRING -> "${formatSize(s.receivedBytes)} of ${formatSize(s.totalBytes)}"
                            SessionStatus.FINISHED -> "Received ${formatSize(s.receivedBytes)}"
                            SessionStatus.FAILED -> "Failed"
                            SessionStatus.CANCELLED -> "Cancelled"
                            SessionStatus.DECLINED -> "Declined"
                            SessionStatus.AWAITING -> "Waiting for you"
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                if (s.status == SessionStatus.TRANSFERRING) TextButton(onClick = vm::cancelReceive) { Text("Cancel") }
            }
            if (s.status == SessionStatus.TRANSFERRING) {
                LinearProgressIndicator(
                    progress = { if (s.totalBytes > 0) s.receivedBytes.toFloat() / s.totalBytes else 0f },
                    modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                )
            }
            s.files.values.filter { it.status != FileStatus.SKIPPED }.take(50).forEach { f ->
                val saved = f.saved
                Row(
                    Modifier.fillMaxWidth().then(if (saved != null) Modifier.clickable { vm.open(saved) } else Modifier).padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(saved?.relativePath ?: f.dto.fileName, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.MiddleEllipsis, style = MaterialTheme.typography.bodySmall)
                    when {
                        saved != null -> Icon(Icons.AutoMirrored.Outlined.OpenInNew, "Open", Modifier.padding(start = 8.dp))
                        f.status == FileStatus.RECEIVING -> Text(if (f.dto.size > 0) "${f.bytes * 100 / f.dto.size}%" else formatSize(f.bytes), style = MaterialTheme.typography.bodySmall)
                        f.status == FileStatus.FAILED -> Text(f.error ?: "Failed", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                        f.status == FileStatus.CANCELLED -> Text("Cancelled", style = MaterialTheme.typography.bodySmall)
                        else -> Text("Queued", style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
    }
}
