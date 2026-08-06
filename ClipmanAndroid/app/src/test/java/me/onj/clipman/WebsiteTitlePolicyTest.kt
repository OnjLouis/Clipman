package me.onj.clipman

import java.net.InetAddress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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

        assertEquals("Open & Graph title", WebsiteTitleDocument.extract(html, "example.org"))
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
            WebsiteTitlePolicy.validate("https://example.org/page?token=secret")
        }
        assertThrows(IllegalArgumentException::class.java) {
            WebsiteTitlePolicy.validate("https://example.org/path/Az19Qw82Er73Ty64Ui50Op21Lm98Qr76")
        }
        assertThrows(IllegalArgumentException::class.java) {
            WebsiteTitlePolicy.validate("https://example.org/page?reset_token=value")
        }
        assertThrows(IllegalArgumentException::class.java) {
            WebsiteTitlePolicy.validate("https://example.org/page?oauth_access_token=value")
        }
        assertFalse(LinkPresentation.isFetchableHttpUrl("https://user:pass@example.org/page"))
        assertFalse(LinkPresentation.isFetchableHttpUrl("https://example.org/page?token=secret"))
        assertTrue(LinkPresentation.isFetchableHttpUrl("https://example.org/articles/accessible-clipboard"))
        assertTrue(LinkPresentation.isFetchableHttpUrl("https://example.org/login"))
        assertTrue(LinkPresentation.isFetchableHttpUrl("https://example.org/reset-password#instructions"))
        assertTrue(LinkPresentation.isFetchableHttpUrl("https://www.youtube.com/watch?v=6-fvja4UXJk&pp=ygUbU29uaWNjb3V0dXJlIEJhbGluZXNlIGZsdXRl"))
        assertTrue(LinkPresentation.isFetchableHttpUrl("https://example.org/a-long-human-readable-article-title-with-2026-and-many-words?utm_source=share"))
        assertTrue(LinkPresentation.isFetchableHttpUrl("https://nautil.us/a-new-toad-species-emerges-from-the-la-brea-tar-pits-1283396?utm_source=firefox-newtab-en-gb"))
        assertTrue(LinkPresentation.isFetchableHttpUrl("https://www.independent.co.uk/news/science/monkeys-primates-friendships-animals-b3028129.html?utm_source=firefox-newtab-en-gb"))
        assertFalse(LinkPresentation.isFetchableHttpUrl("https://example.org/download/550e8400-e29b-41d4-a716-446655440000"))
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
            WebsiteTitleDocument.extract("<title>Résumé&#x202E;&#65533; 日本語</title>", "example.org")
        )
    }

    @Test
    fun scriptHeavyPagesRetainMetadataAndIgnoreUnsafeFallbacks() {
        val html = "<script>" + "x".repeat(180 * 1024) +
            "</script><meta property=\"og:title\" content=\"Useful video title\">"
        assertEquals("Useful video title", WebsiteTitleDocument.extract(html, "youtube.com"))
        assertEquals(
            "Article heading",
            WebsiteTitleDocument.extract(
                "<svg><title>Decorative icon</title></svg><h1>Article heading</h1>",
                "example.org"
            )
        )
        assertNull(WebsiteTitleDocument.extract("<title>Reddit - Dive into anything</title>", "reddit.com"))
        assertNull(WebsiteTitleDocument.extract("<title>example.org</title>", "example.org"))
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
