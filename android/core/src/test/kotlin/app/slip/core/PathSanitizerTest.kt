package app.slip.core

import app.slip.core.server.DirectoryStorage
import app.slip.core.util.PathSanitizer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

class PathSanitizerTest {
    @Test
    fun sanitizes() {
        assertEquals("a.txt", PathSanitizer.sanitize("a.txt"))
        assertEquals("Photos/2024/a.jpg", PathSanitizer.sanitize("Photos/2024/a.jpg"))
        assertEquals("etc/passwd", PathSanitizer.sanitize("/etc/passwd"))
        assertEquals("etc/passwd", PathSanitizer.sanitize("../../etc/passwd"))
        assertEquals("a/b/c.txt", PathSanitizer.sanitize("a/./b/../c.txt"))
        assertEquals("dir/win.txt", PathSanitizer.sanitize("dir\\win.txt"))
        assertEquals("C_/x/a_b_.txt", PathSanitizer.sanitize("C:\\x\\a<b>.txt"))
        assertEquals("file", PathSanitizer.sanitize("../.."))
        assertEquals("file", PathSanitizer.sanitize(""))
        assertEquals("trail", PathSanitizer.sanitize("trail. . "))
        assertEquals("q_uestion_", PathSanitizer.sanitize("q?uestion*"))
        assertEquals("ctl_x", PathSanitizer.sanitize("ctl\u0001x"))
    }

    @Test
    fun counters() {
        assertEquals("a (1).txt", PathSanitizer.withCounter("a.txt", 1))
        assertEquals("archive.tar (2).gz", PathSanitizer.withCounter("archive.tar.gz", 2))
        assertEquals("README (3)", PathSanitizer.withCounter("README", 3))
        assertEquals(".bashrc (1)", PathSanitizer.withCounter(".bashrc", 1))
    }

    @Test
    fun directoryStorageStaysInsideRootAndDeduplicates() {
        val root = Files.createTempDirectory("slip-store").toFile()
        val storage = DirectoryStorage(root)
        repeat(3) { i ->
            val f = storage.create(PathSanitizer.sanitize("../../sub/x.txt"), 1, "text/plain")
            f.output.write("$i".toByteArray())
            f.commit(null)
        }
        val sub = root.resolve("sub")
        assertEquals(setOf("x.txt", "x (1).txt", "x (2).txt"), sub.list()!!.toSet())
        assertEquals("2", sub.resolve("x (2).txt").readText())
        val aborted = storage.create("y.txt", 1, "text/plain")
        aborted.output.write(1)
        aborted.abort()
        assertFalse(root.resolve("y.txt").exists())
        assertTrue(root.listFiles()!!.none { it.name.startsWith(".slip-partial-") })
        root.deleteRecursively()
    }
}
