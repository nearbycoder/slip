package app.slip.core.identity

import app.slip.core.util.randomHex
import app.slip.core.util.sha256Hex
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.asn1.x509.BasicConstraints
import org.bouncycastle.asn1.x509.Extension
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.io.ByteArrayInputStream
import java.io.File
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Date
import java.util.concurrent.TimeUnit
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext

/**
 * The device's long-lived TLS identity: an RSA-2048 key and a self-signed certificate (CN=Slip, 20 years), plus the
 * random fingerprint used when HTTPS is off.
 */
class Identity(
    val privateKey: PrivateKey,
    val certificate: X509Certificate,
    /** Persisted random 32-hex fingerprint advertised in HTTP mode. */
    val httpFingerprint: String,
) {
    /** Lowercase hex SHA-256 of the certificate DER, advertised in HTTPS mode. */
    val certFingerprint: String = sha256Hex(certificate.encoded)

    fun fingerprint(https: Boolean): String = if (https) certFingerprint else httpFingerprint

    /** A server-side TLS context presenting this certificate. */
    fun serverSslContext(): SSLContext {
        val password = CharArray(0)
        val keyStore = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            setKeyEntry("slip", privateKey, password, arrayOf(certificate))
        }
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(keyStore, password) }
        return SSLContext.getInstance("TLS").apply { init(kmf.keyManagers, null, null) }
    }

    companion object {
        fun generate(): Identity {
            val keyPair = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
            val now = System.currentTimeMillis()
            val notBefore = Date(now - TimeUnit.DAYS.toMillis(1))
            val notAfter = Date(now + TimeUnit.DAYS.toMillis(365L * 20))
            val name = X500Name("CN=Slip, O=Slip")
            val serial = BigInteger(64, java.security.SecureRandom()).abs().add(BigInteger.ONE)
            val builder = JcaX509v3CertificateBuilder(name, serial, notBefore, notAfter, name, keyPair.public)
                .addExtension(Extension.basicConstraints, false, BasicConstraints(false))
            val signer = JcaContentSignerBuilder("SHA256withRSA").build(keyPair.private)
            val cert = JcaX509CertificateConverter().getCertificate(builder.build(signer))
            return Identity(keyPair.private, cert, randomHex(32))
        }

        fun decode(keyDer: ByteArray, certDer: ByteArray, httpFingerprint: String): Identity {
            val key = KeyFactory.getInstance("RSA").generatePrivate(PKCS8EncodedKeySpec(keyDer))
            val cert = CertificateFactory.getInstance("X.509")
                .generateCertificate(ByteArrayInputStream(certDer)) as X509Certificate
            return Identity(key, cert, httpFingerprint)
        }
    }
}

/** Persists the identity as DER files in [dir], generating it on first use. */
class FileIdentityStore(private val dir: File) {
    private val keyFile get() = File(dir, "identity.key")
    private val certFile get() = File(dir, "identity.crt")
    private val fpFile get() = File(dir, "identity.http-fingerprint")

    @Synchronized
    fun loadOrCreate(): Identity {
        if (keyFile.isFile && certFile.isFile && fpFile.isFile) {
            runCatching {
                return Identity.decode(keyFile.readBytes(), certFile.readBytes(), fpFile.readText().trim())
            }
        }
        val identity = Identity.generate()
        dir.mkdirs()
        writeAtomically(keyFile, identity.privateKey.encoded)
        writeAtomically(certFile, identity.certificate.encoded)
        writeAtomically(fpFile, identity.httpFingerprint.toByteArray())
        return identity
    }

    private fun writeAtomically(target: File, bytes: ByteArray) {
        val tmp = File(target.parentFile, target.name + ".tmp")
        tmp.writeBytes(bytes)
        if (!tmp.renameTo(target)) {
            target.delete()
            tmp.renameTo(target)
        }
    }
}
