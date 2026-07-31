package me.onj.clipman

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

internal data class AndroidUpdateCandidate(
    val version: String,
    val downloadUrl: String,
    val digest: String?
)

internal object AndroidUpdateService {
    private const val RELEASES_API = "https://api.github.com/repos/OnjLouis/Clipman/releases?per_page=30"
    private const val MAX_APK_BYTES = 250L * 1024L * 1024L
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun check(currentVersion: String): AndroidUpdateCandidate? = withContext(Dispatchers.IO) {
        val candidate = readJson<List<GithubRelease>>(RELEASES_API)
            .asSequence()
            .filterNot { it.draft || it.prerelease }
            .mapNotNull { release ->
                val version = clientVersionFromTag(release.tagName) ?: return@mapNotNull null
                if (compareVersions(version, currentVersion) <= 0) return@mapNotNull null
                val expectedName = "Clipman-Android-$version.apk"
                val asset = release.assets.firstOrNull { it.name.equals(expectedName, ignoreCase = true) }
                    ?: return@mapNotNull null
                AndroidUpdateCandidate(version, asset.downloadUrl, asset.digest)
            }
            .maxWithOrNull { left, right -> compareVersions(left.version, right.version) }
            ?: return@withContext null
        val assetUrl = candidate.downloadUrl
        require(assetUrl.startsWith("https://", ignoreCase = true)) {
            "The Android update download did not use HTTPS."
        }
        candidate
    }

    suspend fun downloadAndVerify(
        context: Context,
        candidate: AndroidUpdateCandidate
    ): File = withContext(Dispatchers.IO) {
        val updateDirectory = File(context.cacheDir, "updates").apply { mkdirs() }
        updateDirectory.listFiles()?.forEach { it.delete() }
        val partial = File(updateDirectory, "Clipman-Android-${candidate.version}.apk.download")
        val target = File(updateDirectory, "Clipman-Android-${candidate.version}.apk")
        val digest = MessageDigest.getInstance("SHA-256")
        val connection = open(candidate.downloadUrl)
        try {
            val length = connection.contentLengthLong
            require(length in -1..MAX_APK_BYTES) { "The Android update is unexpectedly large." }
            connection.inputStream.use { input ->
                partial.outputStream().buffered().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        require(total <= MAX_APK_BYTES) { "The Android update is unexpectedly large." }
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                    }
                }
            }
        } catch (error: Throwable) {
            partial.delete()
            throw error
        } finally {
            connection.disconnect()
        }

        val actualDigest = digest.digest().joinToString("") { "%02x".format(it) }
        candidate.digest?.trim()?.takeIf { it.isNotEmpty() }?.let { expected ->
            require(expected.equals("sha256:$actualDigest", ignoreCase = true)) {
                "The downloaded Android update failed its SHA-256 check."
            }
        }
        require(partial.renameTo(target)) { "Could not finish the Android update download." }
        validatePackage(context, target, candidate.version)
        target
    }

    fun canInstallPackages(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || context.packageManager.canRequestPackageInstalls()

    fun unknownSourcesSettingsIntent(context: Context): Intent = Intent(
        android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
        Uri.parse("package:${context.packageName}")
    )

    fun openInstaller(context: Context, apk: File) {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", apk)
        context.startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        )
    }

    internal fun compareVersions(left: String, right: String): Int {
        fun parse(value: String): List<Int> {
            val clean = value.trim().removePrefix("v").removePrefix("V")
            require(Regex("^\\d+(?:\\.\\d+){1,3}$").matches(clean)) { "Invalid version: $value" }
            return clean.split('.').map { it.toInt() }
        }
        val leftParts = parse(left)
        val rightParts = parse(right)
        for (index in 0 until maxOf(leftParts.size, rightParts.size)) {
            val comparison = (leftParts.getOrElse(index) { 0 }).compareTo(rightParts.getOrElse(index) { 0 })
            if (comparison != 0) return comparison
        }
        return 0
    }

    internal fun clientVersionFromTag(tag: String): String? {
        val match = Regex("^[vV](\\d+(?:\\.\\d+){1,3})$").matchEntire(tag.trim()) ?: return null
        return match.groupValues[1]
    }

    private inline fun <reified T> readJson(url: String): T {
        val connection = open(url)
        try {
            return connection.inputStream.bufferedReader().use { json.decodeFromString(it.readText()) }
        } finally {
            connection.disconnect()
        }
    }

    private fun open(url: String): HttpURLConnection {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 30_000
        connection.readTimeout = 60_000
        connection.instanceFollowRedirects = true
        connection.setRequestProperty("Accept", "application/vnd.github+json")
        connection.setRequestProperty("User-Agent", "Clipman-Android/${BuildConfig.VERSION_NAME}")
        connection.connect()
        require(connection.responseCode in 200..299) {
            "The update service returned HTTP ${connection.responseCode}."
        }
        require(connection.url.protocol.equals("https", ignoreCase = true)) {
            "The update service redirected outside HTTPS."
        }
        return connection
    }

    @Suppress("DEPRECATION")
    private fun validatePackage(context: Context, apk: File, expectedVersion: String) {
        val manager = context.packageManager
        val archive = if (Build.VERSION.SDK_INT >= 33) {
            manager.getPackageArchiveInfo(apk.path, PackageManager.PackageInfoFlags.of(PackageManager.GET_SIGNING_CERTIFICATES.toLong()))
        } else {
            manager.getPackageArchiveInfo(apk.path, PackageManager.GET_SIGNING_CERTIFICATES)
        } ?: error("Android could not read the downloaded update package.")
        require(archive.packageName == context.packageName) { "The downloaded update is not Clipman." }
        require(archive.versionName == expectedVersion) { "The downloaded update has the wrong version." }

        val installed = if (Build.VERSION.SDK_INT >= 33) {
            manager.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(PackageManager.GET_SIGNING_CERTIFICATES.toLong()))
        } else {
            manager.getPackageInfo(context.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        }
        fun signerDigests(info: android.content.pm.PackageInfo): Set<String> {
            val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val signingInfo = info.signingInfo ?: return emptySet()
                if (signingInfo.hasMultipleSigners()) signingInfo.apkContentsSigners else signingInfo.signingCertificateHistory
            } else {
                info.signatures
            }
            return signatures.orEmpty().mapTo(mutableSetOf()) { signature ->
                MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
                    .joinToString("") { "%02x".format(it) }
            }
        }
        require(signerDigests(installed).intersect(signerDigests(archive)).isNotEmpty()) {
            "The downloaded update was not signed by the installed Clipman application."
        }
    }
}

@Serializable
private data class GithubRelease(
    @SerialName("tag_name") val tagName: String,
    val draft: Boolean = false,
    val prerelease: Boolean = false,
    val assets: List<GithubAsset> = emptyList()
)

@Serializable
private data class GithubAsset(
    val name: String,
    @SerialName("browser_download_url") val downloadUrl: String,
    val digest: String? = null
)
