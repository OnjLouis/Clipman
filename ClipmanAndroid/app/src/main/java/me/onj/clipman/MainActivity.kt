package me.onj.clipman

import android.Manifest
import android.content.Context
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.view.View
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

class MainActivity : FragmentActivity() {
    private var isUnlocked by mutableStateOf(false)
    private var appIsForeground by mutableStateOf(false)
    private var unlockMessage by mutableStateOf("Clipman is locked.")
    private var unlockPromptShowing = false
    private var trustedExternalActivityPending = false
    private var externalConnectionImport by mutableStateOf<ExternalServerConnectionImport?>(null)
    private var nextExternalConnectionImportId = 0L
    private var externalImageImports by mutableStateOf<List<ExternalSharedImageImport>>(emptyList())
    private var nextExternalImageImportId = 0L
    private var externalTextImports by mutableStateOf<List<ExternalSharedTextImport>>(emptyList())
    private var nextExternalTextImportId = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIncomingIntent(intent)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    if (isUnlocked) {
                        ClipmanApp(
                            appIsForeground = appIsForeground,
                            externalConnectionImport = externalConnectionImport,
                            onExternalConnectionImportConsumed = { id ->
                                if (externalConnectionImport?.id == id) externalConnectionImport = null
                            },
                            externalImageImport = externalImageImports.firstOrNull(),
                            onExternalImageImportConsumed = { id ->
                                externalImageImports = externalImageImports.filterNot { it.id == id }
                            },
                            externalTextImport = externalTextImports.firstOrNull(),
                            onExternalTextImportConsumed = { id ->
                                externalTextImports = externalTextImports.filterNot { it.id == id }
                            }
                        )
                    } else {
                        LockedScreen(
                            message = unlockMessage
                        )
                    }
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        appIsForeground = true
        if (trustedExternalActivityPending) {
            trustedExternalActivityPending = false
            unlockPromptShowing = false
            isUnlocked = true
            unlockMessage = "Clipman is unlocked."
            return
        }
        if (AndroidSettings(this).requireAuthentication) {
            requestUnlock()
        } else {
            unlockPromptShowing = false
            isUnlocked = true
            unlockMessage = "Clipman is unlocked."
        }
    }

    override fun onStop() {
        appIsForeground = false
        super.onStop()
        if (!trustedExternalActivityPending && !isChangingConfigurations && AndroidSettings(this).requireAuthentication) {
            isUnlocked = false
            unlockMessage = "Clipman is locked."
        }
    }

    fun beginTrustedExternalActivity() {
        trustedExternalActivityPending = true
    }

    fun cancelTrustedExternalActivity() {
        trustedExternalActivityPending = false
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingIntent(intent)
    }

    private fun handleIncomingIntent(intent: Intent?) {
        if (intent == null) return
        when {
            intent.action == Intent.ACTION_SEND && intent.type?.startsWith("text/", ignoreCase = true) == true ->
                enqueueSharedText(intent)
            intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE ->
                enqueueSharedImage(intent)
            else -> handleConfigurationIntent(intent)
        }
    }

    private fun enqueueSharedText(intent: Intent) {
        val requestId = ++nextExternalTextImportId
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString().orEmpty()
        val html = intent.getStringExtra(Intent.EXTRA_HTML_TEXT).orEmpty()
        val rejection = AndroidTextSharePolicy.rejectionMessage(intent.action, intent.type, text)
        externalTextImports = externalTextImports + if (rejection == null) {
            ExternalSharedTextImport(requestId, text = text, html = html)
        } else {
            ExternalSharedTextImport(requestId, errorMessage = rejection)
        }
        if (AndroidSettings(this).requireAuthentication) {
            unlockMessage = "Unlock Clipman to add the shared text."
        }
    }

    private fun enqueueSharedImage(intent: Intent) {
        val requestId = ++nextExternalImageImportId
        val sharedStreams = runCatching { sharedImageStreams(intent) }.getOrElse {
            externalImageImports = externalImageImports + ExternalSharedImageImport(
                requestId,
                errorMessage = "The shared photo details could not be read safely."
            )
            return
        }
        val rejection = AndroidImageSharePolicy.rejectionMessage(intent.action, intent.type, sharedStreams.itemCount)
        if (rejection != null) {
            externalImageImports = externalImageImports + ExternalSharedImageImport(requestId, errorMessage = rejection)
            return
        }
        val uri = sharedStreams.uris.singleOrNull()
        if (uri == null) {
            externalImageImports = externalImageImports + ExternalSharedImageImport(
                requestId,
                errorMessage = "The shared photo does not contain readable image data."
            )
            return
        }
        externalImageImports = externalImageImports + ExternalSharedImageImport(requestId, isReading = true)
        if (AndroidSettings(this).requireAuthentication) {
            unlockMessage = "Unlock Clipman to add the shared photo."
        }
        lifecycleScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { AndroidImageClipboard.readSharedImage(this@MainActivity, uri) }
            }
            val completed = result.fold(
                onSuccess = { ExternalSharedImageImport(requestId, image = it) },
                onFailure = {
                    ExternalSharedImageImport(
                        requestId,
                        errorMessage = it.message ?: "The shared photo could not be added."
                    )
                }
            )
            externalImageImports = externalImageImports.map { if (it.id == requestId) completed else it }
        }
    }

    @Suppress("DEPRECATION")
    private fun sharedImageStreams(intent: Intent): SharedImageStreams {
        val candidates = mutableListOf<Uri>()
        var extraItemCount = 0
        when (val stream = intent.extras?.get(Intent.EXTRA_STREAM)) {
            is Uri -> {
                candidates += stream
                extraItemCount = 1
            }
            is List<*> -> {
                candidates += stream.filterIsInstance<Uri>()
                extraItemCount = stream.size
            }
        }
        val clipItemCount = intent.clipData?.itemCount ?: 0
        intent.clipData?.let { clip ->
            repeat(clip.itemCount) { index -> clip.getItemAt(index).uri?.let(candidates::add) }
        }
        intent.data?.let(candidates::add)
        val distinctUris = candidates.distinctBy(Uri::toString)
        return SharedImageStreams(
            uris = distinctUris,
            itemCount = maxOf(extraItemCount, clipItemCount, if (intent.data != null) 1 else 0, distinctUris.size)
        )
    }

    private data class SharedImageStreams(val uris: List<Uri>, val itemCount: Int)

    private fun handleConfigurationIntent(intent: Intent?) {
        if (intent == null) return
        if (intent.action == Intent.ACTION_VIEW && intent.data != null) {
            importServerConnection(intent.data!!)
            return
        }
        val serverUrl = intent.getStringExtra("serverUrl") ?: intent.getStringExtra("clipmanServerUrl")
        val serverToken = intent.getStringExtra("serverToken") ?: intent.getStringExtra("clipmanServerToken")
        if (serverUrl.isNullOrBlank() && serverToken.isNullOrBlank()) return
        val settings = AndroidSettings(this)
        if (!serverUrl.isNullOrBlank()) settings.serverUrl = serverUrl
        if (!serverToken.isNullOrBlank()) settings.serverToken = serverToken
    }

    private fun importServerConnection(uri: Uri) {
        val requestId = ++nextExternalConnectionImportId
        lifecycleScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readLimitedText(65_536) }
                        ?: error("The selected file could not be read.")
                }.mapCatching(ServerConnectionConfig::parse)
            }
            externalConnectionImport = result.fold(
                onSuccess = { ExternalServerConnectionImport(requestId, details = it) },
                onFailure = {
                    ExternalServerConnectionImport(
                        requestId,
                        errorMessage = it.message ?: it::class.java.simpleName
                    )
                }
            )
        }
    }

    private fun requestUnlock() {
        if (isUnlocked || unlockPromptShowing) return
        if (!AndroidSettings(this).requireAuthentication) {
            isUnlocked = true
            unlockMessage = "Clipman is unlocked."
            return
        }
        val authenticators = BiometricManager.Authenticators.BIOMETRIC_STRONG or
            BiometricManager.Authenticators.DEVICE_CREDENTIAL
        val manager = BiometricManager.from(this)
        when (manager.canAuthenticate(authenticators)) {
            BiometricManager.BIOMETRIC_SUCCESS -> showUnlockPrompt(authenticators)
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> {
                unlockMessage = "Clipman is locked. Set up fingerprint, face unlock, PIN, pattern, or password on this phone to unlock Clipman."
            }
            BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE,
            BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> {
                unlockMessage = "Clipman cannot use biometric or device unlock on this phone."
            }
            else -> {
                unlockMessage = "Clipman cannot unlock right now. Try again."
            }
        }
    }

    private fun showUnlockPrompt(authenticators: Int) {
        unlockPromptShowing = true
        val prompt = BiometricPrompt(
            this,
            ContextCompat.getMainExecutor(this),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    unlockPromptShowing = false
                    isUnlocked = true
                    unlockMessage = "Clipman is unlocked."
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    unlockPromptShowing = false
                    unlockMessage = "Clipman is locked. $errString"
                }

                override fun onAuthenticationFailed() {
                    unlockMessage = "Unlock failed. Try again."
                }
            }
        )
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Unlock Clipman")
            .setSubtitle("Unlock clipboard history")
            .setAllowedAuthenticators(authenticators)
            .build()
        prompt.authenticate(info)
    }
}

@Composable
private fun LockedScreen(
    message: String
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Text(
            text = "Clipman Locked",
            style = MaterialTheme.typography.headlineMedium,
            modifier = Modifier.semantics { heading() }
        )
        Text(message)
    }
}

private enum class HistorySection(val label: String) {
    Text("Text"),
    RichText("Rich Text"),
    Links("Links")
}

private enum class HistoryFilterKind { Group, Device }

private data class MobileSettingsSnapshot(
    val storageMode: MobileStorageMode,
    val serverUrl: String,
    val token: String,
    val serverCaCertPem: String,
    val serverCaHost: String,
    val password: String,
    val deviceName: String,
    val copyRemoteToClipboard: Boolean,
    val addClipboardOnLaunch: Boolean,
    val historySort: HistorySort,
    val richTextEnabled: Boolean,
    val richTextImagesEnabled: Boolean,
    val confirmDeletions: Boolean,
    val requireAuthentication: Boolean,
    val checkForUpdatesAutomatically: Boolean,
    val playSounds: Boolean,
    val useHaptics: Boolean,
    val cloudBackupEnabled: Boolean,
    val cloudBackupTreeUri: String,
    val cloudBackupLocationName: String
)

private data class ExternalServerConnectionImport(
    val id: Long,
    val details: ServerConnectionDetails? = null,
    val errorMessage: String = ""
)

private class LocalHistoryWriteException(
    cause: Throwable,
    val reloadedDatabase: ClipDatabase?
) : Exception(cause.message, cause)

internal fun recoverHistoryAfterLocalWriteFailure(
    previousDatabase: ClipDatabase,
    reloadedDatabase: ClipDatabase?
): ClipDatabase = reloadedDatabase ?: previousDatabase

internal fun localHistoryWriteFailureStatus(actionText: String, error: Throwable): String =
    "$actionText could not be saved. History was restored: ${error.message ?: error::class.java.simpleName}"

internal fun remoteHistoryWriteFailureStatus(actionText: String, error: Throwable): String =
    "$actionText saved locally; server sync is pending: ${error.message ?: error::class.java.simpleName}"

