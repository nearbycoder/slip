package app.slip.android.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Computer
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.Smartphone
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.ui.graphics.vector.ImageVector
import app.slip.core.model.DeviceType
import java.util.Locale

fun formatSize(bytes: Long): String = when {
    bytes < 0 -> "?"
    bytes < 1000 -> "$bytes B"
    bytes < 1000L * 1000 -> String.format(Locale.US, "%.1f KB", bytes / 1000.0)
    bytes < 1000L * 1000 * 1000 -> String.format(Locale.US, "%.1f MB", bytes / 1e6)
    else -> String.format(Locale.US, "%.2f GB", bytes / 1e9)
}

fun formatSpeed(bytesPerSecond: Long): String = formatSize(bytesPerSecond) + "/s"

fun deviceIcon(type: DeviceType): ImageVector = when (type) {
    DeviceType.MOBILE -> Icons.Outlined.Smartphone
    DeviceType.DESKTOP -> Icons.Outlined.Computer
    DeviceType.WEB -> Icons.Outlined.Language
    DeviceType.HEADLESS -> Icons.Outlined.Terminal
    DeviceType.SERVER -> Icons.Outlined.Dns
}
