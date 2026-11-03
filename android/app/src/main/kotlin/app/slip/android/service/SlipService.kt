package app.slip.android.service

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import app.slip.android.graph
import app.slip.android.ui.formatSize
import app.slip.core.ServerState
import app.slip.core.SlipNode
import app.slip.core.client.SendState
import app.slip.core.net.NetworkUtil
import app.slip.core.server.Decision
import app.slip.core.server.SessionStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.sample
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Keeps the receiving server and discovery alive while the app is in the background, with a persistent
 * notification. Holds a Wi-Fi multicast lock so announcements from other devices get through.
 */
class SlipService : Service() {
    companion object {
        const val ACTION_ACCEPT = "app.slip.android.ACCEPT"
        const val ACTION_DECLINE = "app.slip.android.DECLINE"
        const val ACTION_STOP = "app.slip.android.STOP"

        fun start(context: Context) {
            runCatching { ContextCompat.startForegroundService(context, Intent(context, SlipService::class.java)) }
                .onFailure { Log.w("Slip", "Cannot start service", it) }
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var multicastLock: WifiManager.MulticastLock? = null
    private var node: SlipNode? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var lastTypes = -1
    private var startJob: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Notifications.createChannels(this)
        goForeground(Notifications.service(this, "Slip", "Starting…"), transferring = false)
        acquireMulticastLock()
        startJob = scope.launch {
            val n = graph.node()
            node = n
            withContext(Dispatchers.IO) { n.start() }
            registerNetworkCallback(n)
            observe(n)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_ACCEPT -> node?.receiver?.respond(Decision.Accept())
            ACTION_DECLINE -> node?.receiver?.respond(Decision.Decline)
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
        }
        if (intent?.action == ACTION_ACCEPT || intent?.action == ACTION_DECLINE) {
            NotificationManagerCompat.from(this).cancel(Notifications.ID_REQUEST)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        scope.cancel()
        networkCallback?.let { cb -> runCatching { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(cb) } }
        val n = node
        Thread { n?.stop() }.start()
        runCatching { multicastLock?.release() }
        super.onDestroy()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // dataSync time budget exhausted (Android 15+): drop back to connectedDevice only.
        goForeground(Notifications.service(this, "Slip", "Ready to receive"), transferring = false)
    }

    private fun isForegroundApp() = ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)

    @SuppressLint("MissingPermission")
    private fun notify(id: Int, notification: Notification) {
        runCatching { NotificationManagerCompat.from(this).notify(id, notification) }
    }

    @OptIn(ExperimentalCoroutinesApi::class, FlowPreview::class)
    private fun observe(n: SlipNode) {
        val sendActive = n.sender.jobs.flatMapLatest { jobs ->
            val active = jobs.map { it.state }
            if (active.isEmpty()) flowOf(emptyList()) else combine(active) { it.toList() }
        }
        scope.launch {
            combine(n.server, n.settings, n.receiver.session, sendActive) { server, settings, session, sends ->
                Snapshot(server, settings.alias, session, sends)
            }.sample(500).collect { render(it) }
        }
        scope.launch {
            n.receiver.pending.collect { req ->
                if (req != null && !isForegroundApp()) notify(Notifications.ID_REQUEST, Notifications.request(this@SlipService, req))
                if (req == null) NotificationManagerCompat.from(this@SlipService).cancel(Notifications.ID_REQUEST)
            }
        }
        scope.launch {
            n.receiver.messages.collect { msg ->
                if (!isForegroundApp()) notify(Notifications.ID_MESSAGE, Notifications.message(this@SlipService, msg))
            }
        }
        scope.launch {
            var lastNotified: String? = null
            n.receiver.session.collect { s ->
                if (s != null && s.status == SessionStatus.FINISHED && s.id != lastNotified && !isForegroundApp()) {
                    lastNotified = s.id
                    val done = s.files.values.count { it.status == app.slip.core.server.FileStatus.DONE }
                    notify(Notifications.ID_DONE, Notifications.done(this@SlipService, "Received $done file${if (done == 1) "" else "s"}", "From ${s.sender.alias} · saved to Download/Slip"))
                }
            }
        }
    }

    private data class Snapshot(
        val server: ServerState,
        val alias: String,
        val session: app.slip.core.server.ReceiveSession?,
        val sends: List<SendState>,
    )

    private fun render(s: Snapshot) {
        val receiving = s.session?.takeIf { it.status == SessionStatus.TRANSFERRING }
        val sending = s.sends.filter { !it.status.isTerminal }
        val notification = when {
            receiving != null -> {
                val pct = if (receiving.totalBytes > 0) (receiving.receivedBytes * 100 / receiving.totalBytes).toInt() else -1
                Notifications.service(this, "Receiving from ${receiving.sender.alias}", "${formatSize(receiving.receivedBytes)} of ${formatSize(receiving.totalBytes)}", pct)
            }
            sending.isNotEmpty() -> {
                val total = sending.sumOf { it.totalBytes }
                val sent = sending.sumOf { it.sentBytes }
                val pct = if (total > 0) (sent * 100 / total).toInt() else -1
                Notifications.service(this, "Sending to ${sending.first().targetAlias ?: sending.first().target.host}", "${formatSize(sent)} of ${formatSize(total)}", pct)
            }
            s.server is ServerState.Running -> {
                val ip = NetworkUtil.localAddresses().firstOrNull() ?: "no network"
                Notifications.service(this, "Ready to receive", "${s.alias} · $ip:${s.server.port}")
            }
            s.server is ServerState.Failed -> Notifications.service(this, "Slip can't receive", s.server.message)
            else -> Notifications.service(this, "Slip", "Starting…")
        }
        goForeground(notification, transferring = receiving != null || sending.isNotEmpty())
    }

    private fun goForeground(notification: Notification, transferring: Boolean) {
        val types = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or (if (transferring) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0)
        } else 0
        try {
            if (types != lastTypes) {
                ServiceCompat.startForeground(this, Notifications.ID_SERVICE, notification, types)
                lastTypes = types
            } else {
                getSystemService(NotificationManager::class.java).notify(Notifications.ID_SERVICE, notification)
            }
        } catch (e: Exception) {
            Log.w("Slip", "startForeground failed", e)
        }
    }

    private fun acquireMulticastLock() {
        runCatching {
            val wifi = applicationContext.getSystemService(WifiManager::class.java)
            multicastLock = wifi.createMulticastLock("slip-discovery").apply {
                setReferenceCounted(false)
                acquire()
            }
        }.onFailure { Log.w("Slip", "No multicast lock", it) }
    }

    private fun registerNetworkCallback(n: SlipNode) {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        val cb = object : ConnectivityManager.NetworkCallback() {
            private var lastAddrs: List<String> = emptyList()
            override fun onAvailable(network: Network) = changed()
            override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) = changed()
            private fun changed() {
                val addrs = NetworkUtil.localAddresses()
                if (addrs == lastAddrs) return
                lastAddrs = addrs
                scope.launch(Dispatchers.IO) { n.onNetworkChanged() }
            }
        }
        runCatching { cm.registerDefaultNetworkCallback(cb) }.onSuccess { networkCallback = cb }
    }
}
