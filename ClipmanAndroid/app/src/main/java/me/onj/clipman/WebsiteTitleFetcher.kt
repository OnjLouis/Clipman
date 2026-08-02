package me.onj.clipman

import java.io.BufferedInputStream
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.FilterInputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.IDN
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.Charset
import java.nio.charset.StandardCharsets
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.zip.GZIPInputStream
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

object WebsiteTitleFetcher {
    private const val timeoutMilliseconds = 8_000
    private const val maxRedirects = 3
    private const val maxHeaderBytes = 32 * 1024
    private const val maxWireBodyBytes = 256 * 1024
    private const val maxDecodedBodyBytes = 128 * 1024

    fun fetch(url: String): String {
        val deadlineNanos = System.nanoTime() + timeoutMilliseconds * 1_000_000L
        var current = WebsiteTitlePolicy.validate(url)
        repeat(maxRedirects + 1) { redirectCount ->
            val response = request(current, deadlineNanos)
            if (response.status in setOf(301, 302, 303, 307, 308)) {
                if (redirectCount >= maxRedirects) error("The website redirected too many times.")
                val location = response.header("location") ?: error("The website returned a redirect without a destination.")
                WebsiteTitlePolicy.requireUrlLength(location)
                val redirected = WebsiteTitlePolicy.validate(current.resolve(location).toASCIIString())
                if (current.scheme.equals("https", true) && redirected.scheme.equals("http", true)) {
                    error("Clipman refused a redirect from HTTPS to insecure HTTP.")
                }
                current = redirected
                return@repeat
            }
            if (response.status !in 200..299) error("The website returned HTTP ${response.status}.")
            val contentType = response.header("content-type").orEmpty()
            if (!contentType.substringBefore(';').trim().equals("text/html", ignoreCase = true)) {
                error("The website did not return an HTML page.")
            }
            val contentEncoding = response.header("content-encoding").orEmpty().substringBefore(',').trim()
            val decoded = when {
                contentEncoding.isBlank() || contentEncoding.equals("identity", ignoreCase = true) ->
                    response.body.copyOf(minOf(response.body.size, maxDecodedBodyBytes))
                contentEncoding.equals("gzip", ignoreCase = true) ->
                    GZIPInputStream(ByteArrayInputStream(response.body)).use { it.readPrefix(maxDecodedBodyBytes) }
                else -> error("The website returned an unsupported content encoding.")
            }
            val charset = contentType.substringAfter("charset=", "")
                .substringBefore(';')
                .trim()
                .trim('"', '\'')
                .takeIf { it.isNotBlank() }
                ?.let { runCatching { Charset.forName(it) }.getOrNull() }
                ?: StandardCharsets.UTF_8
            return WebsiteTitleDocument.extract(decoded.toString(charset))
                ?: error("The website did not provide a usable title.")
        }
        error("The website redirected too many times.")
    }

    private fun request(uri: URI, deadlineNanos: Long): HttpResponse {
        val host = uri.host.trim('[', ']')
        val secure = uri.scheme.equals("https", true)
        val port = if (secure) 443 else 80
        val addresses = resolveAddresses(host, deadlineNanos)
        if (addresses.isEmpty() || addresses.any { !WebsiteTitlePolicy.isGlobalAddress(it) }) {
            error("Clipman only retrieves titles from public internet addresses.")
        }

        var lastFailure: Throwable? = null
        for (address in addresses) {
            val remaining = remainingMilliseconds(deadlineNanos)
            try {
                val plain = Socket()
                plain.connect(InetSocketAddress(address, port), remaining)
                plain.soTimeout = remainingMilliseconds(deadlineNanos)
                val socket = if (secure) secureSocket(plain, host, port, deadlineNanos) else plain
                socket.use {
                    writeRequest(it.getOutputStream(), uri, host)
                    return readResponse(it, deadlineNanos)
                }
            } catch (error: Exception) {
                lastFailure = error
            }
        }
        throw IllegalStateException("Could not retrieve the website title.", lastFailure)
    }

