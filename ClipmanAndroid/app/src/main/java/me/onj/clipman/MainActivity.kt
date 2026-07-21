package me.onj.clipman

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Patterns
import android.view.View
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
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
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

class MainActivity : FragmentActivity() {
    private var isUnlocked by mutableStateOf(false)
    private var unlockMessage by mutableStateOf("Clipman is locked.")
    private var unlockPromptShowing = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleConfigurationIntent(intent)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    if (isUnlocked) {
                        ClipmanApp()
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
        requestUnlock()
    }

    override fun onStop() {
        super.onStop()
        if (!isChangingConfigurations) {
            isUnlocked = false
            unlockMessage = "Clipman is locked."
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleConfigurationIntent(intent)
    }

    private fun handleConfigurationIntent(intent: Intent?) {
        if (intent == null) return
        val serverUrl = intent.getStringExtra("serverUrl") ?: intent.getStringExtra("clipmanServerUrl")
        val serverToken = intent.getStringExtra("serverToken") ?: intent.getStringExtra("clipmanServerToken")
        if (serverUrl.isNullOrBlank() && serverToken.isNullOrBlank()) return
        val settings = AndroidSettings(this)
        if (!serverUrl.isNullOrBlank()) settings.serverUrl = serverUrl
        if (!serverToken.isNullOrBlank()) settings.serverToken = serverToken
    }

    private fun requestUnlock() {
        if (isUnlocked || unlockPromptShowing) return
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

private enum class HistorySort(val label: String) {
    Manual("Manual order"),
    Newest("Newest first"),
    Oldest("Oldest first"),
    Text("Text")
}

private enum class HistorySection(val label: String) {
    Text("Text"),
    Links("Links")
}

private data class MobileSettingsSnapshot(
    val storageMode: MobileStorageMode,
    val serverUrl: String,
    val token: String,
    val password: String,
    val deviceName: String,
    val copyRemoteToClipboard: Boolean,
    val addClipboardOnLaunch: Boolean,
    val playSounds: Boolean,
    val useHaptics: Boolean
)

@Composable
@OptIn(ExperimentalFoundationApi::class)
private fun ClipmanApp() {
    val context = androidx.compose.ui.platform.LocalContext.current
    val view = androidx.compose.ui.platform.LocalView.current
    val settings = remember { AndroidSettings(context) }
    val historyRepository = remember { MobileHistoryRepository(context) }
    val storageMutex = remember { Mutex() }
    val scope = rememberCoroutineScope()
    val textListState = rememberLazyListState()
    val linksListState = rememberLazyListState()
    val pagerState = rememberPagerState(pageCount = { HistorySection.entries.size })
    var serverUrl by remember { mutableStateOf(settings.serverUrl) }
    var storageMode by remember { mutableStateOf(settings.storageMode) }
    var token by remember { mutableStateOf(settings.serverToken) }
    var password by remember { mutableStateOf(settings.historyPassword) }
    var deviceName by remember { mutableStateOf(settings.deviceName) }
    var showPassword by remember { mutableStateOf(false) }
    var showConnectionSettings by remember {
        mutableStateOf(storageMode == MobileStorageMode.Server && (serverUrl.isBlank() || token.isBlank()))
    }
    var copyRemoteToClipboard by remember { mutableStateOf(settings.copyRemoteToClipboard) }
    var addClipboardOnLaunch by remember { mutableStateOf(settings.addClipboardOnLaunch) }
    var playSounds by remember { mutableStateOf(settings.playSounds) }
    var useHaptics by remember { mutableStateOf(settings.useHaptics) }
    var status by remember { mutableStateOf("Not loaded.") }
    var search by remember { mutableStateOf("") }
    var section by remember { mutableStateOf(HistorySection.Text) }
    var sortMode by remember { mutableStateOf(HistorySort.Manual) }
    var groupFilter by remember { mutableStateOf("") }
    var entries by remember { mutableStateOf<List<ClipEntry>>(emptyList()) }
    var database by remember { mutableStateOf(ClipDatabase()) }
    var viewingEntry by remember { mutableStateOf<ClipEntry?>(null) }
    var editingEntry by remember { mutableStateOf<ClipEntry?>(null) }
    var deleteCandidate by remember { mutableStateOf<ClipEntry?>(null) }
    var showGroupPicker by remember { mutableStateOf(false) }
    var attemptedInitialLoad by remember { mutableStateOf(false) }
    var currentRevision by remember { mutableStateOf("") }
    var isLoadingHistory by remember { mutableStateOf(false) }
    var announcedFirstPage by remember { mutableStateOf(false) }
    var launchClipboardHandled by remember { mutableStateOf(false) }
    var addClipboardAfterLoad by remember { mutableStateOf(false) }
    var hasLoadedHistory by remember { mutableStateOf(false) }
    var loadGeneration by remember { mutableStateOf(0L) }
    var changeGeneration by remember { mutableStateOf(0L) }
    var isSavingSettings by remember { mutableStateOf(false) }

    fun discardSettingsChanges() {
        serverUrl = settings.serverUrl
        storageMode = settings.storageMode
        token = settings.serverToken
        password = settings.historyPassword
        deviceName = settings.deviceName
        copyRemoteToClipboard = settings.copyRemoteToClipboard
        addClipboardOnLaunch = settings.addClipboardOnLaunch
        playSounds = settings.playSounds
        useHaptics = settings.useHaptics
        showConnectionSettings = false
    }

    BackHandler(enabled = showConnectionSettings && !isSavingSettings) {
        discardSettingsChanges()
    }

    fun saveSettings(snapshot: MobileSettingsSnapshot) {
        settings.serverUrl = snapshot.serverUrl
        settings.storageMode = snapshot.storageMode
        settings.serverToken = snapshot.token
        settings.historyPassword = snapshot.password
        settings.deviceName = snapshot.deviceName
        settings.copyRemoteToClipboard = snapshot.copyRemoteToClipboard
        settings.addClipboardOnLaunch = snapshot.addClipboardOnLaunch
        settings.playSounds = snapshot.playSounds
        settings.useHaptics = snapshot.useHaptics
    }

    fun loadHistory(announceResult: Boolean = true, updateStatusWhenUnchanged: Boolean = true) {
        if (storageMode == MobileStorageMode.Server && (serverUrl.isBlank() || token.isBlank())) {
            status = "Server address and token are required before loading history."
            showConnectionSettings = true
            return
        }
        if (isLoadingHistory) return
        val generation = loadGeneration + 1
        loadGeneration = generation
        val requestedMode = storageMode
        val requestedServerUrl = serverUrl
        val requestedToken = token
        val requestedPassword = password
        val databaseSnapshot = database
        isLoadingHistory = true
        if (announceResult) {
            status = "Loading history..."
            announce(view, "Loading history")
        }
        scope.launch {
            val oldEntries = entries
            val result = withContext(Dispatchers.IO) {
                storageMutex.withLock {
                    runCatching {
                        if (requestedMode == MobileStorageMode.Local) {
                            MobileSyncResult(historyRepository.loadLocal(requestedPassword), "", false)
                        } else {
                            try {
                                historyRepository.synchronize(requestedServerUrl, requestedToken, requestedPassword, databaseSnapshot)
                            } catch (error: Throwable) {
                                val cached = historyRepository.loadLocalOrNull(requestedPassword) ?: throw error
                                MobileSyncResult(
                                    database = cached,
                                    revision = "",
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
                        playSounds = playSounds,
                        useHaptics = useHaptics
                    )
                    status = if (sync.pendingError != null) {
                        "Using local history; server sync is pending: ${sync.pendingError}"
                    } else if (remoteSource != null) {
                        "Clipboard updated by $remoteSource."
                    } else if (storageMode == MobileStorageMode.Local) {
                        "Local history loaded. ${loadedStatusText(entries)}"
                    } else {
                        loadedStatusText(entries)
                    }
                } else if (updateStatusWhenUnchanged) {
                    status = "History is already up to date."
                }
                if (announceResult) announce(view, "History refreshed")
                if (!launchClipboardHandled) {
                    launchClipboardHandled = true
                    addClipboardAfterLoad = addClipboardOnLaunch
                }
            }.onFailure { error ->
                status = "Could not load history: ${error.message ?: error::class.java.simpleName}"
                if (announceResult && storageMode == MobileStorageMode.Server && !hasLoadedHistory) showConnectionSettings = true
                if (announceResult) announce(view, "Could not load history")
            }
        }
    }

    fun saveDatabaseChange(actionText: String, mutation: (ClipDatabase) -> ClipDatabase) {
        loadGeneration += 1
        isLoadingHistory = false
        val generation = changeGeneration + 1
        changeGeneration = generation
        val requestedMode = storageMode
        val requestedServerUrl = serverUrl
        val requestedToken = token
        val requestedPassword = password
        status = "$actionText..."
        val updatedLocal = mutation(database)
        database = updatedLocal
        entries = updatedLocal.Entries
        hasLoadedHistory = true
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                storageMutex.withLock {
                    runCatching {
                        historyRepository.saveLocal(updatedLocal, requestedPassword)
                        if (requestedMode == MobileStorageMode.Local) {
                            MobileSyncResult(updatedLocal, "", false)
                        } else {
                            historyRepository.synchronize(requestedServerUrl, requestedToken, requestedPassword, updatedLocal)
                        }
                    }
                }
            }
            if (generation != changeGeneration) return@launch
            result.onSuccess { sync ->
                database = sync.database
                entries = sync.database.Entries
                currentRevision = sync.revision
                status = if (requestedMode == MobileStorageMode.Local) "$actionText complete in local history." else "$actionText complete."
                if (actionText == "Adding Android clipboard text") {
                    playFeedback(context, ClipmanSound.Copy, playSounds, useHaptics)
                }
                announce(view, "$actionText complete")
            }.onFailure { error ->
                status = if (requestedMode == MobileStorageMode.Server) {
                    "$actionText saved locally; server sync is pending: ${error.message ?: error::class.java.simpleName}"
                } else {
                    "$actionText failed: ${error.message ?: error::class.java.simpleName}"
                }
            }
        }
    }

    fun addCurrentClipboardText() {
        val clipboardText = readClipboardText(context).trim()
        if (clipboardText.isEmpty()) {
            status = "The Android clipboard does not contain text to add."
            return
        }
        saveDatabaseChange("Adding Android clipboard text") { database ->
            SyncConflictResolver.addText(database, clipboardText, deviceName.ifBlank { AndroidSettings.defaultDeviceName() })
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

    LaunchedEffect(storageMode, serverUrl, token, password, showConnectionSettings) {
        val ready = storageMode == MobileStorageMode.Local || (serverUrl.isNotBlank() && token.isNotBlank())
        if (!attemptedInitialLoad && !showConnectionSettings && ready) {
            attemptedInitialLoad = true
            loadHistory()
        }
    }

    LaunchedEffect(storageMode, serverUrl, token, password, showConnectionSettings) {
        while (storageMode == MobileStorageMode.Server && serverUrl.isNotBlank() && token.isNotBlank() && !showConnectionSettings) {
            delay(5000)
            loadHistory(announceResult = false, updateStatusWhenUnchanged = false)
        }
    }

    val sectionEntries = remember(entries, section) {
        entries.filter { entry ->
            when (section) {
                HistorySection.Text -> !entry.isLinkEntry()
                HistorySection.Links -> entry.isLinkEntry()
            }
        }
    }
    val groups = remember(sectionEntries) {
        sectionEntries.map { it.Group.trim() }
            .filter { it.isNotBlank() }
            .distinct()
            .sortedWith(String.CASE_INSENSITIVE_ORDER)
    }
    val visibleEntries = remember(sectionEntries, search, sortMode, groupFilter) {
        filteredAndSortedEntries(sectionEntries, search, sortMode, groupFilter)
    }
    val selectedListState = if (section == HistorySection.Text) textListState else linksListState

    LaunchedEffect(section, groupFilter, search, sortMode) {
        if (visibleEntries.isNotEmpty()) selectedListState.scrollToItem(0)
    }

    LaunchedEffect(section) {
        if (pagerState.currentPage != section.ordinal) {
            pagerState.animateScrollToPage(section.ordinal)
        }
    }

    LaunchedEffect(pagerState.currentPage) {
        val newSection = HistorySection.entries[pagerState.currentPage]
        if (section != newSection) {
            section = newSection
            groupFilter = ""
            if (announcedFirstPage) {
                announce(view, "${newSection.label} history")
            }
        } else {
            announcedFirstPage = true
        }
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
                saveDatabaseChange("Deleting entry") { database ->
                    SyncConflictResolver.deleteEntry(database, entry.Id)
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
                copyToClipboard(context, entry.Text)
                playFeedback(context, ClipmanSound.Copy, playSounds, useHaptics)
                announce(view, "Copied to clipboard")
                status = "Copied selected entry to Android clipboard."
            },
            onOpenLink = { link ->
                openLink(context, link)
            },
            onEdit = {
                viewingEntry = null
                editingEntry = entry
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
    if (showGroupPicker) {
        GroupPickerDialog(
            groups = groups,
            selectedGroup = groupFilter,
            onDismiss = { showGroupPicker = false },
            onSelect = {
                groupFilter = it
                showGroupPicker = false
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
                playSounds = playSounds,
                onPlaySoundsChanged = { playSounds = it },
                useHaptics = useHaptics,
                onUseHapticsChanged = { useHaptics = it },
                onCancel = { if (!isSavingSettings) discardSettingsChanges() },
                onSave = saveSettings@{
                    if (isSavingSettings) return@saveSettings
                    val savedSettings = MobileSettingsSnapshot(
                        storageMode = storageMode,
                        serverUrl = serverUrl,
                        token = token,
                        password = password,
                        deviceName = deviceName,
                        copyRemoteToClipboard = copyRemoteToClipboard,
                        addClipboardOnLaunch = addClipboardOnLaunch,
                        playSounds = playSounds,
                        useHaptics = useHaptics
                    )
                    isSavingSettings = true
                    loadGeneration += 1
                    changeGeneration += 1
                    isLoadingHistory = false
                    val oldPassword = settings.historyPassword
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
                                    if (toSave != null) historyRepository.saveLocal(toSave, newPassword)
                                }
                            }
                        }
                        cacheResult.onSuccess {
                            storageMode = savedSettings.storageMode
                            serverUrl = savedSettings.serverUrl
                            token = savedSettings.token
                            password = savedSettings.password
                            deviceName = savedSettings.deviceName
                            copyRemoteToClipboard = savedSettings.copyRemoteToClipboard
                            addClipboardOnLaunch = savedSettings.addClipboardOnLaunch
                            playSounds = savedSettings.playSounds
                            useHaptics = savedSettings.useHaptics
                            saveSettings(savedSettings)
                            isSavingSettings = false
                            showConnectionSettings = false
                            currentRevision = ""
                            loadHistory()
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
            entriesShown = visibleEntries.size,
            totalEntries = entries.size,
            sortMode = sortMode,
            groupFilter = groupFilter,
            groups = groups,
            onSectionChanged = {
                section = it
                groupFilter = ""
            },
            onAddClipboard = { addCurrentClipboardText() },
            onOpenSettings = { showConnectionSettings = true },
            onSort = { sortMode = nextSortMode(sortMode) },
            onGroup = { showGroupPicker = true },
            onTop = { scope.launch { selectedListState.animateScrollToItem(0) } },
            onBottom = {
                scope.launch {
                    if (visibleEntries.isNotEmpty()) selectedListState.animateScrollToItem(visibleEntries.lastIndex)
                }
            }
        )
        OutlinedTextField(
            value = search,
            onValueChange = { search = it },
            label = { Text("Search history") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth()
        )
        Text(
            text = "${visibleEntries.size} ${section.label.lowercase()} entries shown. Sort: ${sortMode.label}. Group: ${groupFilter.ifBlank { "All" }}.",
            style = MaterialTheme.typography.bodySmall
        )
        HorizontalPager(
            state = pagerState,
            modifier = Modifier.weight(1f)
        ) { page ->
            val pageSection = HistorySection.entries[page]
            val pageEntries = filteredAndSortedEntries(
                entries = entries.filter { entry ->
                    when (pageSection) {
                        HistorySection.Text -> !entry.isLinkEntry()
                        HistorySection.Links -> entry.isLinkEntry()
                    }
                },
                search = search,
                sortMode = sortMode,
                groupFilter = if (pageSection == section) groupFilter else ""
            )
            LazyColumn(
                state = if (pageSection == HistorySection.Text) textListState else linksListState,
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxSize()
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
                            copyToClipboard(context, entry.Text)
                            playFeedback(context, ClipmanSound.Copy, playSounds, useHaptics)
                            announce(view, "Copied to clipboard")
                            status = "Copied selected entry to Android clipboard."
                        },
                        onView = { viewingEntry = entry },
                        onOpenLink = { link -> openLink(context, link) },
                        onEdit = { editingEntry = entry },
                        onTogglePinned = {
                            saveDatabaseChange(if (entry.Pinned) "Unpinning entry" else "Pinning entry") { database ->
                                SyncConflictResolver.togglePinned(database, entry.Id)
                            }
                        },
                        onDelete = { deleteCandidate = entry }
                    )
                }
            }
        }
        Text(
            text = status,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.fillMaxWidth()
        )
    }
}

@Composable
private fun ViewEntryDialog(
    entry: ClipEntry,
    links: List<String>,
    onDismiss: () -> Unit,
    onCopy: () -> Unit,
    onOpenLink: (String) -> Unit,
    onEdit: () -> Unit
) {
    val linkActions = links.mapIndexed { index, link ->
        CustomAccessibilityAction("Open $link") {
            onOpenLink(link)
            true
        }
    }
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
        text = { Text("Delete this Clipman entry?\n\n${entry.displayText.take(500)}") },
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
    selectedGroup: String,
    onDismiss: () -> Unit,
    onSelect: (String) -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Choose Group") },
        text = {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                item {
                    Button(
                        modifier = Modifier.fillMaxWidth(),
                        onClick = { onSelect("") }
                    ) {
                        Text(if (selectedGroup.isBlank()) "All groups, selected" else "All groups")
                    }
                }
                items(groups) { group ->
                    Button(
                        modifier = Modifier.fillMaxWidth(),
                        onClick = { onSelect(group) }
                    ) {
                        Text(if (group.equals(selectedGroup, ignoreCase = true)) "$group, selected" else group)
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
    entriesShown: Int,
    totalEntries: Int,
    sortMode: HistorySort,
    groupFilter: String,
    groups: List<String>,
    onSectionChanged: (HistorySection) -> Unit,
    onAddClipboard: () -> Unit,
    onOpenSettings: () -> Unit,
    onSort: () -> Unit,
    onGroup: () -> Unit,
    onTop: () -> Unit,
    onBottom: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        TextButton(
            onClick = {
                onSectionChanged(
                    if (section == HistorySection.Text) HistorySection.Links else HistorySection.Text
                )
            }
        ) {
            Text(if (section == HistorySection.Text) "Switch to Links" else "Switch to Text")
        }
        TextButton(onClick = onAddClipboard) { Text("Paste") }
        TextButton(onClick = onGroup, enabled = groups.isNotEmpty()) {
            Text("Group")
        }
        TextButton(onClick = onOpenSettings) { Text("Settings") }
        TextButton(onClick = onTop, enabled = entriesShown > 0) { Text("Top") }
        TextButton(onClick = onBottom, enabled = entriesShown > 0) { Text("Bottom") }
        TextButton(onClick = onSort) { Text("Sort: ${sortMode.label}") }
    }
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
    onPasteToken: () -> Unit,
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
    playSounds: Boolean,
    onPlaySoundsChanged: (Boolean) -> Unit,
    useHaptics: Boolean,
    onUseHapticsChanged: (Boolean) -> Unit,
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
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            TextButton(onClick = onCancel, enabled = !isSaving) { Text("Cancel") }
            Text(
                text = "Settings",
                style = MaterialTheme.typography.titleLarge,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .weight(1f)
                    .semantics { heading() }
            )
            TextButton(onClick = onSave, enabled = !isSaving) { Text(if (isSaving) "Saving" else "Save") }
        }
        OutlinedTextField(
            value = deviceName,
            onValueChange = onDeviceNameChanged,
            label = { Text("Device name") },
            singleLine = true,
            enabled = !isSaving,
            modifier = Modifier.fillMaxWidth()
        )
        Text(
            text = "History storage",
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.semantics { heading() }
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            MobileStorageMode.entries.forEach { mode ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(
                        selected = storageMode == mode,
                        onClick = { onStorageModeChanged(mode) },
                        enabled = !isSaving
                    )
                    Text(mode.label)
                }
            }
        }
        Text(
            text = if (storageMode == MobileStorageMode.Local) {
                "History is stored privately on this phone. Your server details remain saved for later."
            } else {
                "History is cached on this phone and merged with Clipman Server. Offline changes retry automatically."
            },
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
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Checkbox(
                            checked = showPassword,
                            onCheckedChange = onShowPasswordChanged,
                            enabled = !isSaving,
                            modifier = Modifier
                        )
                        Text("Show password")
                    }
                }
            }
        }
        Text(
            text = "Build information",
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.semantics { heading() }
        )
        Text("Version: ${BuildConfig.VERSION_NAME}")
        Text("Build: ${BuildConfig.CLIPMAN_BUILD_STAMP_UTC_MS}")
        Text("Built: ${formatBuildStamp(BuildConfig.CLIPMAN_BUILD_STAMP_UTC_MS)}")
    }
}

private fun formatBuildStamp(value: String): String {
    val milliseconds = value.toLongOrNull() ?: return "Unknown"
    return SimpleDateFormat("yyyy-MM-dd HH:mm:ss 'UTC'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }.format(Date(milliseconds))
}

@Composable
private fun SettingCheckboxRow(
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    label: String,
    enabled: Boolean = true
) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Checkbox(
            checked = checked,
            onCheckedChange = onCheckedChange,
            enabled = enabled
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
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = group,
                    onValueChange = { group = it },
                    label = { Text("Group") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Checkbox(checked = pinned, onCheckedChange = { pinned = it })
                    Text("Pinned")
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Checkbox(checked = isTemplate, onCheckedChange = { isTemplate = it })
                    Text("Template")
                }
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    label = { Text("Clipboard text") },
                    minLines = 4,
                    maxLines = 8,
                    modifier = Modifier.fillMaxWidth()
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
    onTogglePinned: () -> Unit,
    onDelete: () -> Unit
) {
    val labelParts = buildList {
        if (entry.Pinned) add("Pinned")
        if (entry.Group.isNotBlank()) add("Group: ${entry.Group}")
        if (entry.SourceMachine.isNotBlank()) add("Machine: ${entry.SourceMachine}")
        add("${index + 1} of $total")
    }
    val links = remember(entry.Text) { extractLinks(entry.Text) }
    val actions = buildList {
        if (links.size == 1) {
            add(
                CustomAccessibilityAction("Open link") {
                    onOpenLink(links.single())
                    true
                }
            )
        }
        add(
            CustomAccessibilityAction("View entry") {
                onView()
                true
            }
        )
        add(
            CustomAccessibilityAction("Edit entry") {
                onEdit()
                true
            }
        )
        add(
            CustomAccessibilityAction(if (entry.Pinned) "Unpin entry" else "Pin entry") {
                onTogglePinned()
                true
            }
        )
        add(
            CustomAccessibilityAction("Delete entry") {
                onDelete()
                true
            }
        )
    }
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .combinedClickable(
                onClickLabel = "Copy to Android clipboard",
                onClick = onCopy,
                onLongClickLabel = "View entry",
                onLongClick = onView
            )
            .semantics(mergeDescendants = true) {
                role = Role.Button
                customActions = actions
            }
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Text(entry.displayText.take(500))
            Text(labelParts.joinToString("; "), style = MaterialTheme.typography.bodySmall)
        }
    }
}

private fun filteredAndSortedEntries(
    entries: List<ClipEntry>,
    search: String,
    sortMode: HistorySort,
    groupFilter: String
): List<ClipEntry> {
    val query = search.trim()
    val filtered = entries.filter { entry ->
        (groupFilter.isBlank() || entry.Group.equals(groupFilter, ignoreCase = true)) &&
            (query.isBlank() ||
                entry.Text.contains(query, ignoreCase = true) ||
                entry.Name.contains(query, ignoreCase = true) ||
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
            HistorySort.Text -> normalEntries.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.displayText })
        }
    }
    return pinned + normal
}

