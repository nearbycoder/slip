using System.Globalization;
using Microsoft.UI.Xaml;
using Slip.Core.Protocol;

namespace Slip.App.Helpers;

/// <summary>Formatting helpers, also usable from x:Bind function bindings.</summary>
public static class Format
{
    public static string Bytes(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        double value = bytes;
        var unit = 0;
        while (value >= 1024 && unit < units.Length - 1)
        {
            value /= 1024;
            unit++;
        }
        return unit == 0
            ? string.Format(CultureInfo.CurrentCulture, "{0} B", bytes)
            : string.Format(CultureInfo.CurrentCulture, "{0:0.#} {1}", value, units[unit]);
    }

    public static string Speed(double bytesPerSecond) => bytesPerSecond <= 0 ? "" : Bytes((long)bytesPerSecond) + "/s";

    public static Visibility VisibleIf(bool value) => value ? Visibility.Visible : Visibility.Collapsed;

    public static Visibility CollapsedIf(bool value) => value ? Visibility.Collapsed : Visibility.Visible;

    /// <summary>Segoe Fluent Icons glyph for a LocalSend device type.</summary>
    public static string DeviceGlyph(DeviceType? type) => type switch
    {
        DeviceType.Mobile => "",   // CellPhone
        DeviceType.Web => "",      // Globe
        DeviceType.Headless => "", // CommandPrompt
        DeviceType.Server => "",   // Network
        _ => "",                   // TVMonitor (desktop)
    };
}
