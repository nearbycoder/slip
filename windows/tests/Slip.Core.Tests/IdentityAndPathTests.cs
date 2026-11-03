using System.Security.Cryptography;
using System.Text.Json;
using Slip.Core.Identity;
using Slip.Core.Util;

namespace Slip.Core.Tests;

public class AliasTests
{
    [Fact]
    public void Alias_UsesSharedWordLists()
    {
        var repoAliases = Path.Combine(TestPaths.RepoRoot, "protocol", "aliases.json");
        using var doc = JsonDocument.Parse(File.ReadAllText(repoAliases));
        var adjectives = doc.RootElement.GetProperty("adjectives").EnumerateArray().Select(e => e.GetString()).ToHashSet();
        var fruits = doc.RootElement.GetProperty("fruits").EnumerateArray().Select(e => e.GetString()).ToHashSet();
        Assert.Equal(adjectives.Count, AliasGenerator.Adjectives.Count);
        Assert.Equal(fruits.Count, AliasGenerator.Fruits.Count);

        for (var i = 0; i < 200; i++)
        {
            var alias = AliasGenerator.Generate();
            var parts = alias.Split(' ');
            Assert.Equal(2, parts.Length);
            Assert.Contains(parts[0], adjectives);
            Assert.Contains(parts[1], fruits);
        }
    }
}

public class IdentityTests
{
    [Fact]
    public void Identity_PersistsAndFingerprintIsSha256OfDer()
    {
        var dir = Path.Combine(Path.GetTempPath(), "slip-id-" + Guid.NewGuid().ToString("N"));
        try
        {
            string fp, httpFp;
            using (var id = SlipIdentity.LoadOrCreate(dir))
            {
                fp = id.CertificateFingerprint;
                httpFp = id.HttpFingerprint;
                Assert.Matches("^[0-9a-f]{64}$", fp);
                Assert.Equal(Convert.ToHexStringLower(SHA256.HashData(id.Certificate.RawData)), fp);
                Assert.Matches("^[0-9a-f]{32}$", httpFp);
                Assert.True(id.Certificate.HasPrivateKey);
                Assert.Equal("CN=Slip", id.Certificate.Subject);
                Assert.True(id.Certificate.NotAfter - id.Certificate.NotBefore >= TimeSpan.FromDays(3650));
                Assert.True(id.IsOwnFingerprint(fp.ToUpperInvariant()));
                Assert.True(id.IsOwnFingerprint(httpFp));
                Assert.False(id.IsOwnFingerprint("other"));
                Assert.Equal(fp, id.FingerprintFor(https: true));
                Assert.Equal(httpFp, id.FingerprintFor(https: false));
            }
            Assert.True(File.Exists(Path.Combine(dir, "identity.pfx")));
            using var again = SlipIdentity.LoadOrCreate(dir);
            Assert.Equal(fp, again.CertificateFingerprint);
            Assert.Equal(httpFp, again.HttpFingerprint);
        }
        finally
        {
            Directory.Delete(dir, true);
        }
    }
}

public class PathSanitizerTests
{
    [Theory]
    [InlineData("a.png", "a.png")]
    [InlineData("/etc/passwd", "etc/passwd")]
    [InlineData("../../evil.txt", "evil.txt")]
    [InlineData("Photos/2024/./a.jpg", "Photos/2024/a.jpg")]
    [InlineData("Photos//2024/../a.jpg", "Photos/2024/a.jpg")]
    [InlineData("dir\\..\\x.txt", "dir_.._x.txt")]
    [InlineData("a<b>c:d\"e|f?g*h.txt", "a_b_c_d_e_f_g_h.txt")]
    [InlineData("tab\there.txt", "tab_here.txt")]
    [InlineData("CON", "_CON")]
    [InlineData("nul.txt", "_nul.txt")]
    [InlineData("com1.tar.gz", "_com1.tar.gz")]
    [InlineData("console.txt", "console.txt")]
    [InlineData("trailing. ", "trailing")]
    [InlineData("folder./file", "folder/file")]
    [InlineData("", "file")]
    [InlineData("../..", "file")]
    [InlineData("...", "file")]
    public void Sanitize(string input, string expected) => Assert.Equal(expected, PathSanitizer.Sanitize(input));

    [Fact]
    public void Sanitize_TruncatesLongNamesKeepingExtension()
    {
        var name = new string('x', 400) + ".jpg";
        var clean = PathSanitizer.Sanitize(name);
        Assert.True(clean.Length <= 200);
        Assert.EndsWith(".jpg", clean);
    }

    [Fact]
    public void ResolveUnder_StaysInsideBase()
    {
        var root = Path.Combine(Path.GetTempPath(), "slip-root");
        var resolved = PathSanitizer.ResolveUnder(root, "../../../../etc/passwd");
        Assert.StartsWith(Path.GetFullPath(root) + Path.DirectorySeparatorChar, resolved);
        Assert.EndsWith(Path.Combine("etc", "passwd"), resolved);
    }

    [Fact]
    public void MakeUnique_AppendsCounterBeforeExtension()
    {
        var dir = Path.Combine(Path.GetTempPath(), "slip-unique-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var path = Path.Combine(dir, "a.txt");
            Assert.Equal(path, PathSanitizer.MakeUnique(path));
            File.WriteAllText(path, "x");
            Assert.Equal(Path.Combine(dir, "a (1).txt"), PathSanitizer.MakeUnique(path));
            File.WriteAllText(Path.Combine(dir, "a (1).txt"), "x");
            Assert.Equal(Path.Combine(dir, "a (2).txt"), PathSanitizer.MakeUnique(path));

            var dot = Path.Combine(dir, ".bashrc");
            File.WriteAllText(dot, "x");
            Assert.Equal(Path.Combine(dir, ".bashrc (1)"), PathSanitizer.MakeUnique(dot));
        }
        finally
        {
            Directory.Delete(dir, true);
        }
    }

    [Fact]
    public void ScanTargets_CoversSlash24WithoutSelf()
    {
        var iface = new LocalInterface("en0", 1, System.Net.IPAddress.Parse("192.168.1.42"), 24, true);
        var targets = NetUtil.ScanTargets([iface]).Select(a => a.ToString()).ToList();
        Assert.Equal(253, targets.Count);
        Assert.DoesNotContain("192.168.1.42", targets);
        Assert.DoesNotContain("192.168.1.0", targets);
        Assert.DoesNotContain("192.168.1.255", targets);
        Assert.Contains("192.168.1.1", targets);

        // A /16 is clamped to the local /24.
        var wide = new LocalInterface("en1", 2, System.Net.IPAddress.Parse("10.0.5.9"), 16, true);
        Assert.Equal(253, NetUtil.ScanTargets([wide]).Count());
    }
}

internal static class TestPaths
{
    public static string RepoRoot
    {
        get
        {
            var dir = new DirectoryInfo(AppContext.BaseDirectory);
            while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "protocol", "aliases.json"))) dir = dir.Parent;
            return dir?.FullName ?? throw new InvalidOperationException("repo root not found");
        }
    }
}
