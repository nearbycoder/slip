package app.slip.core

import app.slip.core.identity.Aliases
import app.slip.core.identity.FileIdentityStore
import app.slip.core.identity.Identity
import app.slip.core.model.SlipJson
import app.slip.core.util.sha256Hex
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import kotlin.random.Random

class IdentityTest {
    @Test
    fun aliasFormat() {
        repeat(50) {
            val alias = Aliases.generate(Random(it))
            val (adj, fruit) = alias.split(" ")
            assertTrue(adj in Aliases.adjectives)
            assertTrue(fruit in Aliases.fruits)
        }
    }

    @Test
    fun aliasListsMatchProtocolFile() {
        val dir = System.getProperty("slip.protocolDir") ?: return
        val file = File(dir, "aliases.json")
        if (!file.isFile) return
        val obj = SlipJson.parseToJsonElement(file.readText()).jsonObject
        assertEquals(obj["adjectives"]!!.jsonArray.map { it.jsonPrimitive.content }, Aliases.adjectives)
        assertEquals(obj["fruits"]!!.jsonArray.map { it.jsonPrimitive.content }, Aliases.fruits)
    }

    @Test
    fun fingerprintIsSha256OfCertDer() {
        val id = Identity.generate()
        val expected = MessageDigest.getInstance("SHA-256").digest(id.certificate.encoded)
            .joinToString("") { "%02x".format(it) }
        assertEquals(expected, id.certFingerprint)
        assertEquals(expected, sha256Hex(id.certificate.encoded))
        assertTrue(Regex("[0-9a-f]{64}").matches(id.certFingerprint))
        assertTrue(Regex("[0-9a-f]{32}").matches(id.httpFingerprint))
        assertEquals(id.certFingerprint, id.fingerprint(https = true))
        assertEquals(id.httpFingerprint, id.fingerprint(https = false))
        assertTrue(id.certificate.subjectX500Principal.name.contains("CN=Slip"))
        val years = (id.certificate.notAfter.time - id.certificate.notBefore.time) / (365.25 * 24 * 3600 * 1000)
        assertTrue("validity $years", years >= 10)
        id.serverSslContext() // builds
    }

    @Test
    fun persistsAcrossLoads() {
        val dir = Files.createTempDirectory("slip-id").toFile()
        val a = FileIdentityStore(dir).loadOrCreate()
        val b = FileIdentityStore(dir).loadOrCreate()
        assertEquals(a.certFingerprint, b.certFingerprint)
        assertEquals(a.httpFingerprint, b.httpFingerprint)
        val other = FileIdentityStore(Files.createTempDirectory("slip-id2").toFile()).loadOrCreate()
        assertNotEquals(a.certFingerprint, other.certFingerprint)
        dir.deleteRecursively()
    }
}
