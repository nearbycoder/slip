package app.slip.core

import app.slip.core.model.DeviceInfo
import app.slip.core.model.DeviceType
import app.slip.core.model.FileDto
import app.slip.core.model.MulticastMessage
import app.slip.core.model.PrepareUploadRequest
import app.slip.core.model.PrepareUploadResponse
import app.slip.core.model.Protocol
import app.slip.core.model.SlipJson
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class JsonTest {
    @Test
    fun deviceInfoRoundTrip() {
        val info = DeviceInfo("Nice Orange", "2.1", "Pixel 8", "mobile", "abc", 53317, "https", false)
        val json = SlipJson.encodeToString(DeviceInfo.serializer(), info)
        assertEquals(info, SlipJson.decodeFromString(DeviceInfo.serializer(), json))
        val obj = SlipJson.parseToJsonElement(json).jsonObject
        for (key in listOf("alias", "version", "deviceModel", "deviceType", "fingerprint", "port", "protocol", "download")) {
            assertTrue("missing $key", key in obj)
        }
    }

    @Test
    fun deviceInfoLenient() {
        val json = """{"alias":"X","fingerprint":"f","deviceType":"toaster","port":null,"extra":{"a":[1,2]},"newField":true}"""
        val info = SlipJson.decodeFromString(DeviceInfo.serializer(), json)
        assertEquals("X", info.alias)
        assertNull(info.deviceModel)
        assertEquals(DeviceType.DESKTOP, info.type)
        assertEquals(53317, info.port)
        assertEquals(Protocol.HTTPS, info.proto)
        assertFalse(info.download)
    }

    @Test
    fun registerResponseWithoutPortOrProtocol() {
        val json = """{"alias":"Nice Orange","version":"2.0","deviceModel":"Samsung","deviceType":"mobile","fingerprint":"x","download":true}"""
        val info = SlipJson.decodeFromString(DeviceInfo.serializer(), json)
        assertEquals(53317, info.port)
        assertEquals("https", info.protocol)
        assertTrue(info.download)
        assertEquals(DeviceType.MOBILE, info.type)
    }

    @Test
    fun multicastAnnounceKeys() {
        val info = DeviceInfo("A", fingerprint = "f")
        val json = SlipJson.encodeToString(MulticastMessage.serializer(), MulticastMessage.from(info, true))
        val obj = SlipJson.parseToJsonElement(json).jsonObject
        assertEquals("true", obj["announce"].toString())
        assertEquals("true", obj["announcement"].toString())

        val v1 = SlipJson.decodeFromString(MulticastMessage.serializer(), """{"alias":"Old","fingerprint":"o","announcement":true}""")
        assertTrue(v1.isAnnounce)
        val v2 = SlipJson.decodeFromString(MulticastMessage.serializer(), """{"alias":"New","fingerprint":"n","announce":false}""")
        assertFalse(v2.isAnnounce)
        val none = SlipJson.decodeFromString(MulticastMessage.serializer(), """{"alias":"N","fingerprint":"n"}""")
        assertFalse(none.isAnnounce)
    }

    @Test
    fun prepareUploadRoundTripAndLenient() {
        val json = """
            {"info":{"alias":"S","version":"2.0","deviceModel":null,"deviceType":null,"fingerprint":"x","port":53317,"protocol":"http","download":false},
             "files":{"a":{"id":"a","fileName":"x.png","size":5,"fileType":"image/png","sha256":null,"preview":null,
                            "metadata":{"modified":"2024-01-01T12:00:00Z","accessed":null,"futureKey":1}},
                      "b":{"id":"b","fileName":"y.bin","size":7,"fileType":"application/octet-stream"}}}
        """.trimIndent()
        val req = SlipJson.decodeFromString(PrepareUploadRequest.serializer(), json)
        assertEquals(2, req.files.size)
        assertEquals("2024-01-01T12:00:00Z", req.files["a"]!!.metadata!!.modified)
        assertNull(req.files["b"]!!.metadata)
        assertEquals(Protocol.HTTP, req.info.proto)
        assertFalse(req.isTextMessage)
        val again = SlipJson.decodeFromString(PrepareUploadRequest.serializer(), SlipJson.encodeToString(PrepareUploadRequest.serializer(), req))
        assertEquals(req, again)

        val resp = PrepareUploadResponse("s", mapOf("a" to "t"))
        assertEquals(resp, SlipJson.decodeFromString(PrepareUploadResponse.serializer(), SlipJson.encodeToString(PrepareUploadResponse.serializer(), resp)))
    }

    @Test
    fun textMessageDetection() {
        val info = DeviceInfo("S")
        val text = PrepareUploadRequest(info, mapOf("t" to FileDto("t", "u.txt", 2, "text/plain", preview = "hi")))
        assertTrue(text.isTextMessage)
        val noPreview = PrepareUploadRequest(info, mapOf("t" to FileDto("t", "u.txt", 2, "text/plain")))
        assertFalse(noPreview.isTextMessage)
        val mixed = PrepareUploadRequest(info, mapOf(
            "t" to FileDto("t", "u.txt", 2, "text/plain", preview = "hi"),
            "i" to FileDto("i", "i.png", 2, "image/png", preview = "x"),
        ))
        assertFalse(mixed.isTextMessage)
    }
}
