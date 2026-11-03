using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Dispatching;
using Slip.Core;

namespace Slip.App.ViewModels;

/// <summary>Settings page. Every change is applied (debounced) and persisted to
/// %LOCALAPPDATA%\Slip\settings.json.</summary>
public sealed partial class SettingsViewModel : ObservableObject
{
    private readonly AppState _state;
    private readonly DispatcherQueueTimer _debounce;
    private readonly SlipSettings _draft;

    public SettingsViewModel(AppState state, DispatcherQueue dispatcher)
    {
        _state = state;
        _draft = state.Settings;
        _debounce = dispatcher.CreateTimer();
        _debounce.Interval = TimeSpan.FromMilliseconds(600);
        _debounce.IsRepeating = false;
        _debounce.Tick += async (_, _) => await _state.ApplySettingsAsync(_draft);
    }

    private void Changed(string? name = null)
    {
        if (name is not null) OnPropertyChanged(name);
        _debounce.Stop();
        _debounce.Start();
    }

    public string Alias
    {
        get => _draft.Alias;
        set
        {
            var v = value.Trim();
            if (v.Length == 0 || v == _draft.Alias) return;
            _draft.Alias = v;
            Changed();
        }
    }

    /// <summary>NumberBox works with doubles.</summary>
    public double Port
    {
        get => _draft.Port;
        set
        {
            if (double.IsNaN(value)) return;
            var port = (int)Math.Clamp(Math.Round(value), 1, 65535);
            if (port == _draft.Port) return;
            _draft.Port = port;
            Changed(nameof(Port));
        }
    }

    public bool UseHttps
    {
        get => _draft.UseHttps;
        set { if (value != _draft.UseHttps) { _draft.UseHttps = value; Changed(nameof(UseHttps)); OnPropertyChanged(nameof(Fingerprint)); } }
    }

    public string SaveDirectory
    {
        get => _draft.SaveDirectory;
        set { if (!string.IsNullOrWhiteSpace(value) && value != _draft.SaveDirectory) { _draft.SaveDirectory = value; Changed(nameof(SaveDirectory)); } }
    }

    public bool AutoAccept
    {
        get => _draft.AutoAccept;
        set { if (value != _draft.AutoAccept) { _draft.AutoAccept = value; Changed(nameof(AutoAccept)); } }
    }

    public bool RequirePin
    {
        get => _draft.RequirePin;
        set { if (value != _draft.RequirePin) { _draft.RequirePin = value; Changed(nameof(RequirePin)); } }
    }

    public string Pin
    {
        get => _draft.Pin;
        set { if (value != _draft.Pin) { _draft.Pin = value ?? ""; Changed(); } }
    }

    public bool Discoverable
    {
        get => _draft.Discoverable;
        set { if (value != _draft.Discoverable) { _draft.Discoverable = value; Changed(nameof(Discoverable)); } }
    }

    /// <summary>0 = system, 1 = light, 2 = dark (ComboBox index).</summary>
    public int ThemeIndex
    {
        get => (int)_draft.Theme;
        set
        {
            if (value < 0 || value == (int)_draft.Theme) return;
            _draft.Theme = (AppTheme)value;
            App.MainWindow?.ApplyTheme(_draft.Theme);
            Changed(nameof(ThemeIndex));
        }
    }

    public string Fingerprint => _state.Identity.FingerprintFor(_draft.UseHttps);

    public string Version =>
        typeof(SettingsViewModel).Assembly.GetName().Version?.ToString(3) ?? "0.1.0";

    public string DataDirectory => AppPaths.DataDirectory;

    /// <summary>Re-reads values changed elsewhere (e.g. the Quick Save toggle on the Receive page).</summary>
    public void Reload()
    {
        var current = _state.Settings;
        _draft.Discoverable = current.Discoverable;
        _draft.AutoAccept = current.AutoAccept;
        OnPropertyChanged(nameof(Discoverable));
        OnPropertyChanged(nameof(AutoAccept));
    }
}