@Composable
@OptIn(ExperimentalFoundationApi::class)
private fun ClipmanApp(
    appIsForeground: Boolean,
    externalConnectionImport: ExternalServerConnectionImport?,
    onExternalConnectionImportConsumed: (Long) -> Unit,
    externalImageImport: ExternalSharedImageImport?,
    onExternalImageImportConsumed: (Long) -> Unit,
    externalTextImport: ExternalSharedTextImport?,
    onExternalTextImportConsumed: (Long) -> Unit
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val activity = context as? MainActivity
    val view = androidx.compose.ui.platform.LocalView.current
    val settings = remember { AndroidSettings(context) }
    val historyRepository = remember { MobileHistoryRepository(context) }
    val storageMutex = remember { Mutex() }
    val scope = rememberCoroutineScope()
    val textListState = rememberLazyListState()
    val richTextListState = rememberLazyListState()
    val linksListState = rememberLazyListState()
    var serverUrl by remember { mutableStateOf(settings.serverUrl) }
    var storageMode by remember { mutableStateOf(settings.storageMode) }
    var token by remember { mutableStateOf(settings.serverToken) }
    var serverCaCertPem by remember { mutableStateOf(settings.serverCaCertPem) }
    var serverCaHost by remember { mutableStateOf(settings.serverCaHost) }
    var password by remember { mutableStateOf(settings.historyPassword) }
    var deviceName by remember { mutableStateOf(settings.deviceName) }
    var showPassword by remember { mutableStateOf(false) }
    var showConnectionSettings by remember {
        mutableStateOf(storageMode == MobileStorageMode.Server && (serverUrl.isBlank() || token.isBlank()))
    }
    var copyRemoteToClipboard by remember { mutableStateOf(settings.copyRemoteToClipboard) }
    var addClipboardOnLaunch by remember { mutableStateOf(settings.addClipboardOnLaunch) }
    var richTextEnabled by remember { mutableStateOf(settings.richTextEnabled) }
    var richTextImagesEnabled by remember { mutableStateOf(settings.richTextImagesEnabled) }
    var confirmDeletions by remember { mutableStateOf(settings.confirmDeletions) }
    var requireAuthentication by remember { mutableStateOf(settings.requireAuthentication) }
    var checkForUpdatesAutomatically by remember { mutableStateOf(settings.checkForUpdatesAutomatically) }
    var playSounds by remember { mutableStateOf(settings.playSounds) }
    var useHaptics by remember { mutableStateOf(settings.useHaptics) }
    var cloudBackupEnabled by remember { mutableStateOf(settings.cloudBackupEnabled) }
    var cloudBackupTreeUri by remember { mutableStateOf(settings.cloudBackupTreeUri) }
    var cloudBackupLocationName by remember { mutableStateOf(settings.cloudBackupLocationName) }
    var status by remember { mutableStateOf("Not loaded.") }
    var steadyStatus by remember { mutableStateOf("Ready.") }
    var transientStatusActive by remember { mutableStateOf(false) }
    var statusSequence by remember { mutableStateOf(0L) }
    var search by remember { mutableStateOf("") }
    var section by remember { mutableStateOf(HistorySection.Text) }
    val visibleSections = remember(richTextEnabled) { visibleHistorySections(richTextEnabled) }
    val pagerState = rememberPagerState(pageCount = { visibleSections.size })
    var sortMode by remember { mutableStateOf(settings.historySort) }
    var groupFilter by remember { mutableStateOf("") }
    var deviceFilter by remember { mutableStateOf("") }
    var historyFilterKind by remember { mutableStateOf(HistoryFilterKind.Group) }
    var entries by remember { mutableStateOf<List<ClipEntry>>(emptyList()) }
    var database by remember { mutableStateOf(ClipDatabase()) }
    var viewingEntry by remember { mutableStateOf<ClipEntry?>(null) }
    var editingEntry by remember { mutableStateOf<ClipEntry?>(null) }
    var deleteCandidate by remember { mutableStateOf<ClipEntry?>(null) }
    var showGroupPicker by remember { mutableStateOf(false) }
    var attemptedInitialLoad by remember { mutableStateOf(false) }
    var currentRevision by remember { mutableStateOf("") }
    var isLoadingHistory by remember { mutableStateOf(false) }
    var isSavingHistory by remember { mutableStateOf(false) }
    var announcedFirstPage by remember { mutableStateOf(false) }
    var launchClipboardHandled by remember { mutableStateOf(false) }
    var addClipboardAfterLoad by remember { mutableStateOf(false) }
    var hasLoadedHistory by remember { mutableStateOf(false) }
    var hasPendingLocalChanges by remember { mutableStateOf(false) }
    var pollingFailureCount by remember { mutableStateOf(0) }
    var loadGeneration by remember { mutableStateOf(0L) }
    var changeGeneration by remember { mutableStateOf(0L) }
    var isSavingSettings by remember { mutableStateOf(false) }
    var isCheckingForUpdate by remember { mutableStateOf(false) }
    var isDownloadingUpdate by remember { mutableStateOf(false) }
    var updateStatus by remember { mutableStateOf("") }
    var updateCandidate by remember { mutableStateOf<AndroidUpdateCandidate?>(null) }
    var pendingUpdateApk by remember { mutableStateOf<File?>(null) }
    var pendingConnectionExport by remember { mutableStateOf<String?>(null) }
    var showConnectionExportWarning by remember { mutableStateOf(false) }
    var pendingServerAuthority by remember { mutableStateOf<ServerCertificateAuthority?>(null) }
    var enableBackupAfterFolderChoice by remember { mutableStateOf(false) }
    var websiteTitleCandidate by remember { mutableStateOf<ClipEntry?>(null) }
    var isFetchingWebsiteTitle by remember { mutableStateOf(false) }
    var approvedPhotoSave by remember { mutableStateOf<Pair<ClipEntry, EmbeddedImageData>?>(null) }
    var pendingLegacyPhotoSave by remember { mutableStateOf<Pair<ClipEntry, EmbeddedImageData>?>(null) }

    fun setTransientStatus(message: String) {
        statusSequence += 1
        val sequence = statusSequence
        transientStatusActive = true
        status = message
        scope.launch {
            delay(10_000)
            if (statusSequence == sequence) {
                transientStatusActive = false
                status = steadyStatus
            }
        }
    }

    fun setSteadyStatus(message: String, revealImmediately: Boolean = true) {
        steadyStatus = message
        if (revealImmediately || !transientStatusActive) {
            statusSequence += 1
            transientStatusActive = false
            status = message
        }
    }

    fun reportImageAction(message: String, succeeded: Boolean) {
        setTransientStatus(message)
        announce(view, message)
        playFeedback(
            context,
            if (succeeded) ClipmanSound.Copy else ClipmanSound.Skip,
            playSounds,
            useHaptics
        )
    }

    val legacyPhotoPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        val pending = pendingLegacyPhotoSave
        pendingLegacyPhotoSave = null
        if (granted && pending != null) {
            approvedPhotoSave = pending
        } else if (!granted) {
            reportImageAction("Clipman needs photo storage permission to save this image.", false)
        }
    }

    LaunchedEffect(approvedPhotoSave) {
        val request = approvedPhotoSave ?: return@LaunchedEffect
        val (entry, image) = request
        runCatching {
            withContext(Dispatchers.IO) {
                AndroidImageEntryActions.saveToPhotos(
                    context.applicationContext,
                    image,
                    entry.SourceMachine,
                    entry.CreatedUnixMs
                )
            }
        }.onSuccess { saved ->
            reportImageAction("Saved image to Photos as ${saved.displayName}.", true)
        }.onFailure { error ->
            reportImageAction("Could not save image to Photos: ${error.message ?: error::class.java.simpleName}", false)
        }
        if (approvedPhotoSave == request) approvedPhotoSave = null
    }

    fun applyHistorySort(value: HistorySort) {
        sortMode = value
        settings.historySort = value
        setTransientStatus("Sort set to ${value.label}.")
    }

    fun launchTrustedExternalActivity(action: () -> Unit) {
        activity?.beginTrustedExternalActivity()
        try {
            action()
        } catch (error: Throwable) {
            activity?.cancelTrustedExternalActivity()
            throw error
        }
    }

    val unknownSourcesLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        val apk = pendingUpdateApk
        if (apk != null && AndroidUpdateService.canInstallPackages(context)) {
            pendingUpdateApk = null
            runCatching { AndroidUpdateService.openInstaller(context, apk) }
                .onFailure { updateStatus = "Could not open the Android installer: ${it.message ?: it::class.java.simpleName}" }
        } else if (apk != null) {
            updateStatus = "Allow Clipman to install unknown apps, then choose Check Now again."
        }
    }
    val importServerConnection = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            runCatching {
                context.contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readLimitedText(65_536) }
                    ?: error("The selected file could not be read.")
            }.mapCatching(ServerConnectionConfig::parse)
                .onSuccess { details ->
                    storageMode = MobileStorageMode.Server
                    serverUrl = details.address
                    token = details.token
                    if (details.authority != null) {
                        serverCaCertPem = details.authority.pem
                        serverCaHost = details.authority.host
                    } else if (runCatching { ServerConnectionConfig.parseAuthority(serverCaCertPem, details.address) }.getOrNull() == null) {
                        serverCaCertPem = ""
                        serverCaHost = ""
                    }
                    status = "Server connection imported. Review it, then choose Save."
                    announce(view, status)
                }
                .onFailure { error ->
                    status = "Could not import server connection: ${error.message ?: error::class.java.simpleName}"
                    announce(view, status)
                }
        }
    }
    val importServerAuthority = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            runCatching {
                val pem = context.contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readLimitedText(32 * 1024) }
                    ?: error("The selected certificate could not be read.")
                ServerConnectionConfig.parseAuthority(pem, serverUrl)
                    ?: error("The selected file does not contain a certificate authority.")
            }.onSuccess { authority ->
                pendingServerAuthority = authority
            }.onFailure { error ->
                status = "Could not import private authority: ${error.message ?: error::class.java.simpleName}"
                announce(view, status)
            }
        }
    }
    val exportServerConnection = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/json")
    ) { uri ->
        val content = pendingConnectionExport
        pendingConnectionExport = null
        if (uri != null && content != null) {
            runCatching {
                context.contentResolver.openOutputStream(uri, "wt")?.bufferedWriter()?.use { it.write(content) }
                    ?: error("The selected file could not be written.")
            }.onSuccess {
                status = "Server connection file exported."
                announce(view, status)
            }.onFailure { error ->
                status = "Could not export server connection: ${error.message ?: error::class.java.simpleName}"
                announce(view, status)
            }
        }
    }
    val chooseBackupFolder = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        val shouldEnable = enableBackupAfterFolderChoice
        enableBackupAfterFolderChoice = false
        if (uri != null) {
            runCatching {
                context.contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
                cloudBackupTreeUri = uri.toString()
                cloudBackupLocationName = CloudHistoryBackup.locationName(context, uri)
                if (shouldEnable) cloudBackupEnabled = true
                status = "History backup folder selected. Choose Save to apply it."
                announce(view, status)
            }.onFailure { error ->
                status = "Could not use the selected backup folder: ${error.message ?: error::class.java.simpleName}"
                announce(view, status)
            }
        }
    }
    LaunchedEffect(externalConnectionImport?.id) {
        val request = externalConnectionImport ?: return@LaunchedEffect
        val details = request.details
        if (details != null) {
            storageMode = MobileStorageMode.Server
            serverUrl = details.address
            token = details.token
            if (details.authority != null) {
                serverCaCertPem = details.authority.pem
                serverCaHost = details.authority.host
            } else if (runCatching { ServerConnectionConfig.parseAuthority(serverCaCertPem, details.address) }.getOrNull() == null) {
                serverCaCertPem = ""
                serverCaHost = ""
            }
            showConnectionSettings = true
            status = "Server connection imported. Review it, then choose Save."
        } else {
            status = "Could not import server connection: ${request.errorMessage}"
        }
        announce(view, status)
        onExternalConnectionImportConsumed(request.id)
    }

    fun releaseBackupFolderPermission(uriValue: String) {
        if (uriValue.isBlank()) return
        runCatching {
            context.contentResolver.releasePersistableUriPermission(
                Uri.parse(uriValue),
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        }
    }

    fun discardSettingsChanges() {
        if (cloudBackupTreeUri.isNotBlank() && cloudBackupTreeUri != settings.cloudBackupTreeUri) {
            releaseBackupFolderPermission(cloudBackupTreeUri)
        }
        serverUrl = settings.serverUrl
        storageMode = settings.storageMode
        token = settings.serverToken
        serverCaCertPem = settings.serverCaCertPem
        serverCaHost = settings.serverCaHost
        password = settings.historyPassword
        deviceName = settings.deviceName
        copyRemoteToClipboard = settings.copyRemoteToClipboard
        addClipboardOnLaunch = settings.addClipboardOnLaunch
        sortMode = settings.historySort
        richTextEnabled = settings.richTextEnabled
        richTextImagesEnabled = settings.richTextImagesEnabled
        confirmDeletions = settings.confirmDeletions
        requireAuthentication = settings.requireAuthentication
        checkForUpdatesAutomatically = settings.checkForUpdatesAutomatically
        playSounds = settings.playSounds
        useHaptics = settings.useHaptics
        cloudBackupEnabled = settings.cloudBackupEnabled
        cloudBackupTreeUri = settings.cloudBackupTreeUri
        cloudBackupLocationName = settings.cloudBackupLocationName
        showConnectionSettings = false
    }

    BackHandler(enabled = showConnectionSettings && !isSavingSettings) {
        discardSettingsChanges()
    }

    fun saveSettings(snapshot: MobileSettingsSnapshot) {
        settings.serverUrl = snapshot.serverUrl
        settings.storageMode = snapshot.storageMode
        settings.serverToken = snapshot.token
        settings.serverCaCertPem = snapshot.serverCaCertPem
        settings.serverCaHost = snapshot.serverCaHost
        settings.historyPassword = snapshot.password
        settings.deviceName = snapshot.deviceName
        settings.copyRemoteToClipboard = snapshot.copyRemoteToClipboard
        settings.addClipboardOnLaunch = snapshot.addClipboardOnLaunch
        settings.historySort = snapshot.historySort
        settings.richTextEnabled = snapshot.richTextEnabled
        settings.richTextImagesEnabled = snapshot.richTextImagesEnabled
        settings.confirmDeletions = snapshot.confirmDeletions
        settings.requireAuthentication = snapshot.requireAuthentication
        settings.checkForUpdatesAutomatically = snapshot.checkForUpdatesAutomatically
        settings.playSounds = snapshot.playSounds
        settings.useHaptics = snapshot.useHaptics
        settings.cloudBackupEnabled = snapshot.cloudBackupEnabled
        settings.cloudBackupTreeUri = snapshot.cloudBackupTreeUri
        settings.cloudBackupLocationName = snapshot.cloudBackupLocationName
    }

    fun backupOptions(enabled: Boolean = cloudBackupEnabled, treeUri: String = cloudBackupTreeUri) =
        CloudBackupOptions(enabled = enabled, treeUri = treeUri)

    fun loadHistory(
        announceResult: Boolean = true,
        checkRevisionFirst: Boolean = false
    ) {
        if (storageMode == MobileStorageMode.Server && (serverUrl.isBlank() || token.isBlank())) {
            status = "Server address and token are required before loading history."
            showConnectionSettings = true
            return
        }
        if (isLoadingHistory || isSavingHistory) return
        val generation = loadGeneration + 1
        loadGeneration = generation
        val requestedMode = storageMode
        val requestedServerUrl = serverUrl
        val requestedToken = token
        val requestedCaCertPem = serverCaCertPem
        val requestedCaHost = serverCaHost
        val requestedPassword = password
        val databaseSnapshot = database
        val requestedRevision = currentRevision
        val requestedPendingChanges = hasPendingLocalChanges
        val requestedBackup = backupOptions()
        isLoadingHistory = true
        if (announceResult) {
            status = "Loading history..."
            announce(view, "Loading history")
        }
        scope.launch {
            val oldEntries = entries
            var currentForSync = databaseSnapshot
            var localCacheIsCurrent = false
            if (requestedMode == MobileStorageMode.Server && !hasLoadedHistory) {
                val cachedPreview = withContext(Dispatchers.IO) {
                    storageMutex.withLock {
                        runCatching { historyRepository.loadLocalOrNull(requestedPassword) }.getOrNull()
                    }
                }
                if (generation != loadGeneration) {
                    isLoadingHistory = false
                    return@launch
                }
                if (cachedPreview != null) {
                    currentForSync = cachedPreview
                    localCacheIsCurrent = true
                    database = cachedPreview
                    entries = cachedPreview.Entries
                    hasLoadedHistory = true
                    status = "Cached history loaded; refreshing Clipman Server."
                }
            }
            val result = withContext(Dispatchers.IO) {
                storageMutex.withLock {
                    runCatching {
                        if (requestedMode == MobileStorageMode.Local) {
                            MobileSyncResult(historyRepository.loadLocal(requestedPassword), "", false)
                        } else {
                            try {
                                if (checkRevisionFirst && requestedRevision.isNotBlank() && !requestedPendingChanges) {
                                    val metadata = ServerStorageClient(requestedServerUrl, requestedToken, requestedPassword, requestedCaCertPem, requestedCaHost).metadata()
                                    if (metadata == requestedRevision) {
                                        return@runCatching MobileSyncResult(databaseSnapshot, requestedRevision, false)
                                    }
                                }
                                historyRepository.synchronize(
                                    requestedServerUrl,
                                    requestedToken,
                                    requestedPassword,
                                    requestedCaCertPem,
                                    requestedCaHost,
                                    currentForSync,
                                    requestedBackup,
                                    localAlreadySaved = localCacheIsCurrent
                                )
                            } catch (error: Throwable) {
                                val cached = historyRepository.loadLocalOrNull(requestedPassword) ?: throw error
                                MobileSyncResult(
                                    database = cached,
                                    revision = requestedRevision,
                                    uploaded = false,
                                    pendingError = error.message ?: error::class.java.simpleName
                                )
                            }
                        }
                    }
                }
            }
            if (generation != loadGeneration) return@launch
            isLoadingHistory = false
            result.onSuccess { sync ->
                if (sync.pendingError == null) {
                    pollingFailureCount = 0
                    hasPendingLocalChanges = false
                    setSteadyStatus(
                        if (storageMode == MobileStorageMode.Local) "Ready. Using local history."
                        else "Ready. Server sync connected.",
                        revealImmediately = false
                    )
                } else {
                    pollingFailureCount = minOf(pollingFailureCount + 1, 4)
                    setSteadyStatus("Using local history; server sync is pending: ${sync.pendingError}")
                }
                val loadedDatabase = sync.database
                if (storageMode == MobileStorageMode.Local || sync.revision != currentRevision || entries.isEmpty() || !SyncConflictResolver.hasSameContent(database, loadedDatabase)) {
                    currentRevision = sync.revision
                    database = loadedDatabase
                    entries = loadedDatabase.Entries
                    hasLoadedHistory = true
                    val remoteSource = handleRemoteAdditions(
                        context = context,
                        oldEntries = oldEntries,
                        newEntries = loadedDatabase.Entries,
                        enabled = storageMode == MobileStorageMode.Server && !announceResult,
                        localMachine = deviceName.ifBlank { AndroidSettings.defaultDeviceName() },
                        shouldCopyToClipboard = copyRemoteToClipboard,
                        richTextEnabled = richTextEnabled,
                        playSounds = playSounds,
                        useHaptics = useHaptics
                    )
                    if (remoteSource != null) {
                        setTransientStatus("Clipboard updated by $remoteSource.")
                    }
                }
                if (sync.backupError != null) {
                    setSteadyStatus("History loaded, but cloud backup failed: ${sync.backupError}")
                }
                if (announceResult) announce(view, "History refreshed")
                if (!launchClipboardHandled) {
                    launchClipboardHandled = true
                    addClipboardAfterLoad = addClipboardOnLaunch
                }
            }.onFailure { error ->
                pollingFailureCount = minOf(pollingFailureCount + 1, 4)
                setSteadyStatus("Could not load history: ${error.message ?: error::class.java.simpleName}")
                if (announceResult && storageMode == MobileStorageMode.Server && !hasLoadedHistory) showConnectionSettings = true
                if (announceResult) announce(view, "Could not load history")
            }
        }
    }

    fun saveDatabaseChange(
        actionText: String,
        completionStatus: String = "$actionText complete.",
        playCopyFeedback: Boolean = actionText.startsWith("Adding Android clipboard"),
        mutation: (ClipDatabase) -> ClipDatabase
    ) {
        loadGeneration += 1
        isLoadingHistory = false
        val generation = changeGeneration + 1
        changeGeneration = generation
        isSavingHistory = true
        val previousDatabase = database
        val previousPendingLocalChanges = hasPendingLocalChanges
        val requestedMode = storageMode
        val requestedServerUrl = serverUrl
        val requestedToken = token
        val requestedCaCertPem = serverCaCertPem
        val requestedCaHost = serverCaHost
        val requestedPassword = password
        val requestedBackup = backupOptions()
        val requestedRevision = currentRevision
        val updatedLocal = mutation(database)
        database = updatedLocal
        entries = updatedLocal.Entries
        hasLoadedHistory = true
        if (requestedMode == MobileStorageMode.Server) hasPendingLocalChanges = true
        setSteadyStatus(
            if (requestedMode == MobileStorageMode.Server) "$actionText; server sync in progress."
            else "Saving change."
        )
        if (playCopyFeedback) {
            playFeedback(context, ClipmanSound.Copy, playSounds, useHaptics)
        }
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                storageMutex.withLock {
                    runCatching {
                        if (requestedMode == MobileStorageMode.Local) {
                            val backupError = try {
                                historyRepository.saveLocal(updatedLocal, requestedPassword, requestedBackup)
                            } catch (error: Exception) {
                                val reloaded = try {
                                    historyRepository.loadLocalOrNull(requestedPassword)
                                } catch (_: Exception) {
                                    null
                                }
                                throw LocalHistoryWriteException(error, reloaded)
                            }
                            MobileSyncResult(updatedLocal, "", false, backupError = backupError)
                        } else {
                            historyRepository.persistMutation(
                                serverUrl = requestedServerUrl,
                                token = requestedToken,
                                password = requestedPassword,
                                serverCaCertPem = requestedCaCertPem,
                                serverCaHost = requestedCaHost,
                                current = updatedLocal,
                                expectedRevision = requestedRevision,
                                backupOptions = requestedBackup
                            )
                        }
                    }
                }
            }
            if (generation != changeGeneration) return@launch
            isSavingHistory = false
            result.onSuccess { sync ->
                database = sync.database
                entries = sync.database.Entries
                currentRevision = sync.revision
                hasPendingLocalChanges = false
                pollingFailureCount = 0
                val completed = if (requestedMode == MobileStorageMode.Server) {
                    "${completionStatus.trim().trimEnd('.')} and synced with Clipman Server."
                } else {
                    completionStatus
                }
                if (sync.backupError != null) {
                    setSteadyStatus("${completed.trimEnd('.')} but cloud backup failed: ${sync.backupError}")
                } else {
                    setTransientStatus(completed)
                    setSteadyStatus(
                        if (requestedMode == MobileStorageMode.Server) "Ready. Server sync connected."
                        else "Ready. Using local history.",
                        revealImmediately = false
                    )
                }
            }.onFailure { error ->
                if (error is LocalHistoryWriteException) {
                    val restored = recoverHistoryAfterLocalWriteFailure(previousDatabase, error.reloadedDatabase)
                    database = restored
                    entries = restored.Entries
                    hasLoadedHistory = true
                    hasPendingLocalChanges = previousPendingLocalChanges
                    setSteadyStatus(localHistoryWriteFailureStatus(actionText, error.cause ?: error))
                } else if (error is MobileMutationException && !error.localSaved) {
                    val reloaded = withContext(Dispatchers.IO) {
                        runCatching { historyRepository.loadLocalOrNull(requestedPassword) }.getOrNull()
                    }
                    val restored = recoverHistoryAfterLocalWriteFailure(previousDatabase, reloaded)
                    database = restored
                    entries = restored.Entries
                    hasLoadedHistory = true
                    hasPendingLocalChanges = previousPendingLocalChanges
                    setSteadyStatus(localHistoryWriteFailureStatus(actionText, error.cause ?: error))
                } else {
                    pollingFailureCount = minOf(pollingFailureCount + 1, 4)
                    val failure = if (requestedMode == MobileStorageMode.Server) {
                        remoteHistoryWriteFailureStatus(actionText, error)
                    } else {
                        "$actionText failed: ${error.message ?: error::class.java.simpleName}"
                    }
                    setSteadyStatus(failure)
                }
            }
        }
    }

    val restoreHistoryBackup = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            if (password.isBlank()) {
                status = "Set and save a history password before restoring a cloud backup."
                announce(view, status)
            } else {
                status = "Reading encrypted history backup..."
                announce(view, status)
                scope.launch {
                    val result = withContext(Dispatchers.IO) {
                        runCatching { CloudHistoryBackup.read(context, uri, password) }
                    }
                    result.onSuccess { imported ->
                        saveDatabaseChange("Restoring history backup") { current ->
                            SyncConflictResolver.merge(target = current, source = imported)
                        }
                    }.onFailure { error ->
                        status = "Could not restore history backup: ${error.message ?: error::class.java.simpleName}"
                        announce(view, status)
                    }
                }
            }
        }
    }

    fun addCurrentClipboardText() {
        val entrySnapshot = database.Entries
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    RichTextClipboard.read(
                        context = context,
                        includeRichText = richTextEnabled,
                        includeImages = richTextImagesEnabled,
                        existingEntries = entrySnapshot,
                        forHistoryCapture = true
                    )
                }
            }
            result.onSuccess { clipboardContent ->
                val clipboardText = clipboardContent.text.trim()
                if (clipboardText.isEmpty()) {
                    setTransientStatus("The Android clipboard does not contain text or an image to add.")
                    return@onSuccess
                }
                val image = EmbeddedImageRichText.parse(clipboardContent.richText)
                if (image != null && EmbeddedImageRichText.exceedsTotalBudget(database.Entries, clipboardText, image.bytes.size)) {
                    setTransientStatus("Clipman's 8 MiB embedded-image history limit has been reached. Delete an image entry before adding another.")
                    return@onSuccess
                }
                val isImage = image != null
                saveDatabaseChange(if (isImage) "Adding Android clipboard image" else "Adding Android clipboard text") { current ->
                    SyncConflictResolver.addText(
                        current,
                        clipboardText,
                        deviceName.ifBlank { AndroidSettings.defaultDeviceName() },
                        clipboardContent.richText
                    )
                }
            }.onFailure { error ->
                setTransientStatus(error.message ?: "The Android clipboard could not be added.")
            }
        }
    }

    LaunchedEffect(
        externalImageImport?.id,
        externalImageImport?.isReading,
        externalImageImport?.image,
        externalImageImport?.errorMessage,
        hasLoadedHistory,
        isLoadingHistory,
        showConnectionSettings
    ) {
        val request = externalImageImport ?: return@LaunchedEffect
        if (request.isReading) {
            setTransientStatus("Reading shared photo...")
            return@LaunchedEffect
        }
        request.errorMessage?.let { message ->
            setTransientStatus(message)
            announce(view, message)
            onExternalImageImportConsumed(request.id)
            return@LaunchedEffect
        }
        if (!hasLoadedHistory || isLoadingHistory || showConnectionSettings) return@LaunchedEffect
        if (!richTextEnabled) {
            val message = "Enable Rich Text history before sharing photos to Clipman."
            setTransientStatus(message)
            announce(view, message)
            onExternalImageImportConsumed(request.id)
            return@LaunchedEffect
        }
        if (!richTextImagesEnabled) {
            val message = "Enable Include images in Rich Text history before sharing photos to Clipman."
            setTransientStatus(message)
            announce(view, message)
            onExternalImageImportConsumed(request.id)
            return@LaunchedEffect
        }
        val result = runCatching {
            AndroidImageClipboard.contentForPreparedImage(request.image ?: error("The shared photo could not be read."), database.Entries)
        }
        result.onSuccess { sharedContent ->
            saveDatabaseChange(
                actionText = "Adding shared photo",
                completionStatus = "Shared photo added to Rich Text history.",
                playCopyFeedback = true
            ) { current ->
                SyncConflictResolver.addText(
                    current,
                    sharedContent.text,
                    deviceName.ifBlank { AndroidSettings.defaultDeviceName() },
                    sharedContent.richText
                )
            }
        }.onFailure { error ->
            val message = error.message ?: "The shared photo could not be added."
            setTransientStatus(message)
            announce(view, message)
        }
        onExternalImageImportConsumed(request.id)
    }

    LaunchedEffect(
        externalTextImport?.id,
        hasLoadedHistory,
        isLoadingHistory,
        showConnectionSettings
    ) {
        val request = externalTextImport ?: return@LaunchedEffect
        request.errorMessage?.let { message ->
            setTransientStatus(message)
            announce(view, message)
            onExternalTextImportConsumed(request.id)
            return@LaunchedEffect
        }
        if (!hasLoadedHistory || isLoadingHistory || showConnectionSettings) return@LaunchedEffect
        val richText = if (richTextEnabled && request.html.isNotBlank()) {
            RichTextClipboard.normalize(
                RichTextPayload(HtmlFragment = request.html, PreferredFormat = "Html")
            )
        } else {
            null
        }
        saveDatabaseChange(
            actionText = "Adding shared text",
            completionStatus = "Shared text added to Clipman history.",
            playCopyFeedback = true
        ) { current ->
            SyncConflictResolver.addText(
                current,
                request.text,
                deviceName.ifBlank { AndroidSettings.defaultDeviceName() },
                richText
            )
        }
        onExternalTextImportConsumed(request.id)
    }

    fun offerWebsiteTitle(entry: ClipEntry) {
        if (entry.Name.isNotBlank() || !LinkPresentation.isFetchableHttpUrl(entry.Text)) return
        websiteTitleCandidate = entry
    }

    fun fetchWebsiteTitle(entry: ClipEntry) {
        if (isFetchingWebsiteTitle) return
        websiteTitleCandidate = null
        isFetchingWebsiteTitle = true
        setTransientStatus("Retrieving website title...")
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { WebsiteTitleFetcher.fetch(entry.Text) }
            }
            isFetchingWebsiteTitle = false
            result.onSuccess { title ->
                val currentEntry = database.Entries.firstOrNull { it.Id == entry.Id }
                if (currentEntry == null || currentEntry.Text != entry.Text || currentEntry.Name.isNotBlank()) {
                    playFeedback(context, ClipmanSound.Skip, playSounds, useHaptics)
                    setTransientStatus("The entry changed before its website title was applied.")
                    return@onSuccess
                }
                saveDatabaseChange("Using website title as entry name") { current ->
                    val latest = current.Entries.firstOrNull { it.Id == entry.Id }
                    if (latest == null || latest.Text != entry.Text || latest.Name.isNotBlank()) {
                        current
                    } else {
                        SyncConflictResolver.updateEntry(current, latest.copy(Name = title))
                    }
                }
            }.onFailure { error ->
                playFeedback(context, ClipmanSound.Skip, playSounds, useHaptics)
                setTransientStatus(error.message ?: "The website title could not be retrieved.")
            }
        }
    }

    fun installDownloadedUpdate(apk: File) {
        if (AndroidUpdateService.canInstallPackages(context)) {
            runCatching { AndroidUpdateService.openInstaller(context, apk) }
                .onFailure { updateStatus = "Could not open the Android installer: ${it.message ?: it::class.java.simpleName}" }
        } else {
            pendingUpdateApk = apk
            updateStatus = "Allow Clipman to install updates, then return to continue."
            launchTrustedExternalActivity {
                unknownSourcesLauncher.launch(AndroidUpdateService.unknownSourcesSettingsIntent(context))
            }
        }
    }

    fun checkForUpdates(userInitiated: Boolean) {
        if (isCheckingForUpdate || isDownloadingUpdate) return
        isCheckingForUpdate = true
        if (userInitiated) updateStatus = "Checking for updates..."
        scope.launch {
            runCatching { AndroidUpdateService.check(BuildConfig.VERSION_NAME) }
                .onSuccess { candidate ->
                    settings.lastUpdateCheckUnixMs = System.currentTimeMillis()
                    if (candidate == null) {
                        if (userInitiated) updateStatus = "Clipman is up to date."
                    } else {
                        updateCandidate = candidate
                        updateStatus = "Clipman ${candidate.version} is available."
                    }
                }
                .onFailure { error ->
                    if (userInitiated) {
                        updateStatus = "Could not check for updates: ${error.message ?: error::class.java.simpleName}"
                    }
                }
            isCheckingForUpdate = false
        }
    }

    fun downloadUpdate(candidate: AndroidUpdateCandidate) {
        if (isDownloadingUpdate) return
        updateCandidate = null
        isDownloadingUpdate = true
        updateStatus = "Downloading Clipman ${candidate.version}..."
        scope.launch {
            runCatching { AndroidUpdateService.downloadAndVerify(context, candidate) }
                .onSuccess { apk ->
                    updateStatus = "Clipman ${candidate.version} is ready to install."
                    installDownloadedUpdate(apk)
                }
                .onFailure { error ->
                    updateStatus = "Could not prepare the update: ${error.message ?: error::class.java.simpleName}"
                }
            isDownloadingUpdate = false
        }
    }

    LaunchedEffect(Unit) {
        val day = 24L * 60L * 60L * 1000L
        if (checkForUpdatesAutomatically && System.currentTimeMillis() - settings.lastUpdateCheckUnixMs >= day) {
            delay(3_000)
            checkForUpdates(userInitiated = false)
        }
    }

    LaunchedEffect(addClipboardAfterLoad) {
        if (addClipboardAfterLoad) {
            addClipboardAfterLoad = false
            addCurrentClipboardText()
        }
    }

    if (storageMode == MobileStorageMode.Server && serverUrl.isNotBlank() && token.isNotBlank() && entries.isEmpty() && status == "Not loaded.") {
        status = "Server details loaded. Enter the history password, then choose Load History."
    }

    LaunchedEffect(storageMode, serverUrl, token, password, showConnectionSettings, appIsForeground) {
        val ready = storageMode == MobileStorageMode.Local || (serverUrl.isNotBlank() && token.isNotBlank() && password.isNotBlank())
        if (appIsForeground && !showConnectionSettings && ready) {
            if (!attemptedInitialLoad) {
                attemptedInitialLoad = true
                loadHistory()
            } else {
                loadHistory(announceResult = false, checkRevisionFirst = true)
            }
        }
    }

    LaunchedEffect(storageMode, serverUrl, token, password, showConnectionSettings, appIsForeground, pollingFailureCount) {
        while (appIsForeground && storageMode == MobileStorageMode.Server && serverUrl.isNotBlank() && token.isNotBlank() && password.isNotBlank() && !showConnectionSettings) {
            val delaySeconds = minOf(60L, 5L * (1L shl pollingFailureCount.coerceIn(0, 3)))
            delay(delaySeconds * 1_000L)
            loadHistory(announceResult = false, checkRevisionFirst = true)
        }
    }

    val sectionEntries = remember(entries, section, richTextEnabled) {
        entries.filter { entryBelongsToSection(it, section, richTextEnabled) }
    }
    val groups = remember(entries) {
        canonicalLabels(entries) { it.Group }
    }
    val devices = remember(entries) {
        canonicalLabels(entries) { it.SourceMachine }
    }
    val visibleEntries = remember(sectionEntries, search, sortMode, historyFilterKind, groupFilter, deviceFilter) {
        filteredAndSortedEntries(sectionEntries, search, sortMode, historyFilterKind, groupFilter, deviceFilter)
    }
    val selectedListState = when (section) {
        HistorySection.Text -> textListState
        HistorySection.RichText -> richTextListState
        HistorySection.Links -> linksListState
    }

    LaunchedEffect(section, historyFilterKind, groupFilter, deviceFilter, search, sortMode) {
        if (visibleEntries.isNotEmpty()) selectedListState.scrollToItem(0)
    }

    LaunchedEffect(richTextEnabled) {
        if (section !in visibleSections) section = HistorySection.Text
    }

    LaunchedEffect(section, visibleSections) {
        val page = visibleSections.indexOf(section).coerceAtLeast(0)
        if (pagerState.currentPage != page) {
            pagerState.animateScrollToPage(page)
        }
    }

    LaunchedEffect(pagerState.currentPage, visibleSections) {
        val newSection = visibleSections.getOrNull(pagerState.currentPage) ?: HistorySection.Text
        if (section != newSection) {
            section = newSection
            if (announcedFirstPage) {
                setTransientStatus(
                    "${newSection.label} clipboard history. Page ${pagerState.currentPage + 1} of ${visibleSections.size}."
                )
            }
        } else {
            announcedFirstPage = true
        }
    }

    websiteTitleCandidate?.let { entry ->
        AlertDialog(
            onDismissRequest = { websiteTitleCandidate = null },
            title = { Text("Use Website Title as Name?") },
            text = {
                Text(
                    "Clipman will contact ${LinkPresentation.disclosureHost(entry.Text) ?: "the selected website"} " +
                        "once to read the page title. The website can see that it was contacted. Clipman sends the " +
                        "selected link request, but no cookies, credentials or other clipboard content.\n\n" +
                        "Destination: ${LinkPresentation.shortenedDestination(entry.Text) ?: entry.Text}"
                )
            },
            confirmButton = {
                TextButton(onClick = { fetchWebsiteTitle(entry) }) { Text("Retrieve Title") }
            },
            dismissButton = {
                TextButton(onClick = { websiteTitleCandidate = null }) { Text("Cancel") }
            }
        )
    }
    editingEntry?.let { entry ->
        EntryPropertiesDialog(
            entry = entry,
            onDismiss = { editingEntry = null },
            onSave = { updated ->
                editingEntry = null
                saveDatabaseChange("Saving entry") { database ->
                    SyncConflictResolver.updateEntry(database, updated)
                }
            },
            onDelete = {
                editingEntry = null
                if (confirmDeletions) {
                    deleteCandidate = entry
                } else {
                    saveDatabaseChange("Deleting entry") { database ->
                        SyncConflictResolver.deleteEntry(database, entry.Id)
                    }
                }
            }
        )
    }
    viewingEntry?.let { entry ->
        val links = extractLinks(entry.Text)
        ViewEntryDialog(
            entry = entry,
            links = links,
            onDismiss = { viewingEntry = null },
            onCopy = {
                RichTextClipboard.write(context, entry, richTextEnabled)
                playFeedback(context, ClipmanSound.Copy, playSounds, useHaptics)
                setTransientStatus("Copied selected entry to Android clipboard.")
            },
            onOpenLink = { link ->
                openLink(context, link)
            },
            onEdit = {
                viewingEntry = null
                editingEntry = entry
            },
            onUseWebsiteTitle = {
                viewingEntry = null
                offerWebsiteTitle(entry)
            }
        )
    }
    deleteCandidate?.let { entry ->
        ConfirmDeleteDialog(
            entry = entry,
            onDismiss = { deleteCandidate = null },
            onDelete = {
                deleteCandidate = null
                saveDatabaseChange("Deleting entry") { database ->
                    SyncConflictResolver.deleteEntry(database, entry.Id)
                }
            }
        )
    }
    updateCandidate?.let { candidate ->
        AlertDialog(
            onDismissRequest = { updateCandidate = null },
            title = { Text("Clipman update available") },
            text = { Text("Clipman ${candidate.version} is available. Android will ask you to approve the installation.") },
            confirmButton = {
                TextButton(onClick = { downloadUpdate(candidate) }) { Text("Download") }
            },
            dismissButton = {
                TextButton(onClick = { updateCandidate = null }) { Text("Not now") }
            }
        )
    }
    if (showGroupPicker) {
        GroupPickerDialog(
            groups = groups,
            devices = devices,
            selectedKind = historyFilterKind,
            selectedGroup = groupFilter,
            selectedDevice = deviceFilter,
            onDismiss = { showGroupPicker = false },
            onSelect = { kind, value ->
                historyFilterKind = kind
                if (kind == HistoryFilterKind.Device) {
                    deviceFilter = value
                } else {
                    groupFilter = value
                }
                showGroupPicker = false
            }
        )
    }
    if (showConnectionExportWarning) {
        AlertDialog(
            onDismissRequest = { showConnectionExportWarning = false },
            title = { Text("Export private server connection?") },
            text = { Text("This file contains the private server token. Store and share it securely, and never place it beside an exported clipboard history.") },
            confirmButton = {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = {
                        showConnectionExportWarning = false
                        runCatching { ServerConnectionConfig.create(serverUrl, token, serverCaCertPem, serverCaHost) }
                            .onSuccess { content ->
                                pendingConnectionExport = content
                                launchTrustedExternalActivity {
                                    exportServerConnection.launch("Clipman Server.clpconf")
                                }
                            }
                            .onFailure { error ->
                                status = error.message ?: "Could not prepare the server connection file."
                                announce(view, status)
                            }
                    }) { Text("Save to Files") }
                    TextButton(onClick = {
                        showConnectionExportWarning = false
                        runCatching { ServerConnectionConfig.create(serverUrl, token, serverCaCertPem, serverCaHost) }
                            .onSuccess { content ->
                                launchTrustedExternalActivity {
                                    shareServerConnection(context, content)
                                }
                            }
                            .onFailure { error ->
                                status = error.message ?: "Could not prepare the server connection file."
                                announce(view, status)
                            }
                    }) { Text("Share") }
                }
            },
            dismissButton = {
                TextButton(onClick = { showConnectionExportWarning = false }) { Text("Cancel") }
            }
        )
    }
    pendingServerAuthority?.let { authority ->
        AlertDialog(
            onDismissRequest = { pendingServerAuthority = null },
            title = { Text("Import private authority for this server?") },
            text = {
                Text(
                    "Host: ${authority.host}\n" +
                        "Subject: ${authority.subject}\n" +
                        "Expires: ${DateFormat.getDateInstance(DateFormat.LONG).format(java.util.Date(authority.expiresUnixMs))}\n" +
                        "SHA-256 fingerprint: ${authority.fingerprint}\n\n" +
                        "Clipman will trust this authority only for the displayed server host."
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    serverCaCertPem = authority.pem
                    serverCaHost = authority.host
                    pendingServerAuthority = null
                    status = "Private certificate authority imported for ${authority.host}. Choose Save to apply it."
                    announce(view, status)
                }) { Text("Import") }
            },
            dismissButton = {
                TextButton(onClick = { pendingServerAuthority = null }) { Text("Cancel") }
            }
        )
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        if (showConnectionSettings) {
            ConnectionSettingsScreen(
                isSaving = isSavingSettings,
                storageMode = storageMode,
                onStorageModeChanged = { storageMode = it },
                serverUrl = serverUrl,
                onServerUrlChanged = { serverUrl = it },
                token = token,
                onTokenChanged = { token = it },
                serverCaCertPem = serverCaCertPem,
                serverCaHost = serverCaHost,
                onRemoveServerAuthority = {
                    serverCaCertPem = ""
                    serverCaHost = ""
                },
                onPasteToken = {
                    val pasted = cleanServerToken(readClipboardText(context))
                    if (pasted.isNotBlank()) {
                        token = pasted
                        status = "Server token pasted."
                        announce(view, status)
                    } else {
                        status = "Clipboard does not contain a server token."
                        announce(view, status)
                    }
                },
                onImportServerFile = {
                    launchTrustedExternalActivity {
                        importServerConnection.launch(arrayOf("*/*"))
                    }
                },
                onExportServerFile = { showConnectionExportWarning = true },
                onImportServerAuthority = {
                    launchTrustedExternalActivity { importServerAuthority.launch(arrayOf("application/x-x509-ca-cert", "application/pkix-cert", "*/*")) }
                },
                password = password,
                onPasswordChanged = { password = it },
                deviceName = deviceName,
                onDeviceNameChanged = { deviceName = it },
                showPassword = showPassword,
                onShowPasswordChanged = { showPassword = it },
                copyRemoteToClipboard = copyRemoteToClipboard,
                onCopyRemoteToClipboardChanged = { copyRemoteToClipboard = it },
                addClipboardOnLaunch = addClipboardOnLaunch,
                onAddClipboardOnLaunchChanged = { addClipboardOnLaunch = it },
                historySort = sortMode,
                onHistorySortChanged = { sortMode = it },
                richTextEnabled = richTextEnabled,
                onRichTextEnabledChanged = {
                    richTextEnabled = it
                    if (!it) richTextImagesEnabled = false
                },
                richTextImagesEnabled = richTextImagesEnabled,
                onRichTextImagesEnabledChanged = { richTextImagesEnabled = it },
                confirmDeletions = confirmDeletions,
                onConfirmDeletionsChanged = { confirmDeletions = it },
                requireAuthentication = requireAuthentication,
                onRequireAuthenticationChanged = { requireAuthentication = it },
                checkForUpdatesAutomatically = checkForUpdatesAutomatically,
                onCheckForUpdatesAutomaticallyChanged = { checkForUpdatesAutomatically = it },
                isCheckingForUpdate = isCheckingForUpdate || isDownloadingUpdate,
                updateStatus = updateStatus,
                onCheckForUpdates = { checkForUpdates(userInitiated = true) },
                playSounds = playSounds,
                onPlaySoundsChanged = { playSounds = it },
                useHaptics = useHaptics,
                onUseHapticsChanged = { useHaptics = it },
                cloudBackupEnabled = cloudBackupEnabled,
                onCloudBackupEnabledChanged = { enabled ->
                    when {
                        !enabled -> cloudBackupEnabled = false
                        password.isBlank() -> {
                            status = "Set and save a nonblank history password before enabling cloud backup."
                            announce(view, status)
                        }
                        cloudBackupTreeUri.isBlank() -> {
                            enableBackupAfterFolderChoice = true
                            launchTrustedExternalActivity {
                                chooseBackupFolder.launch(null)
                            }
                        }
                        else -> cloudBackupEnabled = true
                    }
                },
                cloudBackupLocationName = cloudBackupLocationName,
                onChooseBackupFolder = {
                    enableBackupAfterFolderChoice = false
                    launchTrustedExternalActivity {
                        chooseBackupFolder.launch(null)
                    }
                },
                onRestoreHistoryBackup = {
                    launchTrustedExternalActivity {
                        restoreHistoryBackup.launch(arrayOf("application/octet-stream", "application/gzip", "*/*"))
                    }
                },
                onOpenTipJar = {
                    runCatching {
                        launchTrustedExternalActivity {
                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://onj.me/donate")))
                        }
                    }.onFailure {
                        status = "Could not open the tip jar."
                        announce(view, status)
                    }
                },
                onOpenManual = {
                    runCatching {
                        launchTrustedExternalActivity {
                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://onjlouis.github.io/clipman/manual.html")))
                        }
                    }.onFailure {
                        status = "Could not open the Clipman manual."
                        announce(view, status)
                    }
                },
                onCancel = { if (!isSavingSettings) discardSettingsChanges() },
                onSave = saveSettings@{
                    if (isSavingSettings) return@saveSettings
                    if (storageMode == MobileStorageMode.Server && password.isBlank()) {
                        status = "Clipman Server requires a unique history password. Enter one before saving this connection."
                        announce(view, status)
                        return@saveSettings
                    }
                    if (serverCaCertPem.isNotBlank()) {
                        val authority = runCatching { ServerConnectionConfig.parseAuthority(serverCaCertPem, serverUrl) }.getOrElse { error ->
                            status = "The server address does not match the private certificate authority: ${error.message ?: error::class.java.simpleName}"
                            announce(view, status)
                            return@saveSettings
                        }
                        if (authority == null || (serverCaHost.isNotBlank() && !authority.host.equals(serverCaHost, ignoreCase = true))) {
                            status = "The server address does not match the private certificate authority. Remove the authority or restore the matching HTTPS address before saving."
                            announce(view, status)
                            return@saveSettings
                        }
                        serverCaCertPem = authority.pem
                        serverCaHost = authority.host
                    }
                    if (cloudBackupEnabled && (password.isBlank() || cloudBackupTreeUri.isBlank())) {
                        status = "Cloud backup requires a nonblank history password and a selected backup folder."
                        announce(view, status)
                        return@saveSettings
                    }
                    val savedSettings = MobileSettingsSnapshot(
                        storageMode = storageMode,
                        serverUrl = serverUrl,
                        token = token,
                        serverCaCertPem = serverCaCertPem,
                        serverCaHost = serverCaHost,
                        password = password,
                        deviceName = deviceName,
                        copyRemoteToClipboard = copyRemoteToClipboard,
                        addClipboardOnLaunch = addClipboardOnLaunch,
                        historySort = sortMode,
                        richTextEnabled = richTextEnabled,
                        richTextImagesEnabled = richTextEnabled && richTextImagesEnabled,
                        confirmDeletions = confirmDeletions,
                        requireAuthentication = requireAuthentication,
                        checkForUpdatesAutomatically = checkForUpdatesAutomatically,
                        playSounds = playSounds,
                        useHaptics = useHaptics,
                        cloudBackupEnabled = cloudBackupEnabled,
                        cloudBackupTreeUri = cloudBackupTreeUri,
                        cloudBackupLocationName = cloudBackupLocationName
                    )
                    isSavingSettings = true
                    loadGeneration += 1
                    changeGeneration += 1
                    isLoadingHistory = false
                    val oldPassword = settings.historyPassword
                    val oldBackupTreeUri = settings.cloudBackupTreeUri
                    val newPassword = savedSettings.password
                    val databaseSnapshot = database
                    val historyWasLoaded = hasLoadedHistory
                    scope.launch {
                        val cacheResult = withContext(Dispatchers.IO) {
                            storageMutex.withLock {
                                runCatching {
                                    val toSave = if (historyWasLoaded) {
                                        databaseSnapshot
                                    } else {
                                        historyRepository.loadLocalOrNull(oldPassword)
                                    }
                                    if (toSave != null) {
                                        historyRepository.saveLocal(
                                            toSave,
                                            newPassword,
                                            backupOptions(savedSettings.cloudBackupEnabled, savedSettings.cloudBackupTreeUri)
                                        )
                                    } else null
                                }
                            }
                        }
                        cacheResult.onSuccess { backupError ->
                            storageMode = savedSettings.storageMode
                            serverUrl = savedSettings.serverUrl
                            token = savedSettings.token
                            serverCaCertPem = savedSettings.serverCaCertPem
                            serverCaHost = savedSettings.serverCaHost
                            password = savedSettings.password
                            deviceName = savedSettings.deviceName
                            copyRemoteToClipboard = savedSettings.copyRemoteToClipboard
                            addClipboardOnLaunch = savedSettings.addClipboardOnLaunch
                            sortMode = savedSettings.historySort
                            richTextEnabled = savedSettings.richTextEnabled
                            richTextImagesEnabled = savedSettings.richTextImagesEnabled
                            requireAuthentication = savedSettings.requireAuthentication
                            checkForUpdatesAutomatically = savedSettings.checkForUpdatesAutomatically
                            playSounds = savedSettings.playSounds
                            useHaptics = savedSettings.useHaptics
                            cloudBackupEnabled = savedSettings.cloudBackupEnabled
                            cloudBackupTreeUri = savedSettings.cloudBackupTreeUri
                            cloudBackupLocationName = savedSettings.cloudBackupLocationName
                            saveSettings(savedSettings)
                            if (oldBackupTreeUri.isNotBlank() && oldBackupTreeUri != savedSettings.cloudBackupTreeUri) {
                                releaseBackupFolderPermission(oldBackupTreeUri)
                            }
                            isSavingSettings = false
                            showConnectionSettings = false
                            currentRevision = ""
                            loadHistory()
                            if (backupError != null) {
                                status = "Settings saved, but cloud backup failed: $backupError"
                                announce(view, status)
                            }
                        }
                        cacheResult.onFailure { error ->
                            isSavingSettings = false
                            status = "Could not save settings: ${error.message ?: error::class.java.simpleName}"
                            announce(view, status)
                        }
                    }
                }
            )
            return@Column
        }
        Text(
            text = "Clipman",
            style = MaterialTheme.typography.headlineMedium,
            modifier = Modifier.semantics { heading() }
        )
        HistoryToolbar(
            section = section,
            sections = visibleSections,
            entriesShown = visibleEntries.size,
            filterLabel = if (historyFilterKind == HistoryFilterKind.Device) {
                "Device ${deviceFilter.ifBlank { "All" }}"
            } else {
                groupFilter.ifBlank { "All" }
            },
            onSectionChanged = {
                section = it
                groupFilter = ""
            },
            onAddClipboard = { addCurrentClipboardText() },
            onOpenSettings = { showConnectionSettings = true },
            onGroup = { showGroupPicker = true },
            onTop = { scope.launch { selectedListState.animateScrollToItem(0) } }
        )
        OutlinedTextField(
            value = search,
            onValueChange = { search = it },
            label = { Text("Search history") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth()
        )
        HorizontalPager(
            state = pagerState,
            modifier = Modifier.weight(1f)
        ) { page ->
            val pageSection = visibleSections[page]
            val pageEntries = filteredAndSortedEntries(
                entries = entries.filter { entryBelongsToSection(it, pageSection, richTextEnabled) },
                search = search,
                sortMode = sortMode,
                filterKind = historyFilterKind,
                groupFilter = groupFilter,
                deviceFilter = deviceFilter
            )
            LazyColumn(
                state = when (pageSection) {
                    HistorySection.Text -> textListState
                    HistorySection.RichText -> richTextListState
                    HistorySection.Links -> linksListState
                },
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier
                    .fillMaxSize()
                    .semantics {
                        paneTitle = "${pageSection.label} clipboard history"
                    }
            ) {
                items(
                    count = pageEntries.size,
                    key = { index -> pageEntries[index].Id.ifBlank { pageEntries[index].Text.hashCode().toString() } }
                ) { index ->
                    val entry = pageEntries[index]
                    ClipEntryCard(
                        entry = entry,
                        index = index,
                        total = pageEntries.size,
                        onCopy = {
                            RichTextClipboard.write(context, entry, richTextEnabled)
                            playFeedback(context, ClipmanSound.Copy, playSounds, useHaptics)
                            setTransientStatus("Copied selected entry to Android clipboard.")
                        },
                        onView = { viewingEntry = entry },
                        onOpenLink = { link -> openLink(context, link) },
                        onEdit = { editingEntry = entry },
                        onUseWebsiteTitle = { offerWebsiteTitle(entry) },
                        onSaveImageToPhotos = { image ->
                            val request = entry to image
                            val needsPermission = Build.VERSION.SDK_INT <= Build.VERSION_CODES.P &&
                                ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
                                PackageManager.PERMISSION_GRANTED
                            if (needsPermission) {
                                pendingLegacyPhotoSave = request
                                legacyPhotoPermission.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                            } else {
                                approvedPhotoSave = request
                            }
                        },
                        onShareImage = { image ->
                            scope.launch {
                                runCatching {
                                    withContext(Dispatchers.IO) {
                                        AndroidImageEntryActions.createShareChooser(
                                            context.applicationContext,
                                            image,
                                            entry.SourceMachine,
                                            entry.CreatedUnixMs
                                        )
                                    }
                                }.onSuccess { chooser ->
                                    runCatching {
                                        launchTrustedExternalActivity { context.startActivity(chooser) }
                                    }.onSuccess {
                                        reportImageAction("Image share sheet opened.", true)
                                    }.onFailure { error ->
                                        reportImageAction("Could not open the image share sheet: ${error.message ?: error::class.java.simpleName}", false)
                                    }
                                }.onFailure { error ->
                                    reportImageAction("Could not share image: ${error.message ?: error::class.java.simpleName}", false)
                                }
                            }
                        },
                        onTogglePinned = {
                            saveDatabaseChange(if (entry.Pinned) "Unpinning entry" else "Pinning entry") { database ->
                                SyncConflictResolver.togglePinned(database, entry.Id)
                            }
                        },
                        onDelete = {
                            if (confirmDeletions) {
                                deleteCandidate = entry
                            } else {
                                saveDatabaseChange("Deleting entry") { database ->
                                    SyncConflictResolver.deleteEntry(database, entry.Id)
                                }
                            }
                        }
                    )
                }
            }
        }
        HistoryStatusBar(
            status = historyStatusText(visibleEntries.size, section.label, status),
            onGoToBottom = {
                scope.launch {
                    if (visibleEntries.isNotEmpty()) {
                        selectedListState.animateScrollToItem(visibleEntries.lastIndex)
                    }
                }
            },
            onNextSort = { applyHistorySort(nextSortMode(sortMode)) },
            onSetSort = ::applyHistorySort
        )
    }
}

