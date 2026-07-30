package me.onj.clipman

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Test

class ServerConnectionConfigTest {
    @Test
    fun parsesPortableConnectionFile() {
        val details = ServerConnectionConfig.parse(
            """{"clipman":"server-connection","version":1,"address":"clipman://server.example:54321","host":"server.example","port":54321,"token":"test-token"}"""
        )
        assertEquals("clipman://server.example:54321", details.address)
        assertEquals("test-token", details.token)
    }

    @Test
    fun rejectsUnrelatedJson() {
        assertThrows(IllegalArgumentException::class.java) {
            ServerConnectionConfig.parse("""{"address":"clipman://server.example:54321","token":"test-token"}""")
        }
    }

    @Test
    fun exportedConnectionFileRoundTrips() {
        val exported = ServerConnectionConfig.create(
            "clipman://server.example:54321/",
            "test-token"
        )
        val details = ServerConnectionConfig.parse(exported)
        assertEquals("clipman://server.example:54321", details.address)
        assertEquals("test-token", details.token)
    }

    @Test
    fun exportedHttpsConnectionUsesDefaultPort() {
        val exported = ServerConnectionConfig.create("https://server.example", "test-token")
        val details = ServerConnectionConfig.parse(exported)
        assertEquals("https://server.example", details.address)
        assertEquals("test-token", details.token)
    }

    @Test
    fun embeddedAuthorityRoundTripsForHttpsHost() {
        val exported = ServerConnectionConfig.create(
            "https://server.example:54321",
            "test-token",
            testAuthority,
            "server.example"
        )
        val details = ServerConnectionConfig.parse(exported)
        assertNotNull(details.authority)
        assertEquals("server.example", details.authority?.host)
        assertEquals(testAuthorityFingerprint, details.authority?.fingerprint)
    }

    @Test
    fun embeddedAuthorityRequiresHttps() {
        assertThrows(IllegalArgumentException::class.java) {
            ServerConnectionConfig.create("clipman://server.example:54321", "test-token", testAuthority)
        }
    }

    @Test
    fun embeddedAuthorityRejectsPrivateKeyMaterial() {
        assertThrows(IllegalArgumentException::class.java) {
            ServerConnectionConfig.parseAuthority("-----BEGIN PRIVATE KEY-----\nnot-a-key\n-----END PRIVATE KEY-----", "https://server.example")
        }
    }

    companion object {
        private const val testAuthorityFingerprint = "F9:63:AE:33:A5:83:4C:67:3F:6C:78:5E:F4:82:2A:D2:82:3B:80:4F:2D:B1:35:62:8F:57:5B:B2:2D:F2:FF:00"
        private val testAuthority = """
            -----BEGIN CERTIFICATE-----
            MIIDMzCCAhugAwIBAgIUaI6ujB+fhJGrszpRsyLc+hga3MEwDQYJKoZIhvcNAQEL
            BQAwITEfMB0GA1UEAwwWQ2xpcG1hbiBUZXN0IEF1dGhvcml0eTAeFw0yNjA3MzAw
            ODQyMzdaFw0zNjA3MjcwODQyMzdaMCExHzAdBgNVBAMMFkNsaXBtYW4gVGVzdCBB
            dXRob3JpdHkwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC8mlumHxZZ
            FWXMNgIlALja46yyw/PvRrCjn7JCNmJBDgmCVEDpOXy3ShiOC4aWS/4j3IPuf0ie
            Yx/tz4T02RjX40coQXl6vC2MPeKNndfHI+LKmxXZBPcOOn7U6H9ht/0Wel3jOC3D
            XEXokFk2KJBP1hZNIhzKHwRk6LmQ8R+dhGA6gl18Vf0UA4gwvbrIRXFMpFCjgJu6
            9ijVycC/mupE6eqBRER+PPiOaqhFqP6XgwlZDx5MVGDB4YE0C8i2R9TgKJRQ4RZL
            DrOkJ10Dx43eH7Ctq/Pi6635kv9Ud3QW5TF2z5aG/7tHA9p3DP6w/FtjCXjKhrKk
            lS4V8KQfj3Y9AgMBAAGjYzBhMB0GA1UdDgQWBBQTDO91IjyMreUuTchFgDT2FVXZ
            LDAfBgNVHSMEGDAWgBQTDO91IjyMreUuTchFgDT2FVXZLDAPBgNVHRMBAf8EBTAD
            AQH/MA4GA1UdDwEB/wQEAwIBBjANBgkqhkiG9w0BAQsFAAOCAQEAiZ+YXrMqbayA
            Ihswj4GWqQIQLi8HQJCMQA1p44qzCiokEI79Bhlwt03kh7I2iaZdQlVX7V7wpFWu
            PLUSRq0jfe15QwpCGiPLtBIoYfzVR3G5fPclQ/l94nk0H6KUESpCHx3/GYRurVYz
            Hlywz+x7vqQs7ThMrmzsvgG2XPjc1j/uou7foKJkgxSllFRTbkUzfKA2bcA0b4p+
            xCTXMx+vhM90HVvh+ItZiKVfVimj05vz+ImQU8xEuDu2CnmQUzNzUOemSHGJT6co
            IyhCMiU1h+FqQXsUQyqO51Tk/cBUfdCh8nuLVbuMC2f0KEDGAy0AtYrs0RoteBXK
            9MkEmTFxVg==
            -----END CERTIFICATE-----
        """.trimIndent()
    }
}
