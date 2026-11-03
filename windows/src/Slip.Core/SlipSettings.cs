using System.Text.Json;
using System.Text.Json.Serialization;
using Slip.Core.Identity;

namespace Slip.Core;

public enum AppTheme
{
    System,
    Light,
    Dark,
}

/// <summary>User settings shared by all front-ends. Persisted as JSON.</summary>
public sealed class SlipSettings
{
    public string Alias { get; set; } = AliasGenerator.Generate();
    public int Port { get; set; } = SlipConstants.DefaultPort;
    public bool UseHttps { get; set; } = true;
    public string SaveDirectory { get; set; } = AppPaths.DefaultDownloadsDirectory;
    /// <summary>"Quick Save": accept incoming transfers without asking.</summary>
    public bool AutoAccept { get; set; }
    public bool RequirePin { get; set; }
    public string Pin { get; set; } = "";
    public bool Discoverable { get; set; } = true;
    [JsonConverter(typeof(JsonStringEnumConverter<AppTheme>))]
    public AppTheme Theme { get; set; } = AppTheme.System;
    public string MulticastGroup { get; set; } = SlipConstants.MulticastGroup;
    public int MulticastPort { get; set; } = SlipConstants.MulticastPort;
    /// <summary>Windows: minimise to the notification area instead of the taskbar.</summary>
    public bool MinimizeToTray { get; set; }

    public SlipSettings Clone() => (SlipSettings)MemberwiseClone();

    /// <summary>PIN the server enforces, or null when none is required.</summary>
    [JsonIgnore]
    public string? EffectivePin => RequirePin && !string.IsNullOrEmpty(Pin) ? Pin : null;
}

/// <summary>Loads and saves <see cref="SlipSettings"/> as JSON.</summary>
public sealed class SettingsStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        AllowTrailingCommas = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
    };

    public string FilePath { get; }

    public SettingsStore(string filePath) => FilePath = filePath;

    public SlipSettings Load()
    {
        SlipSettings? settings = null;
        try
        {
            if (File.Exists(FilePath))
                settings = JsonSerializer.Deserialize<SlipSettings>(File.ReadAllText(FilePath), Options);
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
        {
            settings = null;
        }

        var fresh = settings is null;
        settings ??= new SlipSettings();
        if (string.IsNullOrWhiteSpace(settings.Alias)) settings.Alias = AliasGenerator.Generate();
        if (settings.Port is <= 0 or > 65535) settings.Port = SlipConstants.DefaultPort;
        if (string.IsNullOrWhiteSpace(settings.SaveDirectory)) settings.SaveDirectory = AppPaths.DefaultDownloadsDirectory;
        if (fresh) Save(settings); // persist the generated alias
        return settings;
    }

    public void Save(SlipSettings settings)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        var tmp = FilePath + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(settings, Options));
        File.Move(tmp, FilePath, overwrite: true);
    }
}

public static class AppPaths
{
    /// <summary>%LOCALAPPDATA%\Slip on Windows; the platform equivalent elsewhere.</summary>
    public static string DataDirectory
    {
        get
        {
            var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData,
                Environment.SpecialFolderOption.Create);
            if (string.IsNullOrEmpty(baseDir))
                baseDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "share");
            return Path.Combine(baseDir, "Slip");
        }
    }

    public static string DefaultDownloadsDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
}
