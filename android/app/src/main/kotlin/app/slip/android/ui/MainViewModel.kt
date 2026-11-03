package app.slip.android.ui

import android.app.Application
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import app.slip.android.SelectionItem
import app.slip.android.SelectionKind
import app.slip.android.data.AndroidReceiveStorage
import app.slip.android.data.AppSettings
import app.slip.android.data.UriSource
import app.slip.android.graph
import app.slip.core.SlipNode
import app.slip.core.client.PeerAddress
import app.slip.core.client.SendJob
import app.slip.core.client.TextSource
import app.slip.core.model.Protocol
import app.slip.core.server.Decision
import app.slip.core.server.SavedFile
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class Tab { RECEIVE, SEND, TRANSFERS, SETTINGS }

/** A PIN prompt raised by an outgoing transfer; complete [answer] with the PIN or null to give up. */
data class PinPrompt(val target: String, val attempt: Int, val answer: CompletableDeferred<String?>)

class MainViewModel(app: Application) : AndroidViewModel(app) {
    private val graph = app.graph
    val node: StateFlow<SlipNode?> = graph.node
    val settings: StateFlow<AppSettings?> = graph.settings
    val selection = graph.selection
    val unseenMessage = graph.unseenMessage

    private val _tab = MutableStateFlow(Tab.RECEIVE)
    val tab: StateFlow<Tab> = _tab.asStateFlow()

    private val _pinPrompt = MutableStateFlow<PinPrompt?>(null)
    val pinPrompt: StateFlow<PinPrompt?> = _pinPrompt.asStateFlow()

    private val _snackbar = MutableSharedFlow<String>(extraBufferCapacity = 8)
    val snackbar: SharedFlow<String> = _snackbar.asSharedFlow()

    init {
        viewModelScope.launch { graph.node() }
    }

    fun selectTab(tab: Tab) { _tab.value = tab }
    fun toast(msg: String) { _snackbar.tryEmit(msg) }

    // --- selection -------------------------------------------------------------------------------------------

    fun addUris(uris: List<Uri>, kind: SelectionKind = SelectionKind.FILE) {
        if (uris.isEmpty()) return
        viewModelScope.launch {
            val items = withContext(Dispatchers.IO) {
                uris.map { uri ->
                    val src = UriSource.from(getApplication(), uri)
                    SelectionItem(kind, src.fileName, listOf(src))
                }
            }
            graph.addToSelection(items)
        }
    }

    fun addFolder(tree: Uri?) {
        tree ?: return
        viewModelScope.launch {
            val (name, sources) = withContext(Dispatchers.IO) { UriSource.fromTree(getApplication(), tree) }
            if (sources.isEmpty()) toast("“$name” is empty") else graph.addToSelection(listOf(SelectionItem(SelectionKind.FOLDER, name, sources)))
        }
    }

    fun addText(text: String) {
        if (text.isBlank()) return
        graph.addToSelection(listOf(SelectionItem(SelectionKind.TEXT, text, listOf(TextSource(text)))))
    }

    fun paste() {
        val cm = getApplication<Application>().getSystemService(ClipboardManager::class.java)
        val clip = cm?.primaryClip
        if (clip == null || clip.itemCount == 0) { toast("Clipboard is empty"); return }
        val uris = ArrayList<Uri>()
        for (i in 0 until clip.itemCount) {
            val item = clip.getItemAt(i)
            val uri = item.uri
            if (uri != null) uris += uri
            else item.coerceToText(getApplication())?.toString()?.let(::addText)
        }
        addUris(uris)
    }

    fun remove(id: String) = graph.removeFromSelection(id)
    fun clearSelection() = graph.clearSelection()

    /** Handles ACTION_SEND / ACTION_SEND_MULTIPLE from the share sheet. */
    fun handleShare(intent: Intent) {
        val uris = ArrayList<Uri>()
        when (intent.action) {
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let(uris::add)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let(uris::addAll)
            }
            else -> return
        }
        intent.clipData?.let { clip -> for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { if (it !in uris) uris += it } }
        if (uris.isNotEmpty()) addUris(uris)
        else intent.getStringExtra(Intent.EXTRA_TEXT)?.let(::addText)
        selectTab(Tab.SEND)
    }

    // --- sending ---------------------------------------------------------------------------------------------

    fun sendTo(address: PeerAddress, alias: String?) {
        val n = node.value ?: return
        val items = selection.value
        if (items.isEmpty()) { toast("Pick files or text to send first"); return }
        val sources = items.flatMap { it.sources }
        val label = alias ?: address.host
        val job: SendJob = n.sender.send(address, sources, alias) { attempt ->
            val answer = CompletableDeferred<String?>()
            _pinPrompt.value = PinPrompt(label, attempt, answer)
            try { answer.await() } finally { _pinPrompt.value = null }
        }
        toast("Sending to $label…")
        viewModelScope.launch {
            val result = job.await()
            when (result.status) {
                app.slip.core.client.SendStatus.DONE -> { toast("Sent to $label"); graph.clearSelection() }
                app.slip.core.client.SendStatus.CANCELLED -> {}
                else -> {
                    android.util.Log.w("Slip", "send to $label: ${result.status} ${result.error}")
                    toast(result.error ?: result.status.name)
                }
            }
        }
        selectTab(Tab.TRANSFERS)
    }

    fun sendToManual(input: String, https: Boolean) {
        val n = node.value ?: return
        val address = PeerAddress.parse(input, if (https) Protocol.HTTPS else Protocol.HTTP)
        viewModelScope.launch {
            val info = n.addManualPeer(address).getOrElse {
                android.util.Log.w("Slip", "manual peer $address failed", it)
                toast("Couldn't reach $address: ${it.message}")
                return@launch
            }
            sendTo(address, info.alias)
        }
    }

    fun refresh() { node.value?.refresh(forceScan = false) }
    fun scan() { node.value?.refresh(forceScan = true); toast("Scanning the local network…") }

    fun cancelSend(job: SendJob) = job.cancel()
    fun clearFinishedSends() = node.value?.sender?.clearFinished()

    // --- receiving -------------------------------------------------------------------------------------------

    fun accept(fileIds: Set<String>?) = node.value?.receiver?.respond(Decision.Accept(fileIds))
    fun decline() = node.value?.receiver?.respond(Decision.Decline)
    fun cancelReceive() = node.value?.receiver?.cancelCurrent()
    fun dismissMessage() { graph.unseenMessage.value = null }

    fun copy(text: String) {
        val cm = getApplication<Application>().getSystemService(ClipboardManager::class.java)
        cm?.setPrimaryClip(ClipData.newPlainText("Slip", text))
        toast("Copied")
    }

    fun open(saved: SavedFile) {
        val ctx = getApplication<Application>()
        val uri = runCatching { AndroidReceiveStorage.viewUri(ctx, saved) }.getOrElse { toast("Can't open ${saved.displayName}"); return }
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, saved.mimeType)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            ctx.startActivity(Intent.createChooser(view, saved.displayName).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: ActivityNotFoundException) {
            toast("No app can open ${saved.displayName}")
        }
    }

    // --- settings --------------------------------------------------------------------------------------------

    fun updateSettings(change: (AppSettings) -> AppSettings) {
        viewModelScope.launch { graph.settingsRepo.update(change) }
    }
}
