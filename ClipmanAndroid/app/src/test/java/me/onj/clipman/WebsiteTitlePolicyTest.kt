package me.onj.clipman

import java.net.InetAddress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class WebsiteTitlePolicyTest {
    @Test
    fun titlePrecedenceAndSanitizingAreDeterministic() {
        val html = """
            <html><head>
            <title>Fallback title</title>
            <meta name="twitter:title" content="Twitter title">
            <meta content="Open &amp; Graph&#x202E; title" property="og:title">
            </head></html>
        """.trimIndent()

        assertEquals("Open & Graph title", WebsiteTitleDocument.extract(html))
    }

    @Test
    fun policyRejectsCredentialsPortsAndCapabilities() {
        assertThrows(IllegalArgumentException::class.java) {
            WebsiteTitlePolicy.validate("https://user:pass@example.org/page")
        }
        assertThrows(IllegalArgumentException::class.java) {
            WebsiteTitlePolicy.validate("https://example.org:8443/page")
        }
        assertThrows(IllegalArgumentException::class.java) {
            WebsiteTitlePolicy.validate("https://example.org/reset-password?token=secret")
        }
        assertThrows(IllegalArgumentException::class.java) {
            WebsiteTitlePolicy.validate("https://example.org/path/Az19Qw82Er73Ty64Ui50Op21Lm98")
        }
        assertThrows(IllegalArgumentException::class.java) {
            WebsiteTitlePolicy.validate("https://example.org/login.php")
        }
        assertThrows(IllegalArgumentException::class.java) {
            WebsiteTitlePolicy.validate("https://example.org/page?reset_token=value")
        }
        assertFalse(LinkPresentation.isFetchableHttpUrl("https://user:pass@example.org/page"))
        assertFalse(LinkPresentation.isFetchableHttpUrl("https://example.org/reset-password?token=secret"))
        assertTrue(LinkPresentation.isFetchableHttpUrl("https://example.org/articles/accessible-clipboard"))
    }

    @Test
    fun overlongUrlIsRejectedBeforeValidationOrFetch() {
        val prefix = "https://example.org/"
        val exact = prefix + "a".repeat(WebsiteTitlePolicy.maxUrlCharacters - prefix.length)
        val overlong = exact + "a"

        assertEquals(exact, WebsiteTitlePolicy.validate(exact).toString())
        val validationError = assertThrows(IllegalArgumentException::class.java) {
            WebsiteTitlePolicy.validate(overlong)
        }
        assertTrue(validationError.message.orEmpty().contains("8,192"))

        val fetchError = assertThrows(IllegalArgumentException::class.java) {
            WebsiteTitleFetcher.fetch(overlong)
        }
        assertTrue(fetchError.message.orEmpty().contains("8,192"))
    }

    @Test
    fun fetchedTitlesStripUnsafeUnicodeAndRetainNormalUnicode() {
        val unsafe = "Café\u0001\u200b\ud800\ufffd\u2028\u2029 日本語"

        assertEquals("Café 日本語", WebsiteTitleDocument.sanitize(unsafe))
        assertEquals(
            "Résumé 日本語",
            WebsiteTitleDocument.extract("<title>Résumé&#x202E;&#65533; 日本語</title>")
        )
    }

    @Test
    fun onlyGlobalAddressesPass() {
        assertFalse(WebsiteTitlePolicy.isGlobalAddress(InetAddress.getByName("127.0.0.1")))
        assertFalse(WebsiteTitlePolicy.isGlobalAddress(InetAddress.getByName("192.168.1.4")))
        assertFalse(WebsiteTitlePolicy.isGlobalAddress(InetAddress.getByName("100.64.0.1")))
        assertFalse(WebsiteTitlePolicy.isGlobalAddress(InetAddress.getByName("2001:db8::1")))
        assertFalse(WebsiteTitlePolicy.isGlobalAddress(InetAddress.getByName("2001:10::1")))
        assertFalse(WebsiteTitlePolicy.isGlobalAddress(InetAddress.getByName("64:ff9b::c0a8:101")))
        assertFalse(WebsiteTitlePolicy.isGlobalAddress(InetAddress.getByName("64:ff9b:1::c0a8:101")))
        assertFalse(WebsiteTitlePolicy.isGlobalAddress(InetAddress.getByName("2002:c0a8:101::1")))
        assertFalse(WebsiteTitlePolicy.isGlobalAddress(InetAddress.getByName("2002:808:808::1")))
        assertFalse(WebsiteTitlePolicy.isGlobalAddress(InetAddress.getByName("fc00::1")))
        assertTrue(WebsiteTitlePolicy.isGlobalAddress(InetAddress.getByName("8.8.8.8")))
    }

    @Test
    fun otherwiseGlobalIpv6RejectsSensitiveIpv4TailsButAllowsPublicTailOne() {
        listOf(
            "2606:4700:4700::a00:1",
            "2606:4700:4700::6440:1",
            "2606:4700:4700::7f00:1",
            "2606:4700:4700::a9fe:1",
            "2606:4700:4700::ac10:1",
            "2606:4700:4700::c0a8:1"
        ).forEach { value ->
            assertFalse(value, WebsiteTitlePolicy.isGlobalAddress(InetAddress.getByName(value)))
        }

        assertTrue(
            WebsiteTitlePolicy.isGlobalAddress(InetAddress.getByName("2606:4700:4700::1"))
        )
    }
}
