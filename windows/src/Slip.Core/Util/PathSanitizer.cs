using System.Text;

namespace Slip.Core.Util;

/// <summary>
/// Turns an untrusted <c>fileName</c> from a peer (which may contain <c>/</c> for folder sends)
/// into a safe relative path. Rules (shared by all Slip clients):
/// strip leading <c>/</c>, drop empty, <c>.</c> and <c>..</c> segments, replace <c>\</c> and
/// characters illegal on Windows/other file systems, and avoid Windows reserved device names.
/// </summary>
public static class PathSanitizer
{
    private static readonly HashSet<char> IllegalChars = ['\\', '<', '>', ':', '"', '|', '?', '*'];

    private static readonly HashSet<string> ReservedNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$",
        "COM0", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT0", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    private const int MaxSegmentLength = 200;

    /// <summary>Returns the sanitised path segments (never empty).</summary>
    public static IReadOnlyList<string> SanitizeSegments(string? fileName)
    {
        var segments = new List<string>();
        foreach (var raw in (fileName ?? "").Split('/'))
        {
            if (raw.Length == 0 || raw == "." || raw == "..") continue;
            var clean = SanitizeSegment(raw);
            if (clean.Length > 0) segments.Add(clean);
        }
        if (segments.Count == 0) segments.Add("file");
        return segments;
    }

    /// <summary>Relative path using '/' separators, e.g. <c>Photos/2024/a.jpg</c>.</summary>
    public static string Sanitize(string? fileName) => string.Join('/', SanitizeSegments(fileName));

    /// <summary>
    /// Resolves the sanitised name under <paramref name="baseDirectory"/>. The result is guaranteed to stay
    /// inside the base directory.
    /// </summary>
    public static string ResolveUnder(string baseDirectory, string? fileName)
    {
        var root = Path.GetFullPath(baseDirectory);
        var full = Path.GetFullPath(Path.Combine([root, .. SanitizeSegments(fileName)]));
        var rootWithSep = root.EndsWith(Path.DirectorySeparatorChar) ? root : root + Path.DirectorySeparatorChar;
        if (!full.StartsWith(rootWithSep, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
            throw new InvalidOperationException("Path escapes the save directory");
        return full;
    }

    private static string SanitizeSegment(string segment)
    {
        var sb = new StringBuilder(segment.Length);
        foreach (var c in segment)
            sb.Append(c < 0x20 || c == 0x7f || IllegalChars.Contains(c) ? '_' : c);

        // Windows silently strips trailing dots and spaces; leading/trailing whitespace is never useful.
        var s = sb.ToString().Trim().TrimEnd('.', ' ');
        if (s.Length == 0 || s == "." || s == "..") return "";

        var dot = s.IndexOf('.');
        var stem = dot < 0 ? s : s[..dot];
        if (ReservedNames.Contains(stem.TrimEnd(' '))) s = "_" + s;

        if (s.Length > MaxSegmentLength)
        {
            var ext = Path.GetExtension(s);
            if (ext.Length is 0 or > 16) ext = "";
            s = s[..(MaxSegmentLength - ext.Length)] + ext;
        }
        return s;
    }

    /// <summary>
    /// Returns <paramref name="path"/> if nothing exists there, otherwise <c>name (1).ext</c>, <c>name (2).ext</c>, …
    /// </summary>
    public static string MakeUnique(string path)
    {
        if (!File.Exists(path) && !Directory.Exists(path)) return path;
        var dir = Path.GetDirectoryName(path) ?? "";
        var (stem, ext) = SplitExtension(Path.GetFileName(path));
        for (var i = 1; ; i++)
        {
            var candidate = Path.Combine(dir, $"{stem} ({i}){ext}");
            if (!File.Exists(candidate) && !Directory.Exists(candidate)) return candidate;
        }
    }

    /// <summary>Splits "a.tar.gz" into ("a.tar", ".gz"); dot-files like ".bashrc" have no extension.</summary>
    public static (string Stem, string Extension) SplitExtension(string fileName)
    {
        var dot = fileName.LastIndexOf('.');
        if (dot <= 0 || dot == fileName.Length - 1) return (fileName, "");
        return (fileName[..dot], fileName[dot..]);
    }
}
