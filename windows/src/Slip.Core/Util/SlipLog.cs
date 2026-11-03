namespace Slip.Core.Util;

public enum LogLevel
{
    Debug,
    Info,
    Warning,
    Error,
}

/// <summary>Tiny logging hook; front-ends subscribe to <see cref="Message"/>.</summary>
public static class SlipLog
{
    public static event Action<LogLevel, string>? Message;

    public static LogLevel MinimumLevel { get; set; } = LogLevel.Info;

    public static void Write(LogLevel level, string message)
    {
        if (level < MinimumLevel) return;
        try { Message?.Invoke(level, message); }
        catch { /* never let logging break networking */ }
    }

    public static void Debug(string message) => Write(LogLevel.Debug, message);
    public static void Info(string message) => Write(LogLevel.Info, message);
    public static void Warn(string message) => Write(LogLevel.Warning, message);
    public static void Error(string message) => Write(LogLevel.Error, message);
}