    private fun resolveAddresses(host: String, deadlineNanos: Long): List<InetAddress> {
        val executor = Executors.newSingleThreadExecutor { task ->
            Thread(task, "Clipman website title DNS").apply { isDaemon = true }
        }
        return try {
            executor.submit<List<InetAddress>> { InetAddress.getAllByName(host).toList() }
                .get(remainingMilliseconds(deadlineNanos).toLong(), TimeUnit.MILLISECONDS)
        } finally {
            executor.shutdownNow()
        }
    }

    private fun secureSocket(plain: Socket, host: String, port: Int, deadlineNanos: Long): SSLSocket {
        val socket = (SSLSocketFactory.getDefault() as SSLSocketFactory)
            .createSocket(plain, host, port, true) as SSLSocket
        socket.sslParameters = socket.sslParameters.apply { endpointIdentificationAlgorithm = "HTTPS" }
        socket.soTimeout = remainingMilliseconds(deadlineNanos)
        socket.startHandshake()
        return socket
    }

    private fun writeRequest(output: OutputStream, uri: URI, host: String) {
        val path = uri.rawPath.takeUnless { it.isNullOrBlank() } ?: "/"
        val target = if (uri.rawQuery.isNullOrBlank()) path else "$path?${uri.rawQuery}"
        val hostHeader = if (host.contains(':')) "[$host]" else host
        val request = buildString {
            append("GET ").append(target).append(" HTTP/1.1\r\n")
            append("Host: ").append(hostHeader).append("\r\n")
            append("Accept: text/html\r\n")
            append("Accept-Encoding: gzip\r\n")
            append("User-Agent: ClipmanAndroid/").append(BuildConfig.VERSION_NAME).append("\r\n")
            append("Connection: close\r\n\r\n")
        }
        output.write(request.toByteArray(StandardCharsets.US_ASCII))
        output.flush()
    }

    private fun readResponse(socket: Socket, deadlineNanos: Long): HttpResponse {
        val buffered = BufferedInputStream(DeadlineInputStream(socket.getInputStream(), socket, deadlineNanos))
        val statusLine = buffered.readAsciiLine(maxHeaderBytes) ?: throw EOFException("The website returned no response.")
        val status = statusLine.split(' ').getOrNull(1)?.toIntOrNull()
            ?: error("The website returned an invalid HTTP response.")
        var headerBytes = statusLine.length + 2
        val headers = linkedMapOf<String, String>()
        while (true) {
            val line = buffered.readAsciiLine(maxHeaderBytes - headerBytes)
                ?: throw EOFException("The website response headers were incomplete.")
            headerBytes += line.length + 2
            if (line.isEmpty()) break
            val separator = line.indexOf(':')
            if (separator <= 0) error("The website returned an invalid HTTP header.")
            val key = line.substring(0, separator).trim().lowercase(Locale.ROOT)
            val value = line.substring(separator + 1).trim()
            headers[key] = headers[key]?.let { "$it, $value" } ?: value
        }

        val body = when {
            status in 100..199 || status == 204 || status == 304 -> ByteArray(0)
            headers["transfer-encoding"].orEmpty().split(',').any { it.trim().equals("chunked", true) } ->
                buffered.readChunkedPrefix(maxWireBodyBytes)
            headers["content-length"] != null -> {
                val length = headers.getValue("content-length").toLongOrNull()
                    ?: error("The website returned an invalid content length.")
                buffered.readExactly(minOf(length, maxWireBodyBytes.toLong()).toInt())
            }
            else -> buffered.readPrefix(maxWireBodyBytes)
        }
        remainingMilliseconds(deadlineNanos)
        return HttpResponse(status, headers, body)
    }

    private fun remainingMilliseconds(deadlineNanos: Long): Int {
        val remaining = (deadlineNanos - System.nanoTime()) / 1_000_000L
        if (remaining <= 0) error("The website did not respond before the title request timed out.")
        return remaining.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
    }

