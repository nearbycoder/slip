namespace Slip.Core.Util;

public static class MimeTypes
{
    private static readonly Dictionary<string, string> Map = new(StringComparer.OrdinalIgnoreCase)
    {
        [".txt"] = "text/plain", [".md"] = "text/markdown", [".csv"] = "text/csv", [".html"] = "text/html",
        [".htm"] = "text/html", [".css"] = "text/css", [".js"] = "text/javascript", [".json"] = "application/json",
        [".xml"] = "application/xml", [".pdf"] = "application/pdf", [".zip"] = "application/zip",
        [".7z"] = "application/x-7z-compressed", [".rar"] = "application/vnd.rar", [".gz"] = "application/gzip",
        [".tar"] = "application/x-tar", [".apk"] = "application/vnd.android.package-archive",
        [".exe"] = "application/vnd.microsoft.portable-executable", [".msi"] = "application/x-msi",
        [".doc"] = "application/msword", [".docx"] = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        [".xls"] = "application/vnd.ms-excel", [".xlsx"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        [".ppt"] = "application/vnd.ms-powerpoint", [".pptx"] = "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        [".png"] = "image/png", [".jpg"] = "image/jpeg", [".jpeg"] = "image/jpeg", [".gif"] = "image/gif",
        [".webp"] = "image/webp", [".bmp"] = "image/bmp", [".svg"] = "image/svg+xml", [".heic"] = "image/heic",
        [".heif"] = "image/heif", [".ico"] = "image/x-icon", [".tif"] = "image/tiff", [".tiff"] = "image/tiff",
        [".mp3"] = "audio/mpeg", [".wav"] = "audio/wav", [".flac"] = "audio/flac", [".m4a"] = "audio/mp4",
        [".ogg"] = "audio/ogg", [".aac"] = "audio/aac", [".mp4"] = "video/mp4", [".mov"] = "video/quicktime",
        [".mkv"] = "video/x-matroska", [".webm"] = "video/webm", [".avi"] = "video/x-msvideo",
    };

    public static string FromFileName(string fileName) =>
        Map.TryGetValue(Path.GetExtension(fileName), out var type) ? type : "application/octet-stream";
}
