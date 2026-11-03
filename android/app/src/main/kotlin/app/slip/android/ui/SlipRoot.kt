package app.slip.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.SwapVert
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.lifecycle.compose.collectAsStateWithLifecycle

private data class TabSpec(val tab: Tab, val label: String, val selected: ImageVector, val unselected: ImageVector)

private val tabs = listOf(
    TabSpec(Tab.RECEIVE, "Receive", Icons.Filled.Download, Icons.Outlined.Download),
    TabSpec(Tab.SEND, "Send", Icons.AutoMirrored.Filled.Send, Icons.AutoMirrored.Outlined.Send),
    TabSpec(Tab.TRANSFERS, "Transfers", Icons.Filled.SwapVert, Icons.Outlined.SwapVert),
    TabSpec(Tab.SETTINGS, "Settings", Icons.Filled.Settings, Icons.Outlined.Settings),
)

@Composable
fun SlipRoot(vm: MainViewModel) {
    val tab by vm.tab.collectAsStateWithLifecycle()
    val node by vm.node.collectAsStateWithLifecycle()
    val settings by vm.settings.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(Unit) { vm.snackbar.collect { snackbar.showSnackbar(it) } }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        bottomBar = {
            NavigationBar {
                tabs.forEach { spec ->
                    NavigationBarItem(
                        selected = tab == spec.tab,
                        onClick = { vm.selectTab(spec.tab) },
                        icon = { Icon(if (tab == spec.tab) spec.selected else spec.unselected, contentDescription = null) },
                        label = { Text(spec.label) },
                    )
                }
            }
        },
    ) { padding ->
        val n = node
        val s = settings
        Box(Modifier.fillMaxSize().padding(padding)) {
            if (n == null || s == null) {
                CircularProgressIndicator(Modifier.align(Alignment.Center))
            } else {
                when (tab) {
                    Tab.RECEIVE -> ReceiveScreen(vm, n, s)
                    Tab.SEND -> SendScreen(vm, n)
                    Tab.TRANSFERS -> TransfersScreen(vm, n)
                    Tab.SETTINGS -> SettingsScreen(vm, n, s)
                }
                IncomingDialogs(vm, n)
            }
        }
    }
}