@Composable
@OptIn(ExperimentalFoundationApi::class)
private fun HistoryStatusBar(
    status: String,
    onGoToBottom: () -> Unit,
    onNextSort: () -> Unit,
    onSetSort: (HistorySort) -> Unit
) {
    val sortActions = HistorySort.entries.map { mode ->
        CustomAccessibilityAction(mode.accessibilityActionLabel) {
            onSetSort(mode)
            true
        }
    }
    Text(
        text = status,
        style = MaterialTheme.typography.bodySmall,
        textAlign = TextAlign.Start,
        modifier = Modifier
            .fillMaxWidth()
            .combinedClickable(
                role = Role.Button,
                onClickLabel = "Go to bottom of history",
                onLongClickLabel = "Use next sort order",
                onClick = onGoToBottom,
                onLongClick = onNextSort
            )
            .semantics {
                liveRegion = LiveRegionMode.Polite
                customActions = sortActions
            }
            .padding(vertical = 12.dp)
    )
}

@Composable
private fun ViewEntryDialog(
    entry: ClipEntry,
    links: List<String>,
    onDismiss: () -> Unit,
    onCopy: () -> Unit,
    onOpenLink: (String) -> Unit,
    onEdit: () -> Unit,
    onUseWebsiteTitle: () -> Unit
) {
    val linkActions = links.mapIndexed { index, link ->
        CustomAccessibilityAction("Open $link") {
            onOpenLink(link)
            true
        }
    }
    val embeddedImage = remember(entry.RichText) { EmbeddedImageRichText.parse(entry.RichText) }
    val previewBitmap = remember(embeddedImage) { embeddedImage?.let(AndroidImageClipboard::decodePreview) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("View Entry") },
        text = {
            Column(
                modifier = Modifier
                    .verticalScroll(rememberScrollState())
                    .semantics {
                        if (linkActions.isNotEmpty()) {
                            customActions = linkActions
                        }
                    },
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                if (embeddedImage != null && previewBitmap != null) {
                    Text(
                        text = "Image preview",
                        style = MaterialTheme.typography.titleSmall,
                        modifier = Modifier.semantics { heading() }
                    )
                    Image(
                        bitmap = previewBitmap.asImageBitmap(),
                        contentDescription = embeddedImage.altText,
                        contentScale = ContentScale.Fit,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 320.dp)
                    )
                }
                Text(
                    text = "Clipboard text",
                    style = MaterialTheme.typography.titleSmall,
                    modifier = Modifier.semantics { heading() }
                )
                textReviewLines(entry.Text).forEach { line ->
                    Text(line, modifier = Modifier.fillMaxWidth())
                }
                if (links.isNotEmpty()) {
                    Text(
                        text = if (links.size == 1) "Link" else "Links",
                        style = MaterialTheme.typography.titleSmall,
                        modifier = Modifier.semantics { heading() }
                    )
                    links.forEachIndexed { index, link ->
                        TextButton(
                            modifier = Modifier.fillMaxWidth(),
                            onClick = { onOpenLink(link) }
                        ) {
                            Text(link)
                        }
                    }
                }
                Text(
                    text = "Details",
                    style = MaterialTheme.typography.titleSmall,
                    modifier = Modifier.semantics { heading() }
                )
                entryMetadataLines(entry, links.size).forEach { line ->
                    Text(line, style = MaterialTheme.typography.bodySmall)
                }
            }
        },
        confirmButton = {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = onCopy) { Text("Copy") }
                TextButton(onClick = onEdit) { Text("Edit") }
                if (entry.Name.isBlank() && LinkPresentation.isFetchableHttpUrl(entry.Text)) {
                    TextButton(onClick = onUseWebsiteTitle) { Text("Use Website Title as Name") }
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Close") }
        }
    )
}