    private fun InputStream.readAsciiLine(maxBytes: Int): String? {
        if (maxBytes <= 0) error("The website response headers are too large.")
        val output = ByteArrayOutputStream()
        while (output.size() < maxBytes) {
            val next = read()
            if (next < 0) return if (output.size() == 0) null else error("The website returned an incomplete HTTP line.")
            if (next == '\n'.code) {
                val bytes = output.toByteArray()
                val length = if (bytes.lastOrNull() == '\r'.code.toByte()) bytes.size - 1 else bytes.size
                return String(bytes, 0, length, StandardCharsets.ISO_8859_1)
            }
            output.write(next)
        }
        error("The website response headers are too large.")
    }

    private fun InputStream.readChunkedPrefix(maxBytes: Int): ByteArray {
        val output = ByteArrayOutputStream()
        while (true) {
            val sizeLine = readAsciiLine(128) ?: throw EOFException("The chunked website response ended early.")
            val size = sizeLine.substringBefore(';').trim().toLongOrNull(16)
                ?: error("The website returned an invalid chunked response.")
            if (size == 0L) {
                while (true) {
                    val trailer = readAsciiLine(maxHeaderBytes) ?: break
                    if (trailer.isEmpty()) break
                }
                return output.toByteArray()
            }
            val remaining = maxBytes - output.size()
            if (size > remaining) {
                output.write(readExactly(remaining))
                return output.toByteArray()
            }
            output.write(readExactly(size.toInt()))
            if (read() != '\r'.code || read() != '\n'.code) error("The website returned an invalid chunk boundary.")
        }
    }

    private fun InputStream.readExactly(length: Int): ByteArray {
        val output = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val count = read(output, offset, length - offset)
            if (count < 0) throw EOFException("The website response ended early.")
            offset += count
        }
        return output
    }

    private fun InputStream.readPrefix(maxBytes: Int): ByteArray {
        val output = ByteArrayOutputStream(minOf(maxBytes, 16 * 1024))
        val buffer = ByteArray(8 * 1024)
        var total = 0
        while (true) {
            val count = read(buffer, 0, minOf(buffer.size, maxBytes - total))
            if (count < 0) break
            total += count
            output.write(buffer, 0, count)
            if (total == maxBytes) break
        }
        return output.toByteArray()
    }

    private data class HttpResponse(
        val status: Int,
        val headers: Map<String, String>,
        val body: ByteArray
    ) {
        fun header(name: String): String? = headers[name.lowercase(Locale.ROOT)]
    }

    private class DeadlineInputStream(
        input: InputStream,
        private val socket: Socket,
        private val deadlineNanos: Long
    ) : FilterInputStream(input) {
        override fun read(): Int {
            socket.soTimeout = remainingMilliseconds(deadlineNanos)
            return super.read()
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            socket.soTimeout = remainingMilliseconds(deadlineNanos)
            return super.read(buffer, offset, length)
        }
    }
}

object WebsiteTitlePolicy {
    internal const val maxUrlCharacters = 8192
    private val blockedHostSuffixes = listOf(
        ".example", ".home", ".internal", ".invalid", ".lan", ".local", ".localhost", ".onion", ".test"
    )
    private val blockedPathWords = setOf(
        "auth", "authenticate", "callback", "confirm", "confirmation", "invite", "login", "magic-link",
        "oauth", "password-reset", "reset", "reset-password", "secret", "signin", "sign-in", "token",
        "unsubscribe", "verification", "verify"
    )
    private val blockedQueryKeys = setOf(
        "access_token", "auth", "authorization", "code", "confirm", "confirmation", "credential", "expires",
        "hash", "invite", "invitation", "jwt", "key", "magic", "password", "reset", "secret", "session",
        "sig", "signature", "signed", "token", "verify", "verification", "x-amz-credential",
        "x-amz-security-token", "x-amz-signature"
    )

