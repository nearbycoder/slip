package app.slip.android.data

import android.content.Context
import android.os.Build
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import app.slip.core.NodeSettings
import app.slip.core.SlipConstants
import app.slip.core.identity.Aliases
import app.slip.core.model.DeviceType
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

enum class ThemeMode { SYSTEM, LIGHT, DARK }

data class AppSettings(
    val alias: String,
    val deviceModel: String = defaultModel(),
    val port: Int = SlipConstants.DEFAULT_PORT,
    val https: Boolean = true,
    val quickSave: Boolean = false,
    val pinEnabled: Boolean = false,
    val pin: String = "",
    val discoverable: Boolean = true,
    val theme: ThemeMode = ThemeMode.SYSTEM,
    val dynamicColor: Boolean = true,
) {
    fun toNodeSettings() = NodeSettings(
        alias = alias,
        deviceModel = deviceModel,
        deviceType = DeviceType.MOBILE,
        port = port,
        https = https,
        autoAccept = quickSave,
        pin = pin.takeIf { pinEnabled && it.isNotEmpty() },
        discoverable = discoverable,
    )

    companion object {
        fun defaultModel(): String {
            val model = Build.MODEL.orEmpty()
            val maker = Build.MANUFACTURER.orEmpty().replaceFirstChar { it.uppercase() }
            return when {
                model.isEmpty() -> "Android"
                model.startsWith(maker, ignoreCase = true) || maker.isEmpty() -> model
                else -> "$maker $model"
            }
        }
    }
}

private val Context.dataStore by preferencesDataStore(name = "settings")

class SettingsRepository(private val context: Context) {
    private object Keys {
        val alias = stringPreferencesKey("alias")
        val model = stringPreferencesKey("device_model")
        val port = intPreferencesKey("port")
        val https = booleanPreferencesKey("https")
        val quickSave = booleanPreferencesKey("quick_save")
        val pinEnabled = booleanPreferencesKey("pin_enabled")
        val pin = stringPreferencesKey("pin")
        val discoverable = booleanPreferencesKey("discoverable")
        val theme = stringPreferencesKey("theme")
        val dynamicColor = booleanPreferencesKey("dynamic_color")
    }

    val settings: Flow<AppSettings> = context.dataStore.data.map(::read)

    private fun read(p: Preferences) = AppSettings(
        alias = p[Keys.alias] ?: "",
        deviceModel = p[Keys.model] ?: AppSettings.defaultModel(),
        port = p[Keys.port] ?: SlipConstants.DEFAULT_PORT,
        https = p[Keys.https] ?: true,
        quickSave = p[Keys.quickSave] ?: false,
        pinEnabled = p[Keys.pinEnabled] ?: false,
        pin = p[Keys.pin] ?: "",
        discoverable = p[Keys.discoverable] ?: true,
        theme = runCatching { ThemeMode.valueOf(p[Keys.theme] ?: "SYSTEM") }.getOrDefault(ThemeMode.SYSTEM),
        dynamicColor = p[Keys.dynamicColor] ?: true,
    )

    /** Loads settings, generating and persisting an alias on first launch. */
    suspend fun load(): AppSettings {
        val current = settings.first()
        if (current.alias.isNotBlank()) return current
        val alias = Aliases.generate()
        context.dataStore.edit { it[Keys.alias] = alias }
        return current.copy(alias = alias)
    }

    suspend fun update(change: (AppSettings) -> AppSettings) {
        context.dataStore.edit { p ->
            val n = change(read(p))
            p[Keys.alias] = n.alias.trim().ifEmpty { Aliases.generate() }
            p[Keys.model] = n.deviceModel
            p[Keys.port] = n.port.coerceIn(1024, 65535)
            p[Keys.https] = n.https
            p[Keys.quickSave] = n.quickSave
            p[Keys.pinEnabled] = n.pinEnabled
            p[Keys.pin] = n.pin
            p[Keys.discoverable] = n.discoverable
            p[Keys.theme] = n.theme.name
            p[Keys.dynamicColor] = n.dynamicColor
        }
    }
}
