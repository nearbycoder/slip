using System.Security.Cryptography;
using System.Text.Json;

namespace Slip.Core.Identity;

/// <summary>Generates "&lt;Adjective&gt; &lt;Fruit&gt;" aliases from protocol/aliases.json (embedded).</summary>
public static class AliasGenerator
{
    private static readonly Lazy<(string[] Adjectives, string[] Fruits)> Words = new(Load);

    public static IReadOnlyList<string> Adjectives => Words.Value.Adjectives;
    public static IReadOnlyList<string> Fruits => Words.Value.Fruits;

    public static string Generate()
    {
        var (adjectives, fruits) = Words.Value;
        return $"{adjectives[RandomNumberGenerator.GetInt32(adjectives.Length)]} {fruits[RandomNumberGenerator.GetInt32(fruits.Length)]}";
    }

    private static (string[], string[]) Load()
    {
        using var stream = typeof(AliasGenerator).Assembly.GetManifestResourceStream("Slip.Core.aliases.json")
                           ?? throw new InvalidOperationException("aliases.json resource missing");
        using var doc = JsonDocument.Parse(stream);
        static string[] Read(JsonElement root, string name) =>
            root.GetProperty(name).EnumerateArray().Select(e => e.GetString()!).Where(s => !string.IsNullOrWhiteSpace(s)).ToArray();
        return (Read(doc.RootElement, "adjectives"), Read(doc.RootElement, "fruits"));
    }
}
