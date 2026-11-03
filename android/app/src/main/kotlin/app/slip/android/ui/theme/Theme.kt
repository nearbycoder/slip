package app.slip.android.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import app.slip.android.data.ThemeMode

val SlipGreen = Color(0xFF16A34A)

// Material 3 tonal palette seeded from Slip green (#16a34a).
private val LightColors = lightColorScheme(
    primary = Color(0xFF146C2E),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFF9AF6A7),
    onPrimaryContainer = Color(0xFF002109),
    secondary = Color(0xFF516350),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFD3E8D0),
    onSecondaryContainer = Color(0xFF0F1F10),
    tertiary = Color(0xFF39656B),
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFBCEBF1),
    onTertiaryContainer = Color(0xFF001F23),
    background = Color(0xFFFCFDF7),
    onBackground = Color(0xFF1A1C19),
    surface = Color(0xFFFCFDF7),
    onSurface = Color(0xFF1A1C19),
    surfaceVariant = Color(0xFFDEE5D9),
    onSurfaceVariant = Color(0xFF424940),
    outline = Color(0xFF72796F),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFF6F8F1),
    surfaceContainer = Color(0xFFF0F2EB),
    surfaceContainerHigh = Color(0xFFEAECE5),
    surfaceContainerHighest = Color(0xFFE4E6E0),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFF7EDA8D),
    onPrimary = Color(0xFF003914),
    primaryContainer = Color(0xFF005321),
    onPrimaryContainer = Color(0xFF9AF6A7),
    secondary = Color(0xFFB7CCB5),
    onSecondary = Color(0xFF233424),
    secondaryContainer = Color(0xFF394B39),
    onSecondaryContainer = Color(0xFFD3E8D0),
    tertiary = Color(0xFFA1CED5),
    onTertiary = Color(0xFF00363C),
    tertiaryContainer = Color(0xFF1F4D53),
    onTertiaryContainer = Color(0xFFBCEBF1),
    background = Color(0xFF111411),
    onBackground = Color(0xFFE2E3DD),
    surface = Color(0xFF111411),
    onSurface = Color(0xFFE2E3DD),
    surfaceVariant = Color(0xFF424940),
    onSurfaceVariant = Color(0xFFC2C9BE),
    outline = Color(0xFF8C9389),
    surfaceContainerLowest = Color(0xFF0C0F0C),
    surfaceContainerLow = Color(0xFF1A1C19),
    surfaceContainer = Color(0xFF1E201D),
    surfaceContainerHigh = Color(0xFF282B27),
    surfaceContainerHighest = Color(0xFF333532),
)

@Composable
fun SlipTheme(mode: ThemeMode = ThemeMode.SYSTEM, dynamicColor: Boolean = true, content: @Composable () -> Unit) {
    val dark = when (mode) {
        ThemeMode.SYSTEM -> isSystemInDarkTheme()
        ThemeMode.LIGHT -> false
        ThemeMode.DARK -> true
    }
    val context = LocalContext.current
    val colors = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
            if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> DarkColors
        else -> LightColors
    }
    MaterialTheme(colorScheme = colors, content = content)
}
