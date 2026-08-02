package me.onj.clipman

import java.net.HttpURLConnection
import java.net.URL
import java.security.KeyStore
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory

class ServerStorageClient(
    serverUrl: String,
    token: String,
    databasePassword: String,
    caCertPem: String = "",
    caHost: String = ""
) {
    private val baseUrl = normalizeBaseUrl(serverUrl)
    private val token = cleanToken(token)
    private val databaseId = ServerDatabaseIdentity.fromTokenAndPassword(token, databasePassword)
    private val hasDatabasePassword = databasePassword.isNotEmpty()
    private val privateAuthority = runCatching { ServerConnectionConfig.parseAuthority(caCertPem, serverUrl) }.getOrNull()
    private val authorityValid = caCertPem.isBlank() || (privateAuthority != null && (caHost.isBlank() || privateAuthority.host.equals(caHost.trim(), ignoreCase = true)))

    val isConfigured: Boolean
        get() = baseUrl.isNotBlank() && token.trim().isNotBlank() && hasDatabasePassword && databaseId.isNotBlank() && authorityValid

    fun download(): ServerDatabaseDownload {
        val connection = openConnection("GET")
        val code = connection.responseCode
        if (code == HttpURLConnection.HTTP_NOT_FOUND) {
            throw ServerDatabaseNotFoundException("The Clipman Server database does not exist yet.")
        }
        if (code < 200 || code > 299) {
            throw IllegalStateException("Clipman Server returned HTTP $code.")
        }
        connection.inputStream.use { input ->
            val data = ClipDatabaseFile.readDatabaseBlob(input, connection.contentLengthLong)
            return ServerDatabaseDownload(
                revision = cleanRevision(connection.getHeaderField("X-Clipman-Revision") ?: connection.getHeaderField("ETag")),
                data = data
            )
        }
    }

    fun metadata(): String {
        val connection = openConnection("HEAD")
        val code = connection.responseCode
        if (code == HttpURLConnection.HTTP_NOT_FOUND) return ""
        if (code < 200 || code > 299) {
            throw IllegalStateException("Clipman Server returned HTTP $code.")
        }
        return cleanRevision(connection.getHeaderField("X-Clipman-Revision") ?: connection.getHeaderField("ETag"))
    }

    fun upload(data: ByteArray, expectedRevision: String): ServerDatabaseDownload {
        val connection = openConnection("PUT")
        if (expectedRevision.isNotBlank()) {
            connection.setRequestProperty("If-Match", "\"${expectedRevision.trim('"')}\"")
        }
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/octet-stream")
        connection.outputStream.use { output -> output.write(data) }
        val code = connection.responseCode
        if (code == HttpURLConnection.HTTP_CONFLICT || code == HttpURLConnection.HTTP_PRECON_FAILED) {
            throw ServerConflictException("Clipman Server reported a revision conflict.")
        }
        if (code < 200 || code > 299) {
            throw IllegalStateException("Clipman Server returned HTTP $code.")
        }
        return ServerDatabaseDownload(
            revision = cleanRevision(connection.getHeaderField("X-Clipman-Revision") ?: connection.getHeaderField("ETag")),
            data = ByteArray(0)
        )
    }

    private fun openConnection(method: String): HttpURLConnection {
        require(isConfigured) { "Clipman server host and token are required." }
        val url = URL(baseUrl + "api/v1/database/" + encodePathSegment(databaseId))
        val connection = (url.openConnection() as HttpURLConnection)
        connection.requestMethod = method
        connection.connectTimeout = 8000
        connection.readTimeout = 8000
        connection.instanceFollowRedirects = false
        if (connection is HttpsURLConnection && privateAuthority != null) {
            connection.sslSocketFactory = sslSocketFactory(privateAuthority)
        }
        connection.setRequestProperty("Authorization", "Bearer ${token.trim()}")
        connection.setRequestProperty("User-Agent", "ClipmanAndroid/${BuildConfig.VERSION_NAME}")
        return connection
    }

    private fun sslSocketFactory(authority: ServerCertificateAuthority): javax.net.ssl.SSLSocketFactory {
        val store = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            setCertificateEntry("clipman-private-authority", authority.certificate)
        }
        val managers = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(store) }
        return SSLContext.getInstance("TLS").apply { init(null, managers.trustManagers, null) }.socketFactory
    }

    private fun normalizeBaseUrl(value: String): String {
        var url = value.trim()
        if (url.isEmpty()) return ""
        val labeled = Regex("""(?i)\b(?:Server address|Address|URL)\s*:\s*(\S+)""").find(url)
        if (labeled != null) {
            url = labeled.groupValues[1]
        }
        val embedded = Regex("""(?i)\b(?:clipman|https?|http)://[^\s,;]+""").find(url)
        if (embedded != null) {
            url = embedded.value
        }
        if (url.startsWith("clipman://", ignoreCase = true)) {
            url = "http://" + url.substringAfter("://")
        }
        if (!url.contains("://")) {
            url = "http://$url"
        }
        if (!url.endsWith("/")) url += "/"
        return url
    }

    private fun cleanToken(value: String): String {
        val text = value.trim()
        val labeled = Regex("""(?i)\b(?:Token|AuthToken)\s*[:=]\s*"?([A-Za-z0-9_\-]+)""").find(text)
        if (labeled != null) return labeled.groupValues[1].trim()
        val json = Regex(""""AuthToken"\s*:\s*"([^"]+)"""").find(text)
        if (json != null) return json.groupValues[1].trim()
        return text.trim('"')
    }

    private fun encodePathSegment(value: String): String =
        java.net.URLEncoder.encode(value, "UTF-8").replace("+", "%20")

    private fun cleanRevision(value: String?): String =
        (value ?: "").trim().trim('"')
}

data class ServerDatabaseDownload(
    val revision: String,
    val data: ByteArray
)

class ServerDatabaseNotFoundException(message: String) : Exception(message)
