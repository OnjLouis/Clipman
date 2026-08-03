package me.onj.clipman

import java.net.IDN
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.util.Locale

object LinkPresentation {
    private const val maxDestinationCharacters = 96

    private val genericSegments = setOf(
        "a", "article", "articles", "default", "en", "gb", "go", "home", "html", "index",
        "link", "links", "p", "page", "pages", "post", "posts", "ref", "uk", "url", "view",
        "www"
    )
    private val uuidPattern = Regex(
        "(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    )
    private val bareWebAddressPattern = Regex(
        "(?i)^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}(?::[0-9]{1,5})?(?:[/?#].*)?$"
    )

    fun rowText(entry: ClipEntry): String {
        val linkText = standaloneUrlText(entry.Text) ?: return entry.displayText
        val destination = shortenedDestination(linkText) ?: return entry.displayText
        val label = entry.Name.trim().ifBlank { offlineLabel(linkText).orEmpty() }
        return when {
            label.isBlank() -> destination
            label.equals(destination, ignoreCase = true) -> label
            else -> "$label; $destination"
        }
    }

    fun offlineLabel(value: String): String? {
        val uri = parseDisplayUri(value) ?: return null
        val host = displayHost(uri) ?: return null
        val segment = meaningfulPathLabel(uri)
        return segment ?: host
    }

    fun shortenedDestination(value: String): String? {
        val uri = parseDisplayUri(value) ?: return null
        val host = displayHost(uri) ?: return null
        val pathSegments = uri.rawPath.orEmpty()
            .split('/')
            .mapNotNull(::decodeSegment)
            .filter { it.isNotBlank() }
        if (pathSegments.isEmpty()) return host

        val full = "$host/${pathSegments.joinToString("/")}"
        if (full.length <= maxDestinationCharacters) return full

        val tail = pathSegments.takeLast(2).joinToString("/")
        val shortened = "$host/.../$tail"
        return if (shortened.length <= maxDestinationCharacters) {
            shortened
        } else {
            shortened.take(maxDestinationCharacters - 1).trimEnd('/') + "\u2026"
        }
    }

    fun searchableText(entry: ClipEntry): String = buildString {
        append(entry.Name)
        append('\n')
        append(offlineLabel(entry.Text).orEmpty())
        append('\n')
        append(entry.Text)
    }

    fun isStandaloneLink(value: String): Boolean {
        return standaloneUrlText(value) != null
    }

    fun standaloneUrlText(value: String): String? {
        if (!WebsiteTitlePolicy.isWithinUrlLength(value)) return null
        val trimmed = value.trim()
        if (trimmed.isBlank() || trimmed.contains('\n') || trimmed.contains('\r')) return null
        val candidate = Regex("""(?i)\s+link$""").find(trimmed)?.let { match ->
            trimmed.substring(0, match.range.first)
        } ?: trimmed
        if (candidate.isBlank() || candidate.any(Char::isWhitespace)) return null
        return candidate.takeIf { parseDisplayUri(it)?.host?.isNotBlank() == true }
    }

    fun isFetchableHttpUrl(value: String): Boolean {
        return runCatching { WebsiteTitlePolicy.validate(value) }.isSuccess
    }

    fun disclosureHost(value: String): String? {
        val host = parseAbsoluteUri(value)?.host?.trim('[', ']')?.trimEnd('.') ?: return null
        return runCatching {
            if (host.contains(':')) host.lowercase(Locale.ROOT) else
                IDN.toASCII(host, IDN.USE_STD3_ASCII_RULES).lowercase(Locale.ROOT)
        }.getOrNull()
    }

    private fun parseDisplayUri(value: String): URI? {
        if (!WebsiteTitlePolicy.isWithinUrlLength(value)) return null
        val trimmed = value.trim()
        if (trimmed.isBlank() || trimmed.any(Char::isWhitespace)) return null
        val normalized = when {
            trimmed.startsWith("www.", ignoreCase = true) -> "https://$trimmed"
            bareWebAddressPattern.matches(trimmed) -> "https://$trimmed"
            else -> trimmed
        }
        return parseAbsoluteUri(normalized)
    }

    private fun parseAbsoluteUri(value: String): URI? {
        if (!WebsiteTitlePolicy.isWithinUrlLength(value)) return null
        return runCatching {
            URI(value.trim()).takeIf { uri ->
                uri.isAbsolute && uri.host != null && uri.scheme.lowercase(Locale.ROOT) in setOf("http", "https", "clipman")
            }
        }.getOrNull()
    }

    private fun displayHost(uri: URI): String? = runCatching {
        LinkVisibleText.sanitize(IDN.toUnicode(uri.host))
            .lowercase(Locale.ROOT)
            .removePrefix("www.")
            .trimEnd('.')
            .takeIf { it.isNotBlank() }
    }.getOrNull()

    private fun meaningfulPathLabel(uri: URI): String? {
        val segments = uri.rawPath.orEmpty()
            .split('/')
            .mapNotNull(::decodeSegment)
            .map { stripDocumentExtension(it.trim()) }
            .filter { it.isNotBlank() }
        if (segments.isEmpty()) return null

        for (index in segments.indices.reversed()) {
            val candidate = segments[index]
            if (uuidPattern.matches(candidate) || looksHighEntropy(candidate)) continue
            if (candidate.all(Char::isDigit)) {
                val prefix = segments.getOrNull(index - 1)
                    ?.takeIf { previous ->
                        !previous.all(Char::isDigit) && !uuidPattern.matches(previous) && !looksHighEntropy(previous)
                    }
                    ?: continue
                return sentenceCase(humanize("$prefix $candidate"))
            }
            if (candidate.lowercase(Locale.ROOT) in genericSegments) continue
            return sentenceCase(humanize(candidate))
        }
        return null
    }

    private fun decodeSegment(raw: String): String? {
        if (raw.isBlank()) return null
        return runCatching {
            LinkVisibleText.sanitize(
                URLDecoder.decode(raw.replace("+", "%2B"), StandardCharsets.UTF_8.name())
            )
        }.getOrNull()
    }

    private fun stripDocumentExtension(value: String): String =
        value.replace(Regex("(?i)\\.(?:aspx?|html?|php|shtml)$"), "")

    private fun humanize(value: String): String = LinkVisibleText.sanitize(value)
        .replace(Regex("[-_]+"), " ")
        .replace(Regex("\\s+"), " ")
        .trim()

    private fun sentenceCase(value: String): String = value.replaceFirstChar { character ->
        if (character.isLowerCase()) character.titlecase(Locale.ROOT) else character.toString()
    }

    internal fun looksHighEntropy(value: String): Boolean {
        val compact = value.filter(Char::isLetterOrDigit)
        if (compact.length < 20) return false
        val classes = listOf(
            compact.any(Char::isLowerCase),
            compact.any(Char::isUpperCase),
            compact.any(Char::isDigit)
        ).count { it }
        val uniqueRatio = compact.toSet().size.toDouble() / compact.length
        return classes >= 2 && uniqueRatio >= 0.45
    }
}

internal object LinkVisibleText {
    fun sanitize(value: String, maximumCodePoints: Int = Int.MAX_VALUE): String {
        require(maximumCodePoints >= 0) { "The visible-text limit cannot be negative." }
        val safe = buildString(value.length) {
            var offset = 0
            var pendingSpace = false
            while (offset < value.length) {
                val codePoint = value.codePointAt(offset)
                val type = Character.getType(codePoint)
                val removable = type == Character.CONTROL.toInt() ||
                    type == Character.FORMAT.toInt() ||
                    type == Character.SURROGATE.toInt() ||
                    type == Character.LINE_SEPARATOR.toInt() ||
                    type == Character.PARAGRAPH_SEPARATOR.toInt() ||
                    codePoint == 0xfffd
                when {
                    removable -> Unit
                    Character.isWhitespace(codePoint) || Character.isSpaceChar(codePoint) -> {
                        pendingSpace = isNotEmpty()
                    }
                    else -> {
                        if (pendingSpace) append(' ')
                        appendCodePoint(codePoint)
                        pendingSpace = false
                    }
                }
                offset += Character.charCount(codePoint)
            }
        }.trim()
        if (safe.codePointCount(0, safe.length) <= maximumCodePoints) return safe
        return safe.substring(0, safe.offsetByCodePoints(0, maximumCodePoints)).trimEnd()
    }
}