    fun validate(value: String): URI {
        requireUrlLength(value)
        val uri = runCatching { URI(value.trim()) }.getOrElse { error("This entry is not a valid website URL.") }
        val scheme = uri.scheme?.lowercase(Locale.ROOT)
        require(scheme == "http" || scheme == "https") { "Only HTTP and HTTPS website titles can be retrieved." }
        require(uri.rawUserInfo.isNullOrBlank()) { "Clipman will not retrieve a title from a URL containing credentials." }
        val expectedPort = if (scheme == "https") 443 else 80
        require(uri.port == -1 || uri.port == expectedPort) { "Clipman only retrieves titles over the default HTTP or HTTPS port." }
        val host = uri.host?.trim('[', ']')?.trimEnd('.') ?: error("This website URL has no host name.")
        val asciiHost = if (host.contains(':')) {
            host.lowercase(Locale.ROOT)
        } else {
            runCatching { IDN.toASCII(host, IDN.USE_STD3_ASCII_RULES) }
                .getOrElse { error("This website has an invalid host name.") }
                .lowercase(Locale.ROOT)
        }
        require(asciiHost.isNotBlank()) { "This website URL has no host name." }
        require(asciiHost != "localhost" && blockedHostSuffixes.none { asciiHost.endsWith(it) }) {
            "Clipman only retrieves titles from public internet websites."
        }
        require(!looksLikeCapability(uri)) {
            "Clipman refused this URL because it appears to contain a login, reset, confirmation, token, or signed capability."
        }
        val authority = if (asciiHost.contains(':')) "[$asciiHost]" else asciiHost
        val port = if (uri.port == -1) "" else ":${uri.port}"
        val path = uri.rawPath.takeUnless { it.isNullOrBlank() } ?: "/"
        val query = uri.rawQuery?.let { "?$it" }.orEmpty()
        return URI("$scheme://$authority$port$path$query")
    }

    internal fun isWithinUrlLength(value: String): Boolean = value.length <= maxUrlCharacters

    internal fun requireUrlLength(value: String) {
        require(isWithinUrlLength(value)) { "This website URL is longer than Clipman's 8,192-character limit." }
    }

    internal fun looksLikeCapability(uri: URI): Boolean {
        val pathSegments = uri.rawPath.orEmpty().split('/').mapNotNull(::decode)
        if (pathSegments.any { segment ->
                val normalized = segment.lowercase(Locale.ROOT)
                    .replace(Regex("(?i)\\.(?:aspx?|html?|php|shtml)$"), "")
                    .replace('_', '-')
                    .trim()
                containsBlockedWord(normalized, blockedPathWords) || LinkPresentation.looksHighEntropy(normalized)
            }) return true
        return uri.rawQuery.orEmpty().split('&').filter { it.isNotBlank() }.any { pair ->
            val key = decode(pair.substringBefore('='))?.lowercase(Locale.ROOT)?.replace('_', '-').orEmpty()
            val value = decode(pair.substringAfter('=', "")).orEmpty()
            containsBlockedWord(key, blockedQueryKeys.mapTo(mutableSetOf()) { it.replace('_', '-') }) ||
                key.startsWith("x-amz-") || LinkPresentation.looksHighEntropy(value)
        }
    }

    private fun containsBlockedWord(value: String, blocked: Set<String>): Boolean {
        if (value in blocked) return true
        val words = value.split(Regex("[^a-z0-9]+"))
        return words.any { it in blocked }
    }

    internal fun isGlobalAddress(address: InetAddress): Boolean = when (address) {
        is Inet4Address -> isGlobalIpv4(address.address)
        is Inet6Address -> isGlobalIpv6(address.address)
        else -> false
    }

    private fun isGlobalIpv4(bytes: ByteArray): Boolean {
        val a = bytes[0].toInt() and 0xff
        val b = bytes[1].toInt() and 0xff
        val c = bytes[2].toInt() and 0xff
        return when {
            a == 0 || a == 10 || a == 127 || a >= 224 -> false
            a == 100 && b in 64..127 -> false
            a == 169 && b == 254 -> false
            a == 172 && b in 16..31 -> false
            a == 192 && b == 0 && c == 0 -> false
            a == 192 && b == 0 && c == 2 -> false
            a == 192 && b == 88 && c == 99 -> false
            a == 192 && b == 168 -> false
            a == 198 && b in 18..19 -> false
            a == 198 && b == 51 && c == 100 -> false
            a == 203 && b == 0 && c == 113 -> false
            else -> true
        }
    }