@Composable
private fun ConfirmDeleteDialog(
    entry: ClipEntry,
    onDismiss: () -> Unit,
    onDelete: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Delete Entry") },
        text = { Text("Delete this Clipman entry?\n\n${historyRowPreview(entry).text}") },
        confirmButton = {
            TextButton(onClick = onDelete) { Text("Delete") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        }
    )
}

@Composable
private fun GroupPickerDialog(
    groups: List<String>,
    devices: List<String>,
    selectedKind: HistoryFilterKind,
    selectedGroup: String,
    selectedDevice: String,
    onDismiss: () -> Unit,
    onSelect: (HistoryFilterKind, String) -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Filter History") },
        text = {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                item {
                    Button(
                        modifier = Modifier.fillMaxWidth(),
                        onClick = { onSelect(HistoryFilterKind.Group, "") }
                    ) {
                        Text(if (selectedKind == HistoryFilterKind.Group && selectedGroup.isBlank()) "All entries, selected" else "All entries")
                    }
                }
                if (groups.isNotEmpty()) {
                    item { Text("Groups", style = MaterialTheme.typography.titleSmall) }
                }
                items(groups) { group ->
                    Button(
                        modifier = Modifier.fillMaxWidth(),
                        onClick = { onSelect(HistoryFilterKind.Group, group) }
                    ) {
                        Text(if (selectedKind == HistoryFilterKind.Group && group.equals(selectedGroup, ignoreCase = true)) "$group, selected" else group)
                    }
                }
                if (devices.isNotEmpty()) {
                    item { Text("Devices", style = MaterialTheme.typography.titleSmall) }
                }
                items(devices) { device ->
                    Button(
                        modifier = Modifier.fillMaxWidth(),
                        onClick = { onSelect(HistoryFilterKind.Device, device) }
                    ) {
                        Text(if (selectedKind == HistoryFilterKind.Device && device.equals(selectedDevice, ignoreCase = true)) "$device, selected" else device)
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        }
    )
}

@Composable
private fun HistoryToolbar(
    section: HistorySection,
    sections: List<HistorySection>,
    entriesShown: Int,
    filterLabel: String,
    onSectionChanged: (HistorySection) -> Unit,
    onAddClipboard: () -> Unit,
    onOpenSettings: () -> Unit,
    onGroup: () -> Unit,
    onTop: () -> Unit
) {
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(modifier = Modifier.fillMaxWidth()) {
            TextButton(
                modifier = Modifier.weight(1f),
                onClick = onAddClipboard
            ) {
                Text("Paste")
            }
            TextButton(
                modifier = Modifier.weight(1f),
                onClick = {
                    val current = sections.indexOf(section).coerceAtLeast(0)
                    onSectionChanged(sections[(current + 1) % sections.size])
                }
            ) {
                val current = sections.indexOf(section).coerceAtLeast(0)
                Text("Switch to ${sections[(current + 1) % sections.size].label}")
            }
        }
        Row(modifier = Modifier.fillMaxWidth()) {
            TextButton(
                modifier = Modifier
                    .weight(1f)
                    .semantics { contentDescription = "Filter history, current filter $filterLabel" },
                onClick = onGroup
            ) {
                Text("Filter")
            }
            TextButton(modifier = Modifier.weight(1f), onClick = onOpenSettings) {
                Text("Settings")
            }
            TextButton(
                modifier = Modifier.weight(1f),
                onClick = onTop,
                enabled = entriesShown > 0
            ) {
                Text("Top")
            }
        }
    }
}

