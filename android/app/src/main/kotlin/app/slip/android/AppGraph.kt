package app.slip.android

import android.content.Context
import android.util.Log
import app.slip.android.data.AndroidReceiveStorage
import app.slip.android.data.AppSettings
import app.slip.android.data.SettingsRepository
import app.slip.core.SlipNode
import app.slip.core.client.SendSource
import app.slip.core.identity.FileIdentityStore
import app.slip.core.server.TextMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

enum class SelectionKind { FILE, MEDIA, FOLDER, TEXT }

/** One entry in the send tray: a file, a folder (many sources) or a text snippet. */
data class SelectionItem(
    val kind: SelectionKind,
    val label: String,
    val sources: List<SendSource>,
    val id: String = UUID.randomUUID().toString(),
) {
    val size: Long get() = sources.sumOf { it.size.coerceAtLeast(0) }
}

/** Process-wide objects: settings, the protocol node, and the send tray (shared by the UI, share intents, service). */
class AppGraph(private val context: Context) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    val settingsRepo = SettingsRepository(context)
    val settings: StateFlow<AppSettings?> = settingsRepo.settings.stateIn(scope, SharingStarted.Eagerly, null)

    private val nodeMutex = Mutex()
    private val _node = MutableStateFlow<SlipNode?>(null)
    val node: StateFlow<SlipNode?> = _node.asStateFlow()

    private val _selection = MutableStateFlow<List<SelectionItem>>(emptyList())
    val selection: StateFlow<List<SelectionItem>> = _selection.asStateFlow()

    /** The most recent text message not yet dismissed in the UI. */
    val unseenMessage = MutableStateFlow<TextMessage?>(null)

    /** Creates (once) the node with the persisted identity and settings, and keeps it in sync with settings. */
    suspend fun node(): SlipNode = nodeMutex.withLock {
        _node.value ?: withContext(Dispatchers.IO) {
            val s = settingsRepo.load()
            val identity = FileIdentityStore(File(context.filesDir, "identity")).loadOrCreate()
            val node = SlipNode(
                identity = identity,
                initialSettings = s.toNodeSettings(),
                storage = { AndroidReceiveStorage(context) },
                log = { Log.d("Slip", it) },
            )
            _node.value = node
            scope.launch(Dispatchers.IO) {
                settingsRepo.settings
                    .map { it.toNodeSettings() }
                    .distinctUntilChanged()
                    .collect { if (it.alias.isNotBlank()) node.updateSettings(it) }
            }
            scope.launch { node.receiver.messages.collect { unseenMessage.value = it } }
            node
        }
    }

    fun addToSelection(items: List<SelectionItem>) = _selection.update { it + items }
    fun removeFromSelection(id: String) = _selection.update { list -> list.filter { it.id != id } }
    fun clearSelection() = _selection.update { emptyList() }
}