private fun ClipEntry.isLinkEntry(): Boolean {
    val text = Text.trim()
    if (text.isBlank() || text.any { it.isWhitespace() }) return false
    if (text.startsWith("http://", ignoreCase = true) ||
        text.startsWith("https://", ignoreCase = true) ||
        text.startsWith("www.", ignoreCase = true)) {
        return true
    }
    return Patterns.WEB_URL.matcher(text).matches()
}

private fun loadedStatusText(entries: List<ClipEntry>): String {
    val links = entries.count { it.isLinkEntry() }
    val text = (entries.size - links).coerceAtLeast(0)
    return "Loaded ${entries.size} clipboard entries: $text text, $links links."
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
        if (entry.Name.isNotBlank()) add("Name: ${entry.Name}")
        if (entry.Group.isNotBlank()) add("Group: ${entry.Group}")
        if (entry.SourceMachine.isNotBlank()) add("Machine: ${entry.SourceMachine}")
        add("Pinned: ${if (entry.Pinned) "Yes" else "No"}")
        add("Template: ${if (entry.IsTemplate) "Yes" else "No"}")
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
        copyToClipboard(context, newestRemote.Text)
    }
    playFeedback(context, ClipmanSound.Remote, playSounds, useHaptics)
    return newestRemote.SourceMachine.takeIf { it.isNotBlank() } ?: "another machine"
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

private fun copyToClipboard(context: Context, text: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    clipboard.setPrimaryClip(ClipData.newPlainText("Clipman entry", text))
}

private fun announce(view: View, message: String) {
    view.announceForAccessibility(message)
}

private fun readClipboardText(context: Context): String {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    val clip = clipboard.primaryClip ?: return ""
    if (clip.itemCount <= 0) return ""
    return clip.getItemAt(0).coerceToText(context)?.toString() ?: ""
}

private fun cleanServerToken(value: String): String {
    val text = value.trim()
    val labeled = Regex("""(?i)\b(?:Token|AuthToken)\s*[:=]\s*"?([A-Za-z0-9_\-]+)""").find(text)
    if (labeled != null) return labeled.groupValues[1].trim()
    val json = Regex(""""AuthToken"\s*:\s*"([^"]+)"""").find(text)
    if (json != null) return json.groupValues[1].trim()
    return text.trim('"')
}