internal fun historyStatusText(entriesShown: Int, sectionLabel: String, status: String): String {
    val label = sectionLabel.trim().lowercase()
    val entryLabel = when {
        label == "rich text" -> "rich text ${if (entriesShown == 1) "entry" else "entries"}"
        label == "links" -> "${if (entriesShown == 1) "link" else "links"} ${if (entriesShown == 1) "entry" else "entries"}"
        else -> "$label ${if (entriesShown == 1) "entry" else "entries"}"
    }
    val count = "$entriesShown $entryLabel."
    val detail = status.trim()
    return if (detail.isEmpty()) count else "$count $detail"
}

@Composable
private fun ConnectionSettingsScreen(
    isSaving: Boolean,
    storageMode: MobileStorageMode,
    onStorageModeChanged: (MobileStorageMode) -> Unit,
    serverUrl: String,
    onServerUrlChanged: (String) -> Unit,
    token: String,
    onTokenChanged: (String) -> Unit,
    serverCaCertPem: String,
    serverCaHost: String,
    onRemoveServerAuthority: () -> Unit,
    onPasteToken: () -> Unit,
    onImportServerFile: () -> Unit,
    onExportServerFile: () -> Unit,
    onImportServerAuthority: () -> Unit,
    password: String,
    onPasswordChanged: (String) -> Unit,
    deviceName: String,
    onDeviceNameChanged: (String) -> Unit,
    showPassword: Boolean,
    onShowPasswordChanged: (Boolean) -> Unit,
    copyRemoteToClipboard: Boolean,
    onCopyRemoteToClipboardChanged: (Boolean) -> Unit,
    addClipboardOnLaunch: Boolean,
    onAddClipboardOnLaunchChanged: (Boolean) -> Unit,
    historySort: HistorySort,
    onHistorySortChanged: (HistorySort) -> Unit,
    richTextEnabled: Boolean,
    onRichTextEnabledChanged: (Boolean) -> Unit,
    richTextImagesEnabled: Boolean,
    onRichTextImagesEnabledChanged: (Boolean) -> Unit,
    confirmDeletions: Boolean,
    onConfirmDeletionsChanged: (Boolean) -> Unit,
    requireAuthentication: Boolean,
    onRequireAuthenticationChanged: (Boolean) -> Unit,
    checkForUpdatesAutomatically: Boolean,
    onCheckForUpdatesAutomaticallyChanged: (Boolean) -> Unit,
    isCheckingForUpdate: Boolean,
    updateStatus: String,
    onCheckForUpdates: () -> Unit,
    playSounds: Boolean,
    onPlaySoundsChanged: (Boolean) -> Unit,
    useHaptics: Boolean,
    onUseHapticsChanged: (Boolean) -> Unit,
    cloudBackupEnabled: Boolean,
    onCloudBackupEnabledChanged: (Boolean) -> Unit,
    cloudBackupLocationName: String,
    onChooseBackupFolder: () -> Unit,
    onRestoreHistoryBackup: () -> Unit,
    onOpenTipJar: () -> Unit,
    onOpenManual: () -> Unit,
    onCancel: () -> Unit,
    onSave: () -> Unit
) {
    var showServerConnection by remember {
        mutableStateOf(serverUrl.isBlank() || token.isBlank())
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        SettingsHeader(isSaving = isSaving, onCancel = onCancel, onSave = onSave)
        Text(
            text = "Device",
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.semantics { heading() }
        )
        OutlinedTextField(
            value = deviceName,
            onValueChange = onDeviceNameChanged,
            label = { Text("Device name") },
            singleLine = true,
            enabled = !isSaving,
            modifier = Modifier.fillMaxWidth()
        )
        TextButton(
            onClick = { onHistorySortChanged(nextSortMode(historySort)) },
            enabled = !isSaving,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("History sort order: ${historySort.label}")
        }
        Text(
            text = "History storage",
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.semantics { heading() }
        )
        StorageModeSelector(
            storageMode = storageMode,
            enabled = !isSaving,
            onStorageModeChanged = onStorageModeChanged,
        )
        Text(
            text = if (storageMode == MobileStorageMode.Local) {
                "History is stored privately on this phone. Your server details remain saved for later."
            } else {
                "History is cached on this phone and merged with Clipman Server. Offline changes retry automatically."
            },
            style = MaterialTheme.typography.bodySmall
        )
        Text(
            text = "History backup",
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.semantics { heading() }
        )
        SettingCheckboxRow(
            checked = cloudBackupEnabled,
            onCheckedChange = onCloudBackupEnabledChanged,
            label = "Back up encrypted history automatically",
            enabled = !isSaving
        )
        Text(
            text = if (cloudBackupLocationName.isBlank()) {
                "Backup folder: Not selected"
            } else {
                "Backup folder: $cloudBackupLocationName"
            },
            style = MaterialTheme.typography.bodySmall
        )
        TextButton(onClick = onChooseBackupFolder, enabled = !isSaving) {
            Text(if (cloudBackupLocationName.isBlank()) "Choose backup folder" else "Change backup folder")
        }
        TextButton(onClick = onRestoreHistoryBackup, enabled = !isSaving) {
            Text("Restore and merge history backup")
        }
        Text(
            text = "Clipman writes Clipman History.clipdb through Android's folder picker. A nonblank history password is required, and restore merges entries instead of replacing your current history. Server tokens and passwords are never included.",
            style = MaterialTheme.typography.bodySmall
        )
        SettingCheckboxRow(
            checked = playSounds,
            onCheckedChange = onPlaySoundsChanged,
            label = "Play sounds",
            enabled = !isSaving
        )
        SettingCheckboxRow(
            checked = useHaptics,
            onCheckedChange = onUseHapticsChanged,
            label = "Use haptic feedback",
            enabled = !isSaving
        )
        SettingCheckboxRow(
            checked = copyRemoteToClipboard,
            onCheckedChange = onCopyRemoteToClipboardChanged,
            label = "Copy remote additions to Android clipboard",
            enabled = !isSaving
        )
        SettingCheckboxRow(
            checked = addClipboardOnLaunch,
            onCheckedChange = onAddClipboardOnLaunchChanged,
            label = "Add current clipboard to history on launch",
            enabled = !isSaving
        )
        SettingCheckboxRow(
            checked = richTextEnabled,
            onCheckedChange = onRichTextEnabledChanged,
            label = "Preserve copied formatting and show Rich Text history",
            enabled = !isSaving
        )
        SettingCheckboxRow(
            checked = richTextImagesEnabled,
            onCheckedChange = onRichTextImagesEnabledChanged,
            label = "Include images in Rich Text history",
            enabled = !isSaving && richTextEnabled
        )
        Text(
            text = "Retained image metadata may contain camera or location information and follows " +
                "your clipboard history encryption and sync choices.",
            style = MaterialTheme.typography.bodySmall
        )
        SettingCheckboxRow(
            checked = confirmDeletions,
            onCheckedChange = onConfirmDeletionsChanged,
            label = "Confirm before deleting entries",
            enabled = !isSaving
        )
        SettingCheckboxRow(
            checked = requireAuthentication,
            onCheckedChange = onRequireAuthenticationChanged,
            label = "Require biometric or device authentication",
            enabled = !isSaving
        )
        Text(
            text = "Updates",
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.semantics { heading() }
        )
        SettingCheckboxRow(
            checked = checkForUpdatesAutomatically,
            onCheckedChange = onCheckForUpdatesAutomaticallyChanged,
            label = "Check for updates automatically",
            enabled = !isSaving
        )
        TextButton(onClick = onCheckForUpdates, enabled = !isSaving && !isCheckingForUpdate) {
            Text(if (isCheckingForUpdate) "Checking" else "Check Now")
        }
        if (updateStatus.isNotBlank()) {
            Text(updateStatus, style = MaterialTheme.typography.bodySmall)
        }
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(
                modifier = Modifier.padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Text(
                    text = "Server connection",
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.semantics { heading() }
                )
                Text(
                    text = if (serverUrl.isBlank() || token.isBlank()) {
                        "Server connection needs setup."
                    } else {
                        "Server connection is configured."
                    },
                    style = MaterialTheme.typography.bodyMedium
                )
                TextButton(onClick = { showServerConnection = !showServerConnection }, enabled = !isSaving) {
                    Text(if (showServerConnection) "Hide server connection" else "Show server connection")
                }
                TextButton(onClick = onImportServerFile, enabled = !isSaving) {
                    Text("Import server connection file")
                }
                TextButton(onClick = onExportServerFile, enabled = !isSaving) {
                    Text("Export server connection file")
                }
                TextButton(onClick = onImportServerAuthority, enabled = !isSaving) {
                    Text("Import private authority")
                }
                val authority = remember(serverCaCertPem, serverUrl) {
                    runCatching { ServerConnectionConfig.parseAuthority(serverCaCertPem, serverUrl) }.getOrNull()
                }
                if (authority == null) {
                    Text("Private certificate authority: Not configured", style = MaterialTheme.typography.bodySmall)
                } else {
                    Text(
                        "Private certificate authority for ${authority.host}. Subject: ${authority.subject}. Expires: ${java.text.DateFormat.getDateInstance(java.text.DateFormat.LONG).format(java.util.Date(authority.expiresUnixMs))}.",
                        style = MaterialTheme.typography.bodySmall
                    )
                    Text("Authority SHA-256 fingerprint: ${authority.fingerprint}", style = MaterialTheme.typography.bodySmall)
                    TextButton(onClick = onRemoveServerAuthority, enabled = !isSaving) {
                        Text("Remove private authority")
                    }
                }
                if (showServerConnection) {
                    OutlinedTextField(
                        value = serverUrl,
                        onValueChange = onServerUrlChanged,
                        label = { Text("Server address") },
                        singleLine = true,
                        enabled = !isSaving,
                        modifier = Modifier.fillMaxWidth()
                    )
                    OutlinedTextField(
                        value = token,
                        onValueChange = onTokenChanged,
                        label = { Text("Server token") },
                        singleLine = true,
                        enabled = !isSaving && storageMode == MobileStorageMode.Server,
                        visualTransformation = PasswordVisualTransformation(),
                        modifier = Modifier.fillMaxWidth()
                    )
                    TextButton(
                        onClick = onPasteToken,
                        enabled = !isSaving && storageMode == MobileStorageMode.Server
                    ) {
                        Text("Paste token from clipboard")
                    }
                    OutlinedTextField(
                        value = password,
                        onValueChange = onPasswordChanged,
                        label = { Text("History password") },
                        singleLine = true,
                        enabled = !isSaving,
                        visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
                        modifier = Modifier.fillMaxWidth()
                    )
                    SettingCheckboxRow(
                        checked = showPassword,
                        onCheckedChange = onShowPasswordChanged,
                        label = "Show password",
                        enabled = !isSaving
                    )
                }
            }
        }
        Text(
            text = "Help",
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.semantics { heading() }
        )
        TextButton(onClick = onOpenManual, enabled = !isSaving) { Text("Open Manual") }
        Text(
            text = "Build information",
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.semantics { heading() }
        )
        Text("Version: ${BuildConfig.VERSION_NAME}")
        Text("Build: ${BuildConfig.CLIPMAN_BUILD_STAMP_UTC_MS}")
        Text("Built: ${formatBuildStamp(BuildConfig.CLIPMAN_BUILD_STAMP_UTC_MS)}")
        Text(
            text = "Support Clipman",
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.semantics { heading() }
        )
        TextButton(onClick = onOpenTipJar, enabled = !isSaving) { Text("Open Tip Jar") }
        Text("Tips are optional and do not unlock features.", style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
internal fun StorageModeSelector(
    storageMode: MobileStorageMode,
    enabled: Boolean,
    onStorageModeChanged: (MobileStorageMode) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .selectableGroup(),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        MobileStorageMode.entries.forEach { mode ->
            Row(
                modifier = Modifier.selectable(
                    selected = storageMode == mode,
                    enabled = enabled,
                    role = Role.RadioButton,
                    onClick = { onStorageModeChanged(mode) },
                ),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RadioButton(
                    selected = storageMode == mode,
                    onClick = null,
                    enabled = enabled,
                )
                Text(mode.label)
            }
        }
    }
}

private fun formatBuildStamp(value: String): String {
    val milliseconds = value.toLongOrNull() ?: return "Unknown"
    return SimpleDateFormat("yyyy-MM-dd HH:mm:ss 'UTC'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }.format(Date(milliseconds))
}

@Composable
internal fun SettingCheckboxRow(
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    label: String,
    enabled: Boolean = true
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) {}
            .toggleable(
                value = checked,
                enabled = enabled,
                role = Role.Checkbox,
                onValueChange = onCheckedChange
            )
            .padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Checkbox(
            checked = checked,
            onCheckedChange = null,
            enabled = enabled,
            modifier = Modifier.clearAndSetSemantics {}
        )
        Text(label)
    }
}

