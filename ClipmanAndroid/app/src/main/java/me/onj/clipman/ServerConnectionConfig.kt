package me.onj.clipman

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.URI
import java.io.ByteArrayInputStream
import java.security.MessageDigest
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.time.Instant

data class ServerCertificateAuthority(
    val pem: String,
    val host: String,
    val certificate: X509Certificate,
    val subject: String,
    val expiresUnixMs: Long,
    val fingerprint: String
)

data class ServerConnectionDetails(
    val address: String,
    val token: String,
    val authority: ServerCertificateAuthority?
)

object ServerConnectionConfig {
    private val prettyJson = Json { prettyPrint = true }

    fun create(addressValue: String, tokenValue: String, caCertPem: String = "", caHost: String = ""): String {
        var address = addressValue.trim().trimEnd('/')
        if (address.startsWith("http://", ignoreCase = true)) {
            address = "clipman://" + address.substring("http://".length)
        } else if (!address.contains("://") && address.isNotEmpty()) {
            address = "clipman://$address"
        }
        val uri = runCatching { URI(address) }.getOrNull()
        val host = uri?.host.orEmpty()
        val port = uri?.port?.takeIf { it > 0 }
            ?: if (uri?.scheme.equals("https", ignoreCase = true)) 443 else 80
        val token = tokenValue.trim().trim('"', '\'', ',', ';')
        require(host.isNotEmpty() && port in 1..65535 && token.isNotEmpty()) {
            "Enter a valid server address, port, and token before exporting."
        }
        val authority = parseAuthority(caCertPem, address)
        require(authority == null || caHost.isBlank() || authority.host.equals(caHost.trim(), ignoreCase = true)) {
            "The private certificate authority is configured for a different server host."
        }
        val value = buildJsonObject {
            put("clipman", JsonPrimitive("server-connection"))
            put("version", JsonPrimitive(1))
            put("address", JsonPrimitive(address))
            put("host", JsonPrimitive(host))
            put("port", JsonPrimitive(port))
            put("token", JsonPrimitive(token))
            if (authority != null) put("ca_cert_pem", JsonPrimitive(authority.pem))
        }
        return prettyJson.encodeToString(JsonObject.serializer(), value)
    }

    fun parse(text: String): ServerConnectionDetails {
        val objectValue = Json.parseToJsonElement(text).jsonObject
        require(objectValue["clipman"]?.jsonPrimitive?.content == "server-connection") {
            "This is not a Clipman Server connection file."
        }
        require(objectValue["version"]?.jsonPrimitive?.intOrNull == 1) {
            "This Clipman Server connection-file version is not supported."
        }

        var address = objectValue["address"]?.jsonPrimitive?.content?.trim().orEmpty()
        if (address.isEmpty()) {
            val host = objectValue["host"]?.jsonPrimitive?.content?.trim().orEmpty()
            val port = objectValue["port"]?.jsonPrimitive?.intOrNull ?: -1
            if (host.isNotEmpty() && port in 1..65535) address = "$host:$port"
        }
        if (address.startsWith("http://", ignoreCase = true)) {
            address = "clipman://" + address.substring("http://".length)
        } else if (!address.contains("://") && address.isNotEmpty()) {
            address = "clipman://$address"
        }
        address = address.trimEnd('/')
        val token = objectValue["token"]?.jsonPrimitive?.content?.trim().orEmpty().trim('"', '\'', ',', ';')
        require(address.isNotEmpty() && token.isNotEmpty()) {
            "The connection file does not contain both a server address and token."
        }
        val authority = parseAuthority(objectValue["ca_cert_pem"]?.jsonPrimitive?.content.orEmpty(), address)
        return ServerConnectionDetails(address, token, authority)
    }

    fun parseAuthority(pemValue: String, addressValue: String): ServerCertificateAuthority? {
        val pem = pemValue.trim()
        if (pem.isEmpty()) return null
        require(pem.toByteArray(Charsets.UTF_8).size <= 32 * 1024) { "The private certificate authority exceeds the 32 KiB limit." }
        require(!pem.contains("PRIVATE KEY", ignoreCase = true)) { "The private certificate authority must not contain private key material." }
        val match = Regex("""\A\s*-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\r\n]+?)\s*-----END CERTIFICATE-----\s*\z""").matchEntire(pem)
            ?: error("The private certificate authority must contain exactly one PEM CERTIFICATE block.")
        val der = java.util.Base64.getMimeDecoder().decode(match.groupValues[1])
        val certificates = CertificateFactory.getInstance("X.509")
            .generateCertificates(ByteArrayInputStream(der))
        require(certificates.size == 1) { "The private certificate authority must contain exactly one certificate." }
        val certificate = certificates.single() as X509Certificate
        certificate.checkValidity()
        require(certificate.basicConstraints >= 0) { "The configured certificate is not marked as a certificate authority." }
        val keyUsage = certificate.keyUsage
        require(keyUsage == null || (keyUsage.size > 5 && keyUsage[5])) { "The configured certificate authority cannot sign certificates." }

        val address = normalizeAddress(addressValue)
        val uri = runCatching { URI(address.replaceFirst(Regex("(?i)^clipman://"), "http://")) }.getOrNull()
        require(uri?.scheme.equals("https", ignoreCase = true) && !uri?.host.isNullOrBlank()) {
            "A private certificate authority can be used only with an HTTPS server address."
        }
        val canonical = java.util.Base64.getMimeEncoder(64, "\n".toByteArray())
            .encodeToString(certificate.encoded)
        val fingerprint = MessageDigest.getInstance("SHA-256").digest(certificate.encoded)
            .joinToString(":") { "%02X".format(it) }
        return ServerCertificateAuthority(
            pem = "-----BEGIN CERTIFICATE-----\n$canonical\n-----END CERTIFICATE-----\n",
            host = uri!!.host,
            certificate = certificate,
            subject = certificate.subjectX500Principal.name,
            expiresUnixMs = certificate.notAfter.time,
            fingerprint = fingerprint
        )
    }

    private fun normalizeAddress(value: String): String {
        var address = value.trim().trimEnd('/')
        if (address.startsWith("http://", ignoreCase = true)) address = "clipman://" + address.substring("http://".length)
        else if (!address.contains("://") && address.isNotEmpty()) address = "clipman://$address"
        return address
    }
}