    private fun isGlobalIpv6(bytes: ByteArray): Boolean {
        val first = bytes[0].toInt() and 0xff
        val second = bytes[1].toInt() and 0xff
        if (bytes.all { it == 0.toByte() }) return false
        if (bytes.dropLast(1).all { it == 0.toByte() } && bytes.last() == 1.toByte()) return false
        if (first !in 0x20..0x3f) return false
        if (first == 0x20 && second == 0x01 && (bytes[2].toInt() and 0xff) <= 0x01) return false
        if (first == 0x20 && second == 0x01 && (bytes[2].toInt() and 0xff) == 0x02) return false
        if (first == 0x20 && second == 0x01 && (bytes[2].toInt() and 0xff) == 0x0d && (bytes[3].toInt() and 0xff) == 0xb8) return false
        if (first == 0x20 && second == 0x01 && (bytes[2].toInt() and 0xf0) == 0x10) return false
        if (first == 0x20 && second == 0x01 && (bytes[2].toInt() and 0xf0) == 0x20) return false
        if (first == 0x20 && second == 0x02) return false
        if (first == 0x3f && (second and 0xf0) == 0xf0) return false
        if (hasSensitiveIpv4Tail(bytes)) return false
        return true
    }

    private fun hasSensitiveIpv4Tail(bytes: ByteArray): Boolean {
        val a = bytes[12].toInt() and 0xff
        val b = bytes[13].toInt() and 0xff
        return when {
            a == 10 || a == 127 -> true
            a == 100 && b in 64..127 -> true
            a == 169 && b == 254 -> true
            a == 172 && b in 16..31 -> true
            a == 192 && b == 168 -> true
            else -> false
        }
    }

    private fun decode(value: String): String? = runCatching {
        URLDecoder.decode(value.replace("+", "%2B"), StandardCharsets.UTF_8.name())
    }.getOrNull()
}

object WebsiteTitleDocument {
    private val metaTag = Regex("(?is)<meta\\b[^>]*>")
    private val titleTag = Regex("(?is)<title\\b[^>]*>(.*?)</title\\s*>")
    private val attribute = Regex(
        "(?is)([A-Za-z_:][-A-Za-z0-9_:.]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'=<>`]+))"
    )

    fun extract(html: String): String? {
        var openGraph: String? = null
        var twitter: String? = null
        for (match in metaTag.findAll(html)) {
            val attributes = attribute.findAll(match.value).associate { item ->
                item.groupValues[1].lowercase(Locale.ROOT) to
                    (item.groupValues[2].ifEmpty { item.groupValues[3].ifEmpty { item.groupValues[4] } })
            }
            val key = attributes["property"]?.lowercase(Locale.ROOT)
                ?: attributes["name"]?.lowercase(Locale.ROOT)
            val content = attributes["content"]
            if (key == "og:title" && openGraph == null) openGraph = content
            if (key == "twitter:title" && twitter == null) twitter = content
        }
        return listOfNotNull(openGraph, twitter, titleTag.find(html)?.groupValues?.get(1))
            .asSequence()
            .map(::sanitize)
            .firstOrNull { it.isNotBlank() }
    }

    internal fun sanitize(value: String): String {
        val decoded = decodeEntities(value)
        return LinkVisibleText.sanitize(decoded, 200)
    }

    private fun decodeEntities(value: String): String = Regex("&(#x?[0-9A-Fa-f]+|[A-Za-z]+);").replace(value) { match ->
        val entity = match.groupValues[1]
        when {
            entity.startsWith("#x", true) -> entity.substring(2).toIntOrNull(16)?.let(::safeCodePoint) ?: match.value
            entity.startsWith('#') -> entity.substring(1).toIntOrNull()?.let(::safeCodePoint) ?: match.value
            else -> when (entity.lowercase(Locale.ROOT)) {
                "amp" -> "&"
                "apos" -> "'"
                "gt" -> ">"
                "lt" -> "<"
                "nbsp" -> " "
                "quot" -> "\""
                else -> match.value
            }
        }
    }

    private fun safeCodePoint(value: Int): String? =
        value.takeIf(Character::isValidCodePoint)?.let { String(Character.toChars(it)) }
}