@Composable
private fun EntryPropertiesDialog(
    entry: ClipEntry,
    onDismiss: () -> Unit,
    onSave: (ClipEntry) -> Unit,
    onDelete: () -> Unit
) {
    var name by remember(entry.Id) { mutableStateOf(entry.Name) }
    var group by remember(entry.Id) { mutableStateOf(entry.Group) }
    var text by remember(entry.Id) { mutableStateOf(entry.Text) }
    var pinned by remember(entry.Id) { mutableStateOf(entry.Pinned) }
    var isTemplate by remember(entry.Id) { mutableStateOf(entry.IsTemplate) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Clipboard Entry Properties") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Name") },
                    singleLine = true,
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics { contentDescription = "Name" }
                )
                OutlinedTextField(
                    value = group,
                    onValueChange = { group = it },
                    label = { Text("Group") },
                    singleLine = true,
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics { contentDescription = "Group" }
                )
                SettingCheckboxRow(
                    checked = pinned,
                    onCheckedChange = { pinned = it },
                    label = "Pinned"
                )
                SettingCheckboxRow(
                    checked = isTemplate,
                    onCheckedChange = { isTemplate = it },
                    label = "Template"
                )
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    label = { Text("Clipboard text") },
                    minLines = 4,
                    maxLines = 8,
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics { contentDescription = "Clipboard text" }
                )
            }
        },
        confirmButton = {
            TextButton(onClick = {
                onSave(
                    entry.copy(
                        Name = name,
                        Group = group,
                        Text = text,
                        Pinned = pinned,
                        IsTemplate = isTemplate
                    )
                )
            }) {
                Text("Save")
            }
        },
        dismissButton = {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = onDelete) { Text("Delete") }
                TextButton(onClick = onDismiss) { Text("Cancel") }
            }
        }
    )
}

