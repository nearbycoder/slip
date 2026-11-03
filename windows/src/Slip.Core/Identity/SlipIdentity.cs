using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;

namespace Slip.Core.Identity;

/// <summary>
/// Persistent device identity: a self-signed certificate (RSA-2048, CN=Slip, 10+ years) stored as a
/// PFX under the app data directory, plus a random fingerprint used in HTTP mode.
/// </summary>
public sealed class SlipIdentity : IDisposable
{
    private const string PfxFileName = "identity.pfx";
    private const string StateFileName = "identity.json";

    // The PFX lives in the user's private app data folder; the password only satisfies
    // platform PKCS#12 importers that dislike empty passwords.
    private const string PfxPassword = "slip";

    public X509Certificate2 Certificate { get; }

    /// <summary>Lowercase hex SHA-256 of the certificate DER (HTTPS mode fingerprint).</summary>
    public string CertificateFingerprint { get; }

    /// <summary>Persisted random 32-char hex string (HTTP mode fingerprint).</summary>
    public string HttpFingerprint { get; }

    private SlipIdentity(X509Certificate2 certificate, string httpFingerprint)
    {
        Certificate = certificate;
        CertificateFingerprint = ComputeFingerprint(certificate);
        HttpFingerprint = httpFingerprint;
    }

    public string FingerprintFor(bool https) => https ? CertificateFingerprint : HttpFingerprint;

    /// <summary>True when <paramref name="fingerprint"/> is one of ours (either mode).</summary>
    public bool IsOwnFingerprint(string? fingerprint) =>
        !string.IsNullOrEmpty(fingerprint) &&
        (string.Equals(fingerprint, CertificateFingerprint, StringComparison.OrdinalIgnoreCase) ||
         string.Equals(fingerprint, HttpFingerprint, StringComparison.OrdinalIgnoreCase));

    public static string ComputeFingerprint(X509Certificate2 certificate) =>
        Convert.ToHexStringLower(SHA256.HashData(certificate.RawData));

    /// <summary>Loads the identity from <paramref name="directory"/>, creating and persisting it on first use.</summary>
    public static SlipIdentity LoadOrCreate(string directory)
    {
        Directory.CreateDirectory(directory);
        var pfxPath = Path.Combine(directory, PfxFileName);
        var statePath = Path.Combine(directory, StateFileName);

        X509Certificate2? cert = null;
        if (File.Exists(pfxPath))
        {
            try
            {
                cert = LoadPfx(File.ReadAllBytes(pfxPath));
                if (!cert.HasPrivateKey) { cert.Dispose(); cert = null; }
            }
            catch (CryptographicException)
            {
                cert = null; // corrupt: regenerate below
            }
        }

        if (cert is null)
        {
            var pfx = CreateSelfSignedPfx();
            WriteAtomically(pfxPath, pfx);
            cert = LoadPfx(pfx);
        }

        string? httpFingerprint = null;
        if (File.Exists(statePath))
        {
            try
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(statePath));
                if (doc.RootElement.TryGetProperty("httpFingerprint", out var fp) && fp.ValueKind == JsonValueKind.String)
                    httpFingerprint = fp.GetString();
            }
            catch (JsonException) { }
        }
        if (string.IsNullOrWhiteSpace(httpFingerprint) || httpFingerprint.Length != 32)
        {
            httpFingerprint = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));
            WriteAtomically(statePath, JsonSerializer.SerializeToUtf8Bytes(new { httpFingerprint }));
        }

        return new SlipIdentity(cert, httpFingerprint);
    }

    /// <summary>Creates a throw-away identity that is never persisted (tests, ephemeral CLI runs).</summary>
    public static SlipIdentity CreateEphemeral() =>
        new(LoadPfx(CreateSelfSignedPfx()), Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16)));

    internal static byte[] CreateSelfSignedPfx()
    {
        using var rsa = RSA.Create(2048);
        var request = new CertificateRequest("CN=Slip", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(
            X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(
            [new Oid("1.3.6.1.5.5.7.3.1"), new Oid("1.3.6.1.5.5.7.3.2")], false)); // server + client auth
        request.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(request.PublicKey, false));

        var notBefore = DateTimeOffset.UtcNow.AddDays(-1);
        using var cert = request.CreateSelfSigned(notBefore, notBefore.AddYears(20));
        return cert.Export(X509ContentType.Pkcs12, PfxPassword);
    }

    private static X509Certificate2 LoadPfx(byte[] pfx)
    {
        // Round-tripping through PKCS#12 gives a key that SChannel (Windows) can use for TLS;
        // keys created in-memory by CreateSelfSigned are ephemeral and rejected by SslStream there.
        var flags = OperatingSystem.IsWindows()
            ? X509KeyStorageFlags.UserKeySet | X509KeyStorageFlags.Exportable
            : X509KeyStorageFlags.Exportable;
        return X509CertificateLoader.LoadPkcs12(pfx, PfxPassword, flags);
    }

    private static void WriteAtomically(string path, byte[] data)
    {
        var tmp = path + ".tmp";
        File.WriteAllBytes(tmp, data);
        File.Move(tmp, path, overwrite: true);
    }

    public void Dispose() => Certificate.Dispose();
}
