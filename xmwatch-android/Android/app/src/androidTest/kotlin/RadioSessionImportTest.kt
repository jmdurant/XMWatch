package xmwatch.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.Assume
import org.junit.runner.RunWith
import java.io.File

/** Explicit development migration: the input is app-private and removed after encryption. */
@RunWith(AndroidJUnit4::class)
class RadioSessionImportTest {
    @Test fun importExistingSession() {
        Assume.assumeTrue("Explicit session import required",
            InstrumentationRegistry.getArguments().getString("allowSessionImport") == "true")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val input = File(context.filesDir, "session-import.json")
        assertTrue("No explicitly supplied session file", input.isFile)
        require(input.length() in 1..131072)
        try {
            val json = input.readText()
            assertTrue("Encrypted session could not be saved", RadioSecureStore.save(context, json))
            assertTrue("Encrypted session round trip failed", json == RadioSecureStore.load(context))
        } finally { assertTrue(input.delete()) }
    }
}