@Composable
@OptIn(ExperimentalFoundationApi::class)
private fun ClipEntryCard(
    entry: ClipEntry,
    index: Int,
    total: Int,
    onCopy: () -> Unit,
    onView: () -> Unit,
    onOpenLink: (String) -> Unit,
    onEdit: () -> Unit,
    onUseWebsiteTitle: () -> Unit,
    onSaveImageToPhotos: (EmbeddedImageData) -> Unit,
    onShareImage: (EmbeddedImageData) -> Unit,
    onTogglePinned: () -> Unit,
    onDelete: () -> Unit
) {
    val embeddedImage = remember(entry.RichText) { EmbeddedImageRichText.parse(entry.RichText) }
    val rowPreview = remember(entry) { historyRowPreview(entry) }
    val rowText = rowPreview.text
    val groupPreview = remember(entry.Group) { HistoryRowPreview.metadata(entry.Group) }
    val devicePreview = remember(entry.SourceMachine) { HistoryRowPreview.metadata(entry.SourceMachine) }
    val labelParts = buildList {
        if (entry.Pinned) add("Pinned")
        if (embeddedImage != null) add("Image, ${embeddedImage.width} by ${embeddedImage.height} pixels")
        if (groupPreview.isNotBlank()) add("Group: $groupPreview")
        if (devicePreview.isNotBlank()) add("Device: $devicePreview")
        add("${index + 1} of $total")
    }
    val links = remember(entry.Text) { extractLinksForHistoryRow(entry.Text) }
    val canOpen = links.size == 1
    val canUseWebsiteTitle = entry.Name.isBlank() && LinkPresentation.isFetchableHttpUrl(entry.Text)
    val actions = clipEntryActionSpecs(
        canOpen,
        canUseWebsiteTitle,
        entry.Pinned,
        hasEmbeddedImage = embeddedImage != null
    ).map { spec ->
        CustomAccessibilityAction(spec.label) {
            when (spec.kind) {
                ClipEntryActionKind.Open -> onOpenLink(links.single())
                ClipEntryActionKind.View -> onView()
                ClipEntryActionKind.Edit -> onEdit()
                ClipEntryActionKind.UseWebsiteTitle -> onUseWebsiteTitle()
                ClipEntryActionKind.Pin -> onTogglePinned()
                ClipEntryActionKind.Delete -> onDelete()
                ClipEntryActionKind.SaveToPhotos -> onSaveImageToPhotos(requireNotNull(embeddedImage))
                ClipEntryActionKind.Share -> onShareImage(requireNotNull(embeddedImage))
            }
            true
        }
    }
    val accessibilityText = clipEntryAccessibilityText(
        rowText = rowText,
        previewWasTruncated = rowPreview.wasTruncated,
        pinned = entry.Pinned,
        imageDescription = embeddedImage?.let { "Image, ${it.width} by ${it.height} pixels" },
        group = groupPreview,
        device = devicePreview,
        index = index,
        total = total
    )
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .combinedClickable(
                onClickLabel = "Copy to Android clipboard",
                onClick = onCopy,
                onLongClickLabel = "View entry",
                onLongClick = onView
            )
            .clearAndSetSemantics {
                contentDescription = accessibilityText
                role = Role.Button
                onClick(label = "Copy to Android clipboard") {
                    onCopy()
                    true
                }
                customActions = actions
            }
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Text(rowText)
            Text(labelParts.joinToString("; "), style = MaterialTheme.typography.bodySmall)
        }
    }
}

internal fun clipEntryAccessibilityText(
    rowText: String,
    previewWasTruncated: Boolean = false,
    pinned: Boolean,
    imageDescription: String?,
    group: String,
    device: String,
    index: Int,
    total: Int
): String = buildList {
    if (pinned) add("Pinned")
    add(rowText)
    if (previewWasTruncated) add("Preview truncated")
    if (!imageDescription.isNullOrBlank()) add(imageDescription)
    if (group.isNotBlank()) add("Group: $group")
    if (device.isNotBlank()) add("Device: $device")
    add("${index + 1} of $total")
}.joinToString("; ")

internal enum class ClipEntryActionKind {
    Open,
    View,
    Edit,
    UseWebsiteTitle,
    Pin,
    Delete,
    SaveToPhotos,
    Share
}

internal data class ClipEntryActionSpec(val kind: ClipEntryActionKind, val label: String)

internal fun clipEntryActionSpecs(
    canOpen: Boolean,
    canUseWebsiteTitle: Boolean,
    pinned: Boolean,
    hasEmbeddedImage: Boolean = false
): List<ClipEntryActionSpec> = buildList {
    if (canOpen) add(ClipEntryActionSpec(ClipEntryActionKind.Open, "Open"))
    add(ClipEntryActionSpec(ClipEntryActionKind.View, "View"))
    add(ClipEntryActionSpec(ClipEntryActionKind.Edit, "Edit"))
    if (canUseWebsiteTitle) {
        add(ClipEntryActionSpec(ClipEntryActionKind.UseWebsiteTitle, "Use Website Title as Name"))
    }
    add(ClipEntryActionSpec(ClipEntryActionKind.Pin, if (pinned) "Unpin" else "Pin"))
    add(ClipEntryActionSpec(ClipEntryActionKind.Delete, "Delete"))
    if (hasEmbeddedImage) {
        add(ClipEntryActionSpec(ClipEntryActionKind.SaveToPhotos, AndroidImageEntryActionPolicy.saveToPhotosLabel))
        add(ClipEntryActionSpec(ClipEntryActionKind.Share, AndroidImageEntryActionPolicy.shareLabel))
    }
}

private fun filteredAndSortedEntries(
    entries: List<ClipEntry>,
    search: String,
    sortMode: HistorySort,
    filterKind: HistoryFilterKind,
    groupFilter: String,
    deviceFilter: String
): List<ClipEntry> {
    val query = search.trim()
    val filtered = entries.filter { entry ->
        (when (filterKind) {
            HistoryFilterKind.Group -> groupFilter.isBlank() || entry.Group.equals(groupFilter, ignoreCase = true)
            HistoryFilterKind.Device -> deviceFilter.isBlank() || entry.SourceMachine.equals(deviceFilter, ignoreCase = true)
        }) &&
            (query.isBlank() ||
                LinkPresentation.searchableText(entry).contains(query, ignoreCase = true) ||
                entry.Group.contains(query, ignoreCase = true) ||
                entry.SourceMachine.contains(query, ignoreCase = true))
    }
    val pinned = filtered.filter { it.Pinned }
        .sortedWith(compareBy<ClipEntry> { manualOrderKey(it) }.thenByDescending { it.CreatedUnixMs })
    val normal = filtered.filterNot { it.Pinned }.let { normalEntries ->
        when (sortMode) {
            HistorySort.Manual -> normalEntries.sortedWith(compareBy<ClipEntry> { manualOrderKey(it) }.thenBy { it.CreatedUnixMs })
            HistorySort.Newest -> normalEntries.sortedByDescending { it.LastUsedUnixMs }
            HistorySort.Oldest -> normalEntries.sortedBy { it.LastUsedUnixMs }
            HistorySort.Text -> normalEntries.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { entryRowText(it) })
        }
    }
    return pinned + normal
}

private fun canonicalLabels(entries: List<ClipEntry>, selector: (ClipEntry) -> String): List<String> =
    entries
        .mapNotNull { entry ->
            selector(entry).trim().takeIf { it.isNotBlank() }?.let { label -> label to entry }
        }
        .groupBy { it.first.lowercase() }
        .values
        .mapNotNull { cluster ->
            cluster
                .groupBy { it.first }
                .map { (label, spelling) ->
                    Triple(
                        label,
                        spelling.size,
                        spelling.maxOf { (_, entry) ->
                            maxOf(entry.ModifiedUnixMs, entry.LastUsedUnixMs, entry.CreatedUnixMs)
                        }
                    )
                }
                .sortedWith(
                    compareByDescending<Triple<String, Int, Long>> { it.second }
                        .thenByDescending { it.third }
                        .thenBy { it.first }
                )
                .firstOrNull()?.first
        }
        .sortedWith(String.CASE_INSENSITIVE_ORDER)

private fun ClipEntry.isLinkEntry(): Boolean {
    return LinkPresentation.isStandaloneLink(Text)
}

private fun entryRowText(entry: ClipEntry): String {
    return historyRowPreview(entry).text
}

@Composable
internal fun SettingsHeader(
    isSaving: Boolean,
    onCancel: () -> Unit,
    onSave: () -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        TextButton(
            onClick = onCancel,
            enabled = !isSaving,
            modifier = Modifier.clearAndSetSemantics {
                contentDescription = "Cancel settings"
                role = Role.Button
                if (isSaving) {
                    disabled()
                } else {
                    onClick(label = "Cancel settings") {
                        onCancel()
                        true
                    }
                }
            }
        ) {
            Text("Cancel", modifier = Modifier.clearAndSetSemantics { })
        }
        Text(
            text = "Settings",
            style = MaterialTheme.typography.titleLarge,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .weight(1f)
                .semantics { heading() }
        )
        val saveLabel = if (isSaving) "Saving settings" else "Save settings"
        TextButton(
            onClick = onSave,
            enabled = !isSaving,
            modifier = Modifier.clearAndSetSemantics {
                contentDescription = saveLabel
                role = Role.Button
                if (isSaving) {
                    disabled()
                } else {
                    onClick(label = "Save settings") {
                        onSave()
                        true
                    }
                }
            }
        ) {
            Text(if (isSaving) "Saving" else "Save", modifier = Modifier.clearAndSetSemantics { })
        }
    }
}

private fun visibleHistorySections(richTextEnabled: Boolean): List<HistorySection> =
    if (richTextEnabled) {
        listOf(HistorySection.Text, HistorySection.RichText, HistorySection.Links)
    } else {
        listOf(HistorySection.Text, HistorySection.Links)
    }

private fun shareServerConnection(context: Context, content: String) {
    val directory = File(context.cacheDir, "shared-connections")
    check(directory.exists() || directory.mkdirs()) { "Could not prepare private sharing storage." }
    directory.listFiles()?.forEach { existing -> existing.delete() }
    val file = File(directory, "Clipman Server.clpconf")
    file.writeText(content, Charsets.UTF_8)
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
    val share = Intent(Intent.ACTION_SEND).apply {
        type = "application/json"
        putExtra(Intent.EXTRA_STREAM, uri)
        clipData = ClipData.newUri(context.contentResolver, "Clipman Server connection", uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    val chooser = Intent.createChooser(share, "Share Clipman Server connection").apply {
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    context.startActivity(chooser)
}

private fun entryBelongsToSection(entry: ClipEntry, section: HistorySection, richTextEnabled: Boolean): Boolean {
    if (richTextEnabled && entry.RichText != null) return section == HistorySection.RichText
    return when (section) {
        HistorySection.Text -> !entry.isLinkEntry()
        HistorySection.RichText -> false
        HistorySection.Links -> entry.isLinkEntry()
    }
}

private fun loadedStatusText(entries: List<ClipEntry>, richTextEnabled: Boolean): String {
    val richText = if (richTextEnabled) entries.count { it.RichText != null } else 0
    val remaining = if (richTextEnabled) entries.filter { it.RichText == null } else entries
    val links = remaining.count { it.isLinkEntry() }
    val text = (remaining.size - links).coerceAtLeast(0)
    val richPart = if (richTextEnabled) ", $richText rich text" else ""
    return "Loaded ${entries.size} clipboard entries: $text text$richPart, $links links."
}

private fun extractLinks(text: String): List<String> =
    UrlRegex.findAll(text)
        .map { match ->
            match.value
                .trim()
                .trimEnd('.', ',', ';', ':', ')', ']', '}', '"', '\'')
        }
        .filter { it.isNotBlank() }
        .distinct()
        .toList()

internal fun extractLinksForHistoryRow(text: String): List<String> =
    if (HistoryRowPreview.canInspectLinks(text)) extractLinks(text) else emptyList()

private val UrlRegex = Regex(
    pattern = """(?i)\b((?:https?://|www\.)[^\s<>"']+)"""
)

private fun textReviewLines(text: String): List<String> {
    val normalized = text.replace("\r\n", "\n").replace('\r', '\n')
    val lines = normalized.split('\n')
    return if (lines.isEmpty()) {
        listOf("Empty")
    } else {
        lines.map { line -> if (line.isBlank()) "Blank line" else line }
    }
}

private fun entryMetadataLines(entry: ClipEntry, linkCount: Int): List<String> =
    buildList {
        val embeddedImage = EmbeddedImageRichText.parse(entry.RichText)
        if (entry.Name.isNotBlank()) add("Name: ${entry.Name}")
        if (entry.Group.isNotBlank()) add("Group: ${entry.Group}")
        if (entry.SourceMachine.isNotBlank()) add("Device: ${entry.SourceMachine}")
        add("Pinned: ${if (entry.Pinned) "Yes" else "No"}")
        add("Template: ${if (entry.IsTemplate) "Yes" else "No"}")
        add("Formatting: ${entry.richTextDescription()}")
        if (embeddedImage != null) {
            add("Image filename: ${embeddedImage.filename}")
            add("Image type: ${if (embeddedImage.mimeType == "image/png") "PNG" else "JPEG"}")
            add("Image dimensions: ${embeddedImage.width} by ${embeddedImage.height} pixels")
            add("Stored image size: ${formatByteSize(embeddedImage.bytes.size.toLong())}")
        }
        add("Added: ${formatUnixMilliseconds(entry.CreatedUnixMs)}")
        add("Last used: ${formatUnixMilliseconds(entry.LastUsedUnixMs)}")
        if (entry.ManualOrder > 0) add("Manual order: ${entry.ManualOrder}")
        add("Text length: ${entry.Text.length} characters")
        add("Links: $linkCount")
        if (entry.Id.isNotBlank()) add("Entry ID: ${entry.Id}")
    }

private fun formatUnixMilliseconds(value: Long): String {
    if (value <= 0L) return "Unknown"
    return DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.MEDIUM).format(Date(value))
}

private fun openLink(context: Context, text: String) {
    val trimmed = text.trim()
    if (trimmed.isBlank()) return
    val url = if (trimmed.startsWith("www.", ignoreCase = true)) "https://$trimmed" else trimmed
    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    runCatching { context.startActivity(intent) }
}

private fun manualOrderKey(entry: ClipEntry): Long =
    if (entry.ManualOrder <= 0) Long.MAX_VALUE else entry.ManualOrder

private fun nextSortMode(current: HistorySort): HistorySort =
    when (current) {
        HistorySort.Manual -> HistorySort.Newest
        HistorySort.Newest -> HistorySort.Oldest
        HistorySort.Oldest -> HistorySort.Text
        HistorySort.Text -> HistorySort.Manual
    }

private fun handleRemoteAdditions(
    context: Context,
    oldEntries: List<ClipEntry>,
    newEntries: List<ClipEntry>,
    enabled: Boolean,
    localMachine: String,
    shouldCopyToClipboard: Boolean,
    richTextEnabled: Boolean,
    playSounds: Boolean,
    useHaptics: Boolean
): String? {
    if (!enabled || oldEntries.isEmpty()) return null
    val oldIds = oldEntries.map { it.Id }.toHashSet()
    val newestRemote = newEntries
        .asSequence()
        .filter { it.Id.isNotBlank() && it.Id !in oldIds }
        .filter { it.SourceMachine.isBlank() || !it.SourceMachine.equals(localMachine, ignoreCase = true) }
        .maxByOrNull { it.CreatedUnixMs }
        ?: return null

    if (shouldCopyToClipboard) {
        RichTextClipboard.write(context, newestRemote, richTextEnabled)
    }
    playFeedback(context, ClipmanSound.Remote, playSounds, useHaptics)
    return newestRemote.SourceMachine.takeIf { it.isNotBlank() } ?: "another device"
}

private fun playFeedback(
    context: Context,
    sound: ClipmanSound,
    playSounds: Boolean,
    useHaptics: Boolean
) {
    if (playSounds) {
        AndroidSoundPlayer.play(context, sound)
    }
    if (useHaptics) {
        vibrate(context)
    }
}

@Suppress("DEPRECATION")
private fun vibrate(context: Context) {
    val vibrator = context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
    if (!vibrator.hasVibrator()) return
    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
        vibrator.vibrate(VibrationEffect.createOneShot(45, VibrationEffect.DEFAULT_AMPLITUDE))
    } else {
        vibrator.vibrate(45)
    }
}

private fun announce(view: View, message: String) {
    view.announceForAccessibility(message)
}

private fun readClipboardText(context: Context): String {
    return RichTextClipboard.read(context, includeRichText = false).text
}

private fun formatByteSize(bytes: Long): String = when {
    bytes < 1024 -> "$bytes bytes"
    else -> String.format(Locale.US, "%.1f KiB", bytes / 1024.0)
}

private fun cleanServerToken(value: String): String {
    val text = value.trim()
    val labeled = Regex("""(?i)\b(?:Token|AuthToken)\s*[:=]\s*"?([A-Za-z0-9_\-]+)""").find(text)
    if (labeled != null) return labeled.groupValues[1].trim()
    val json = Regex(""""(?:AuthToken|token)"\s*:\s*"([^"]+)"""", RegexOption.IGNORE_CASE).find(text)
    if (json != null) return json.groupValues[1].trim()
    return text.trim('"')
}

private fun java.io.Reader.readLimitedText(maxChars: Int): String {
    val output = StringBuilder()
    val buffer = CharArray(4096)
    while (true) {
        val count = read(buffer)
        if (count < 0) break
        if (output.length + count > maxChars) error("This connection file is too large.")
        output.append(buffer, 0, count)
    }
    return output.toString()
}

private fun ClipEntry.richTextDescription(): String {
    val payload = RichTextClipboard.normalize(RichText) ?: return "Plain text"
    val formats = buildList {
        if (payload.HtmlFragment.isNotEmpty()) add("HTML")
        if (payload.RtfBase64.isNotEmpty()) add("RTF")
    }
    return formats.joinToString(" and ").ifEmpty { "Plain text" }
}
