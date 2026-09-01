using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class ClipmanApplicationContext : ApplicationContext
    {
        private const int ShowHotkeyId = 1001;
        private const int ToggleHotkeyId = 1002;
        private const int SaveCurrentClipboardHotkeyId = 1003;
        private const int ToggleHotkeyAlternateId = 1004;
        private const int QuickCopyHotkeyBaseId = 2000;
        private const int SecretHotkeyBaseId = 3000;
        private const int MaximumClipboardSnapshotTextLength = 32 * 1024 * 1024;
        private const int MaximumClipboardSnapshotStreamLength = 64 * 1024 * 1024;

        private readonly string appDirectory;
        private readonly SettingsStore settingsStore;
        private SoundService sounds;
        private readonly MessageWindow messageWindow;
        private readonly Control invoker;
        private readonly NotifyIcon notifyIcon;
        private readonly EventWaitHandle closeEvent;
        private readonly EventWaitHandle showEvent;
        private readonly EventWaitHandle recoverEvent;
        private readonly EventWaitHandle pauseEvent;
        private readonly EventWaitHandle resumeEvent;
        private readonly EventWaitHandle toggleEvent;
        private readonly EventWaitHandle historyChangedEvent;
        private readonly EventWaitHandle historyAddedEvent;
        private readonly Thread closeThread;
        private readonly Thread showThread;
        private readonly Thread recoverThread;
        private readonly Thread pauseThread;
        private readonly Thread resumeThread;
        private readonly Thread toggleThread;
        private readonly Thread historyChangedThread;
        private readonly Thread historyAddedThread;
        private readonly ClipboardFloodGuardRegistry clipboardFloodGuards = new ClipboardFloodGuardRegistry();
        private readonly ClipboardNotificationState clipboardNotifications = new ClipboardNotificationState();
        private readonly ClipMergeDetector clipMergeDetector = new ClipMergeDetector();
        private readonly object automaticWebsiteTitleLock = new object();
        private readonly Queue<AutomaticWebsiteTitleRequest> automaticWebsiteTitleQueue = new Queue<AutomaticWebsiteTitleRequest>();
        private readonly HashSet<string> automaticWebsiteTitleEntryIds = new HashSet<string>(StringComparer.Ordinal);
        private bool automaticWebsiteTitleWorkerRunning;
        private FileSystemWatcher sharedStateWatcher;
        private FileSystemWatcher executableWatcher;
        private System.Threading.Timer sharedStateTimer;
        private System.Threading.Timer updateCheckTimer;
        private readonly System.Windows.Forms.Timer clipboardFloodRecoveryTimer;
        private AppSettings settings;
        private ClipStore store;
        private FileClipboardEventStore fileEventStore;
        private SecretStore secretStore;
        private HistoryForm historyForm;
        private PreferencesForm preferencesForm;
        private SecretsForm secretsForm;
        private int ignoredClipboardChangeCount;
        private bool showHotkeyRegistered;
        private bool toggleHotkeyRegistered;
        private bool saveCurrentClipboardHotkeyRegistered;
        private bool toggleAlternateHotkeyRegistered;
        private readonly Dictionary<int, string> quickCopyHotkeyEntryIds = new Dictionary<int, string>();
        private readonly Dictionary<int, string> secretHotkeyEntryIds = new Dictionary<int, string>();
        private int quickCopyHotkeysRegistered;
        private int secretHotkeysRegistered;
        private string lastClipboardPrivacySignal = "None";
        private string lastHandledCloseRequestId = string.Empty;
        private string lastAutoCopiedRemoteEntryId = string.Empty;
        private long lastAutoCopiedRemoteEntryStamp;
        private string databasePassword = string.Empty;
        private IntPtr previousForegroundWindow = IntPtr.Zero;
        private string lastReceivedHistoryTab = HistoryTabs.Text;
        private bool receivedHistoryTabPending;
        private int storageRetryInProgress;

        private sealed class AutomaticWebsiteTitleRequest
        {
            public string EntryId { get; set; }
            public string OriginalText { get; set; }
            public Uri Uri { get; set; }
        }

        public ClipmanApplicationContext()
        {
            RichImageFileDropData.Cleanup();
            appDirectory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            settingsStore = new SettingsStore(appDirectory, Program.WriteRuntimeLog);
            settings = settingsStore.Load();
            ResolveDatabaseLocation();
            ResolveDatabasePassword();
            SeedServerCacheFromConfiguredDatabase();
            SharedUpdateStateStore.PublishCurrentBuild(SharedExecutableSettingsDirectory(), Application.ExecutablePath);
            sounds = new SoundService(appDirectory, settingsStore.SettingsDirectory);
            store = new ClipStore(EffectiveTextHistoryDatabasePath(), CurrentDatabasePassword, CurrentDeviceName());
            store.Changed += StoreChanged;
            ConfigureTextHistoryServerStorage();
            ResetRemoteAutoCopyBaseline();
            fileEventStore = new FileClipboardEventStore(settingsStore.DefaultFileHistoryDatabasePath(), CurrentDatabasePassword);
            fileEventStore.Changed += FileEventStoreChanged;
            secretStore = new SecretStore(DefaultSecretsDatabasePath(), CurrentDatabasePassword);

            invoker = new Control();
            invoker.CreateControl();

            clipboardFloodRecoveryTimer = new System.Windows.Forms.Timer
            {
                Interval = ClipboardFloodGuard.DefaultQuietMilliseconds
            };
            clipboardFloodRecoveryTimer.Tick += ClipboardFloodRecoveryTimerTick;

            messageWindow = new MessageWindow(this);
            NativeMethods.AddClipboardFormatListener(messageWindow.Handle);

            notifyIcon = new NotifyIcon
            {
                Text = TrayText(),
                Icon = BuildIcon(settings.Active),
                Visible = true,
                ContextMenuStrip = BuildTrayMenu()
            };
            notifyIcon.DoubleClick += (s, e) => ToggleHistoryWindow();
            if (settings.CaptureClipboardOnStartup)
            {
                TryCaptureClipboardOnStartup();
            }

            RegisterHotkeys();
            ApplyStartupRegistration(false);
            PlayLaunchStateSound();

            closeEvent = new EventWaitHandle(false, EventResetMode.ManualReset, Program.CloseEventName);
            showEvent = new EventWaitHandle(false, EventResetMode.ManualReset, Program.ShowEventName);
            recoverEvent = new EventWaitHandle(false, EventResetMode.ManualReset, Program.RecoverEventName);
            pauseEvent = new EventWaitHandle(false, EventResetMode.ManualReset, Program.PauseEventName);
            resumeEvent = new EventWaitHandle(false, EventResetMode.ManualReset, Program.ResumeEventName);
            toggleEvent = new EventWaitHandle(false, EventResetMode.ManualReset, Program.ToggleEventName);
            historyChangedEvent = new EventWaitHandle(false, EventResetMode.ManualReset, Program.HistoryChangedEventName);
            historyAddedEvent = new EventWaitHandle(false, EventResetMode.ManualReset, Program.HistoryAddedEventName);
            closeThread = new Thread(WaitForClose) { IsBackground = true, Name = "Clipman close event listener" };
            showThread = new Thread(WaitForShow) { IsBackground = true, Name = "Clipman show event listener" };
            recoverThread = new Thread(WaitForRecover) { IsBackground = true, Name = "Clipman storage recovery listener" };
            pauseThread = new Thread(() => WaitForState(pauseEvent, false)) { IsBackground = true, Name = "Clipman pause event listener" };
            resumeThread = new Thread(() => WaitForState(resumeEvent, true)) { IsBackground = true, Name = "Clipman resume event listener" };
            toggleThread = new Thread(WaitForToggle) { IsBackground = true, Name = "Clipman toggle event listener" };
            historyChangedThread = new Thread(WaitForHistoryChanged) { IsBackground = true, Name = "Clipman history-change event listener" };
            historyAddedThread = new Thread(WaitForHistoryAdded) { IsBackground = true, Name = "Clipman history-add event listener" };
            closeThread.Start();
            showThread.Start();
            recoverThread.Start();
            pauseThread.Start();
            resumeThread.Start();
            toggleThread.Start();
            historyChangedThread.Start();
            historyAddedThread.Start();
            if (InstanceStateStore.HasPendingCommandEntry())
            {
                historyAddedEvent.Set();
            }
            StartSharedUpdateWatchers();
            ScheduleSharedUpdateCheck(5000);
            ScheduleUpdateChecks();
            WarnAboutPasswordlessServerConfiguration();
        }

        private void WarnAboutPasswordlessServerConfiguration()
        {
            if (!IsServerStorageEnabled() ||
                string.IsNullOrWhiteSpace(settings.ServerUrl) ||
                string.IsNullOrWhiteSpace(settings.ServerToken) ||
                !string.IsNullOrEmpty(CurrentDatabasePassword()) ||
                invoker == null ||
                !invoker.IsHandleCreated)
            {
                return;
            }

            invoker.BeginInvoke(new Action(() =>
            {
                MessageBox.Show(
                    "Clipman Server now requires a history password. Server synchronization has not started, and your local cached history has not been changed.\r\n\r\nOpen Storage and Password preferences and enter a unique password shared only with your own Clipman clients.",
                    "Clipman Server history password",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
                ShowPreferencesFromTray();
            }));
        }

        public void ShowHistory()
        {
            var historyWasVisible = historyForm != null && !historyForm.IsDisposed && historyForm.Visible;
            if (!historyWasVisible)
            {
                RememberPreviousForegroundWindow();
            }
            var created = false;
            if (historyForm == null || historyForm.IsDisposed)
            {
                historyForm = new HistoryForm(store, settings, SaveSettings, RegisterHotkeys, CopyEntryToClipboard, CopyEntriesToClipboard, CopyPlainTextToClipboard, PasteClipboardIntoPreviousApplication, SaveCurrentClipboardToHistory, GetRecentClipboardEvents, DeleteRecentClipboardEvents, ClearRecentClipboardEvents, RemoveUnavailableRecentClipboardEvents, ToggleRecentClipboardEventPinned, MoveRecentClipboardEvents, ClearTextHistory, ShowPreferences, ShowSecrets, ToggleActive, ExitThread, () => sounds.Skip(settings.SoundsEnabled), BuildDiagnosticsText, HistorySteadyStatusText);
                created = true;
            }

            if (historyForm.WindowState == FormWindowState.Minimized)
            {
                historyForm.WindowState = FormWindowState.Normal;
            }
            if (settings.DynamicHistoryMode && receivedHistoryTabPending)
            {
                historyForm.SelectHistoryTabForOpen(lastReceivedHistoryTab);
                receivedHistoryTabPending = false;
            }
            var handle = historyForm.Handle;
            historyForm.Show();
            NativeMethods.ShowWindow(handle, NativeMethods.SW_SHOWNORMAL);
            historyForm.BringToFront();
            historyForm.Activate();
            NativeMethods.SetForegroundWindow(handle);
            if (created)
            {
                historyForm.TopMost = true;
                historyForm.TopMost = false;
            }
            historyForm.FocusHistoryList(created);
        }

        public void ToggleHistoryWindow()
        {
            if (historyForm != null && !historyForm.IsDisposed && historyForm.Visible && historyForm.WindowState != FormWindowState.Minimized)
            {
                historyForm.Hide();
                return;
            }

            ShowHistory();
        }

        public void ToggleActive()
        {
            SetActive(!settings.Active, true);
        }

        private void SetActive(bool active, bool playSound)
        {
            settings.Active = active;
            SaveSettings();
            UpdateTray();
            if (preferencesForm != null && !preferencesForm.IsDisposed)
            {
                preferencesForm.SetActiveChecked(settings.Active);
            }
            if (playSound)
            {
                if (settings.Active) sounds.On(settings.SoundsEnabled); else sounds.Off(settings.SoundsEnabled);
            }
        }

        public void ShowPreferences()
        {
            ShowPreferences(true);
        }

        private void ShowPreferencesFromTray()
        {
            ShowPreferences(false);
        }

        private void ShowPreferences(bool showHistoryIfHidden)
        {
            if (preferencesForm != null && !preferencesForm.IsDisposed)
            {
                FocusPreferencesForm();
                return;
            }

            if (historyForm == null || historyForm.IsDisposed || !historyForm.Visible)
            {
                if (showHistoryIfHidden)
                {
                    ShowHistory();
                }
            }

            preferencesForm = new PreferencesForm(settings, ApplyPreferences, CopySensitiveTextToClipboard);
            preferencesForm.FormClosed += (s, e) => preferencesForm = null;
            if (historyForm != null && !historyForm.IsDisposed && historyForm.Visible)
            {
                preferencesForm.ShowDialog(historyForm);
            }
            else
            {
                preferencesForm.ShowDialog();
            }
            preferencesForm = null;
        }

        private void FocusPreferencesForm()
        {
            if (preferencesForm == null || preferencesForm.IsDisposed) return;
            FocusPreferencesFormNow();
            BeginDelayedPreferencesFocus(80);
            BeginDelayedPreferencesFocus(250);
            BeginDelayedPreferencesFocus(600);
        }

        private void BeginDelayedPreferencesFocus(int delayMilliseconds)
        {
            var timer = new System.Windows.Forms.Timer { Interval = delayMilliseconds };
            timer.Tick += (s, e) =>
            {
                timer.Stop();
                timer.Dispose();
                FocusPreferencesFormNow();
            };
            timer.Start();
        }

        private void FocusPreferencesFormNow()
        {
            if (preferencesForm == null || preferencesForm.IsDisposed) return;
            if (preferencesForm.WindowState == FormWindowState.Minimized)
            {
                preferencesForm.WindowState = FormWindowState.Normal;
            }
            if (!preferencesForm.Visible)
            {
                return;
            }
            var handle = preferencesForm.Handle;
            if (handle != IntPtr.Zero)
            {
                NativeMethods.ShowWindow(handle, NativeMethods.SW_RESTORE);
                NativeMethods.SetForegroundWindow(handle);
            }
            preferencesForm.Activate();
            preferencesForm.BringToFront();
            preferencesForm.Focus();
            preferencesForm.BeginInvoke(new Action(() =>
            {
                if (preferencesForm == null || preferencesForm.IsDisposed) return;
                if (preferencesForm.WindowState == FormWindowState.Minimized)
                {
                    preferencesForm.WindowState = FormWindowState.Normal;
                }
                var delayedHandle = preferencesForm.Handle;
                if (delayedHandle != IntPtr.Zero)
                {
                    NativeMethods.ShowWindow(delayedHandle, NativeMethods.SW_RESTORE);
                    NativeMethods.SetForegroundWindow(delayedHandle);
                }
                preferencesForm.Activate();
                preferencesForm.BringToFront();
                preferencesForm.Focus();
            }));
        }

        private void ApplyPreferences(AppSettings updated)
        {
            var nextDatabasePassword = databasePassword;
            if (updated.PasswordClearRequested)
            {
                nextDatabasePassword = string.Empty;
            }
            else if (!string.IsNullOrEmpty(updated.PlainDatabasePassword))
            {
                nextDatabasePassword = updated.PlainDatabasePassword;
            }
            if (!updated.DatabaseEncryptionEnabled)
            {
                nextDatabasePassword = string.Empty;
                updated.ProtectedDatabasePassword = string.Empty;
                updated.RememberDatabasePassword = false;
            }
            else if (updated.RememberDatabasePassword &&
                     string.IsNullOrWhiteSpace(updated.ProtectedDatabasePassword) &&
                     !string.IsNullOrEmpty(nextDatabasePassword))
            {
                updated.ProtectedDatabasePassword = DatabasePasswordProtector.Protect(nextDatabasePassword);
            }
            else if (!updated.RememberDatabasePassword)
            {
                updated.ProtectedDatabasePassword = string.Empty;
            }

            var databaseChanged =
                !string.Equals(settings.DatabasePath, updated.DatabasePath, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(settings.StorageMode, updated.StorageMode, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(settings.ServerUrl, updated.ServerUrl, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(settings.ServerToken, updated.ServerToken, StringComparison.Ordinal) ||
                !string.Equals(settings.ServerCaCertPem, updated.ServerCaCertPem, StringComparison.Ordinal) ||
                !string.Equals(settings.ServerCaHost, updated.ServerCaHost, StringComparison.OrdinalIgnoreCase);
            var wasServerStorageEnabled = IsServerStorageEnabled();
            var serverCacheBeforeStorageChange = wasServerStorageEnabled ? ServerCacheDatabasePath() : string.Empty;
            var activeChanged = settings.Active != updated.Active;
            var sendToChanged = settings.SendToEnabled != updated.SendToEnabled;
            var encryptionChanged =
                settings.DatabaseEncryptionEnabled != updated.DatabaseEncryptionEnabled ||
                settings.RememberDatabasePassword != updated.RememberDatabasePassword ||
                !string.Equals(settings.ProtectedDatabasePassword, updated.ProtectedDatabasePassword, StringComparison.Ordinal) ||
                !string.IsNullOrEmpty(updated.PlainDatabasePassword) ||
                updated.PasswordClearRequested;
            var startupChanged = settings.RunAtStartup != updated.RunAtStartup;
            var updatePolicyChanged =
                !string.Equals(settings.UpdateCheckFrequency, updated.UpdateCheckFrequency, StringComparison.OrdinalIgnoreCase) ||
                settings.InstallUpdatesSilently != updated.InstallUpdatesSilently;
            var autoRemoteCopyTurnedOn = !settings.AutoCopyLatestRemoteText && updated.AutoCopyLatestRemoteText;
            var saveListPositionTurnedOff = settings.SaveListPosition && !updated.SaveListPosition;
            var linksHistoryVisibilityChanged = settings.LinksHistoryEnabled != updated.LinksHistoryEnabled;
            var richTextHistoryVisibilityChanged = settings.RichTextHistoryEnabled != updated.RichTextHistoryEnabled;
            var oldSettingsDirectory = settingsStore.SettingsDirectory;
            settingsStore.Save(updated);
            databasePassword = nextDatabasePassword;
            settings.ShowHistoryHotkey = updated.ShowHistoryHotkey;
            settings.ToggleActiveHotkey = updated.ToggleActiveHotkey;
            settings.SaveCurrentClipboardHotkey = updated.SaveCurrentClipboardHotkey;
            settings.QuickCopyHotkeys = updated.QuickCopyHotkeys == null
                ? new List<QuickCopyBinding>()
                : updated.QuickCopyHotkeys.Select(b => new QuickCopyBinding { EntryId = b.EntryId, Hotkey = b.Hotkey, Mode = QuickPasteModes.Normalize(b.Mode) }).ToList();
            settings.AutoCopyLatestRemoteText = updated.AutoCopyLatestRemoteText;
            settings.PasteAfterEnter = updated.PasteAfterEnter;
            settings.DynamicHistoryMode = updated.DynamicHistoryMode;
            settings.RemoveDuplicates = updated.RemoveDuplicates;
            settings.SoundsEnabled = updated.SoundsEnabled;
            settings.ClipMergeEnabled = updated.ClipMergeEnabled;
            settings.ClipMergeWindowMilliseconds = ClipMergeDetector.NormalizeWindow(updated.ClipMergeWindowMilliseconds);
            settings.ClipMergeSeparatorMode = updated.ClipMergeSeparatorMode;
            settings.ClipMergeCustomSeparator = updated.ClipMergeCustomSeparator;
            settings.MultipleEntrySeparatorMode = updated.MultipleEntrySeparatorMode;
            settings.MultipleEntryCustomSeparator = updated.MultipleEntryCustomSeparator;
            settings.SaveListPosition = updated.SaveListPosition;
            settings.Active = updated.Active;
            settings.DatabasePath = updated.DatabasePath;
            settings.UseDefaultDatabasePath = updated.UseDefaultDatabasePath;
            settings.StorageMode = updated.StorageMode;
            settings.ServerUrl = updated.ServerUrl;
            settings.ServerToken = updated.ServerToken;
            settings.ServerCaCertPem = updated.ServerCaCertPem;
            settings.ServerCaHost = updated.ServerCaHost;
            settings.MaxHistoryEntries = updated.MaxHistoryEntries;
            settings.MaxHistoryDays = updated.MaxHistoryDays;
            settings.IgnoredProcesses = updated.IgnoredProcesses;
            settings.SortMode = updated.SortMode;
            settings.SortDescending = updated.SortDescending;
            settings.SendToEnabled = updated.SendToEnabled;
            settings.ShowHistoryAfterSendTo = updated.ShowHistoryAfterSendTo;
            settings.GroupFilter = updated.GroupFilter;
            settings.HistoryFilterType = updated.HistoryFilterType;
            settings.DeviceFilter = updated.DeviceFilter;
            settings.DeviceName = updated.DeviceName;
            settings.ConfirmDeletions = updated.ConfirmDeletions;
            settings.ConfirmSingleModifierHotkeys = updated.ConfirmSingleModifierHotkeys;
            settings.ConfirmWebsiteTitleRequests = updated.ConfirmWebsiteTitleRequests;
            settings.AutoNameCopiedWebsiteLinks = updated.AutoNameCopiedWebsiteLinks;
            settings.DuplicateMode = updated.DuplicateMode;
            settings.AutoGroupByApp = updated.AutoGroupByApp;
            settings.AutoRemoveUrlTracking = updated.AutoRemoveUrlTracking;
            settings.LinksHistoryEnabled = updated.LinksHistoryEnabled;
            settings.RichTextHistoryEnabled = updated.RichTextHistoryEnabled;
            settings.IncludeImagesInRichText = updated.RichTextHistoryEnabled && updated.IncludeImagesInRichText;
            settings.AutoAddImageFilesToRichText = settings.IncludeImagesInRichText && updated.AutoAddImageFilesToRichText;
            settings.LastSelectedHistoryTab = HistoryTabs.Normalize(updated.LastSelectedHistoryTab, settings.LinksHistoryEnabled, settings.RichTextHistoryEnabled);
            settings.HistoryTabOrder = HistoryTabs.NormalizeOrder(updated.HistoryTabOrder);
            settings.AutoRemoveUnavailableFileHistoryEvents = updated.AutoRemoveUnavailableFileHistoryEvents;
            settings.DiagnosticsFileHistoryLimit = updated.DiagnosticsFileHistoryLimit;
            settings.SensitiveDataMode = SensitiveDataExclusion.NormalizeMode(updated.SensitiveDataMode);
            settings.SensitiveDataPresetIds = updated.SensitiveDataPresetIds == null ? new List<string>() : new List<string>(updated.SensitiveDataPresetIds);
            settings.RunAtStartup = updated.RunAtStartup;
            settings.CaptureClipboardOnStartup = updated.CaptureClipboardOnStartup;
            settings.UpdateCheckFrequency = updated.UpdateCheckFrequency;
            settings.InstallUpdatesSilently = updated.InstallUpdatesSilently;
            settings.DatabaseEncryptionEnabled = updated.DatabaseEncryptionEnabled;
            settings.RememberDatabasePassword = updated.RememberDatabasePassword;
            settings.ProtectedDatabasePassword = updated.ProtectedDatabasePassword;
            settings.LastPreferencesTab = updated.LastPreferencesTab;
            store.SetMachineName(CurrentDeviceName());
            if (saveListPositionTurnedOff)
            {
                settings.LastSelectedIndex = -1;
            }
            var settingsDirectoryChanged = !string.Equals(oldSettingsDirectory, settingsStore.SettingsDirectory, StringComparison.OrdinalIgnoreCase);
            if (settingsDirectoryChanged)
            {
                SharedUpdateStateStore.PublishCurrentBuild(SharedExecutableSettingsDirectory(), Application.ExecutablePath);
                RestartSharedUpdateWatchers();
                sounds = new SoundService(appDirectory, settingsStore.SettingsDirectory);
                ReopenFileHistoryStore();
                ReopenSecretStore();
            }
            if (sendToChanged)
            {
                try
                {
                    SendToInstaller.SetInstalled(settings.SendToEnabled);
                }
                catch (Exception ex)
                {
                    MessageBox.Show("Could not update the Send To shortcut.\r\n\r\n" + ex.Message, "Clipman Send To", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            }
            if (databaseChanged)
            {
                if (wasServerStorageEnabled && !IsServerStorageEnabled())
                {
                    MergeServerCacheIntoConfiguredDatabase(serverCacheBeforeStorageChange);
                }
                ResolveDatabasePassword();
                ResolveDatabaseLocation();
                SeedServerCacheFromConfiguredDatabase();
                store.SetDatabasePath(EffectiveTextHistoryDatabasePath(), CurrentDatabasePassword);
                ConfigureTextHistoryServerStorage();
                ResetRemoteAutoCopyBaseline();
                ReopenSecretStore();
            }
            else if (encryptionChanged)
            {
                if (!updated.PasswordClearRequested)
                {
                    ResolveDatabasePassword();
                }
                store.ChangeDatabasePassword();
                ConfigureTextHistoryServerStorage();
                if (!settingsDirectoryChanged)
                {
                    fileEventStore.ChangeDatabasePassword();
                }
                if (secretStore != null)
                {
                    secretStore.ChangeDatabasePassword();
                }
                ReopenSecretStore();
            }
            RegisterHotkeys();
            if (startupChanged)
            {
                ApplyStartupRegistration(true);
            }
            if (updatePolicyChanged)
            {
                ScheduleUpdateChecks();
            }
            if (autoRemoteCopyTurnedOn)
            {
                ResetRemoteAutoCopyBaseline();
            }
            UpdateTray();
            if (activeChanged)
            {
                if (settings.Active) sounds.On(settings.SoundsEnabled); else sounds.Off(settings.SoundsEnabled);
            }
            if (historyForm != null && !historyForm.IsDisposed && (databaseChanged || linksHistoryVisibilityChanged || richTextHistoryVisibilityChanged))
            {
                historyForm.RefreshTabsAndReload();
            }
        }

        private void ShowSecrets()
        {
            var password = CurrentDatabasePassword();
            if (string.IsNullOrEmpty(password))
            {
                MessageBox.Show(
                    "Secrets require a history password. Open Preferences, set a history password, and enable Remember history password on this computer if you want secrets available after restart.",
                    "Clipman Secrets",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning);
                return;
            }
            if (!ConfirmSecretsPassword(password))
            {
                return;
            }

            if (secretStore == null)
            {
                secretStore = new SecretStore(DefaultSecretsDatabasePath(), CurrentDatabasePassword);
            }

            if (secretsForm == null || secretsForm.IsDisposed)
            {
                secretsForm = new SecretsForm(secretStore, RegisterHotkeys, QuickPasteSecret);
                secretsForm.FormClosed += (s, e) => secretsForm = null;
            }
            if (historyForm != null && !historyForm.IsDisposed && historyForm.Visible)
            {
                secretsForm.ShowDialog(historyForm);
            }
            else
            {
                secretsForm.ShowDialog();
            }
            secretsForm = null;
        }

        private bool ConfirmSecretsPassword(string currentPassword)
        {
            var entered = PasswordPromptForm.Ask(
                "Unlock Clipman Secrets",
                "Enter the current history password to open Secrets.");
            if (entered.Length == 0) return false;
            if (string.Equals(entered, currentPassword, StringComparison.Ordinal)) return true;
            MessageBox.Show(
                "The history password did not match. Secrets were not opened.",
                "Clipman Secrets",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
            return false;
        }

        public void CopyEntryToClipboard(ClipEntry entry)
        {
            if (entry == null) return;
            IgnoreClipboardChanges(1);
            SetEntryClipboard(entry);
            store.MarkUsed(entry.Id);
            sounds.Copy(settings.SoundsEnabled);
        }

        private void QueueAutomaticWebsiteTitle(ClipEntry entry, bool deliberate)
        {
            if (deliberate || !settings.AutoNameCopiedWebsiteLinks || entry == null ||
                !string.IsNullOrWhiteSpace(entry.Name) || string.IsNullOrWhiteSpace(entry.Id)) return;
            Uri uri;
            string reason;
            if (!LinkPresentation.TryGetUri(entry, out uri) || !LinkTitleFetcher.CanOffer(uri, out reason)) return;

            var startWorker = false;
            lock (automaticWebsiteTitleLock)
            {
                if (automaticWebsiteTitleEntryIds.Contains(entry.Id) || automaticWebsiteTitleQueue.Count >= 8) return;
                automaticWebsiteTitleEntryIds.Add(entry.Id);
                automaticWebsiteTitleQueue.Enqueue(new AutomaticWebsiteTitleRequest
                {
                    EntryId = entry.Id,
                    OriginalText = entry.Text ?? string.Empty,
                    Uri = uri
                });
                if (!automaticWebsiteTitleWorkerRunning)
                {
                    automaticWebsiteTitleWorkerRunning = true;
                    startWorker = true;
                }
            }
            if (startWorker) ThreadPool.QueueUserWorkItem(_ => ProcessAutomaticWebsiteTitles());
        }

        private void ProcessAutomaticWebsiteTitles()
        {
            while (true)
            {
                AutomaticWebsiteTitleRequest request;
                lock (automaticWebsiteTitleLock)
                {
                    if (automaticWebsiteTitleQueue.Count == 0)
                    {
                        automaticWebsiteTitleWorkerRunning = false;
                        return;
                    }
                    request = automaticWebsiteTitleQueue.Dequeue();
                }

                if (!settings.AutoNameCopiedWebsiteLinks)
                {
                    lock (automaticWebsiteTitleLock) automaticWebsiteTitleEntryIds.Remove(request.EntryId);
                    continue;
                }

                var result = LinkTitleFetcher.Fetch(request.Uri);
                BeginInvokeIfReady(() => CompleteAutomaticWebsiteTitle(request, result));
            }
        }

        private void CompleteAutomaticWebsiteTitle(AutomaticWebsiteTitleRequest request, LinkTitleFetchResult result)
        {
            lock (automaticWebsiteTitleLock) automaticWebsiteTitleEntryIds.Remove(request.EntryId);
            if (!settings.AutoNameCopiedWebsiteLinks) return;
            if (!result.Success)
            {
                Program.WriteRuntimeLog("Automatic website title lookup failed for " + request.Uri.Host + ".", new InvalidOperationException(result.Error));
                return;
            }
            if (!store.TrySetNameIfUnchanged(request.EntryId, request.OriginalText, result.Title))
            {
                Program.WriteRuntimeLog("Automatic website title was not applied because the entry changed.", null);
            }
        }

        public void CopyEntriesToClipboard(List<ClipEntry> entries)
        {
            if (entries == null || entries.Count == 0) return;
            var data = new DataObject();
            data.SetText(
                string.Join(
                    MultipleEntrySeparator.Resolve(settings.MultipleEntrySeparatorMode, settings.MultipleEntryCustomSeparator),
                    entries.Select(ResolvedEntryText)),
                TextDataFormat.UnicodeText);
            data.SetData(ClipmanClipboardData.EntriesFormat, ClipmanClipboardData.SerializeEntries(entries));
            IgnoreClipboardChanges(1);
            Clipboard.SetDataObject(data, true);
            foreach (var entry in entries)
            {
                store.MarkUsed(entry.Id);
            }
            sounds.Copy(settings.SoundsEnabled);
        }

        private bool CopyPlainTextToClipboard(string text, List<ClipEntry> entries)
        {
            try
            {
                IgnoreClipboardChanges(1);
                Clipboard.SetText(text ?? string.Empty, TextDataFormat.UnicodeText);
                foreach (var entry in entries ?? new List<ClipEntry>())
                {
                    if (entry != null) store.MarkUsed(entry.Id);
                }
                sounds.Copy(settings.SoundsEnabled);
                return true;
            }
            catch (Exception ex)
            {
                ClearIgnoredClipboardChanges();
                sounds.Skip(settings.SoundsEnabled);
                Program.WriteRuntimeLog("Clipman could not copy plain text to the clipboard.", ex);
                return false;
            }
        }

        private void CopySensitiveTextToClipboard(string text)
        {
            IgnoreClipboardChanges(1);
            Clipboard.SetText(text ?? string.Empty, TextDataFormat.UnicodeText);
        }

        internal void HandleHotkey(int id)
        {
            if (id == ShowHotkeyId)
            {
                ToggleHistoryWindow();
            }
            else if (id == ToggleHotkeyId || id == ToggleHotkeyAlternateId)
            {
                ToggleActive();
            }
            else if (id == SaveCurrentClipboardHotkeyId)
            {
                SaveCurrentClipboardToHistory();
            }
            else if (quickCopyHotkeyEntryIds.ContainsKey(id))
            {
                QuickPasteEntry(quickCopyHotkeyEntryIds[id]);
            }
            else if (secretHotkeyEntryIds.ContainsKey(id))
            {
                QuickPasteSecret(secretStore.GetEntryById(secretHotkeyEntryIds[id]));
            }
        }

        private void SaveCurrentClipboardToHistory()
        {
            HandleClipboardUpdate(true);
        }

        private void TryCaptureClipboardOnStartup()
        {
            try
            {
                HandleClipboardUpdate();
            }
            catch (ExternalException ex)
            {
                if ((uint)ex.ErrorCode != 0x800401D0U) throw;
                Program.WriteRuntimeLog("The clipboard was busy during startup; Clipman will retry the initial capture.", ex);
                clipboardFloodRecoveryTimer.Stop();
                clipboardFloodRecoveryTimer.Start();
            }
        }

        internal void HandleClipboardUpdate(bool deliberate = false, uint clipboardSequence = 0, bool recovery = false)
        {
            if (!deliberate && clipboardSequence == 0)
            {
                clipboardSequence = NativeMethods.GetClipboardSequenceNumber();
            }
            if (!deliberate && !clipboardNotifications.ShouldProcess(clipboardSequence, recovery))
            {
                return;
            }
            if (!deliberate && ignoredClipboardChangeCount > 0)
            {
                ignoredClipboardChangeCount--;
                return;
            }

            var sourceProcessName = ClipboardOwnerProcessName();
            if (string.IsNullOrWhiteSpace(sourceProcessName))
            {
                sourceProcessName = ForegroundProcessName();
            }

            if (!deliberate && IsClipmanProcess(sourceProcessName))
            {
                return;
            }

            if (!deliberate)
            {
                var floodDecision = clipboardFloodGuards.Observe(
                    NormalizeProcessName(sourceProcessName),
                    ClipboardFloodGuard.MonotonicMilliseconds());
                if (floodDecision != ClipboardFloodDecision.Allow)
                {
                    clipboardFloodRecoveryTimer.Stop();
                    clipboardFloodRecoveryTimer.Start();
                    return;
                }
                clipboardFloodRecoveryTimer.Stop();
            }

            if (!deliberate && !settings.Active)
            {
                clipMergeDetector.Reset();
                sounds.Skip(settings.SoundsEnabled);
                return;
            }

            if (!deliberate && IsIgnoredProcess(sourceProcessName))
            {
                clipMergeDetector.Reset();
                sounds.Skip(settings.SoundsEnabled);
                return;
            }

            var privacySignal = ClipboardPrivacySignals.Detect();
            if (privacySignal != null)
            {
                clipMergeDetector.Reset();
                lastClipboardPrivacySignal = privacySignal.Reason;
                sounds.Exclude(settings.SoundsEnabled);
                return;
            }

            lastClipboardPrivacySignal = "None";

            if (settings.RichTextHistoryEnabled && settings.IncludeImagesInRichText &&
                !Clipboard.ContainsText(TextDataFormat.UnicodeText) && RichImageData.ClipboardHasStandaloneImage())
            {
                clipMergeDetector.Reset();
                var imageCapture = RichImageData.CaptureFromClipboard();
                if (imageCapture == null)
                {
                    sounds.Skip(settings.SoundsEnabled);
                    return;
                }
                if (store.EmbeddedImageByteCount() + imageCapture.ImageBytes > RichImageData.MaximumDatabaseImageBytes)
                {
                    Program.WriteRuntimeLog("Clipman did not store a clipboard image because the 8 MiB history image budget is full.", null);
                    sounds.Skip(settings.SoundsEnabled);
                    return;
                }
                var imageGroup = settings.AutoGroupByApp ? FriendlyProcessName(sourceProcessName) : string.Empty;
                store.AddText(imageCapture.Text, settings.DuplicateMode, settings.MaxHistoryEntries, settings.MaxHistoryDays, imageGroup, imageCapture.RichText);
                if (IsStorageUnavailable())
                {
                    sounds.Skip(settings.SoundsEnabled);
                    UpdateTray();
                    return;
                }
                RememberReceivedHistoryTab(HistoryTabs.RichText);
                sounds.Copy(settings.SoundsEnabled);
                return;
            }

            ClipboardEventSummary fileSummary = null;
            try
            {
                fileSummary = ReadClipboardEventSummary(sourceProcessName);
            }
            catch
            {
            }
            if (fileSummary != null)
            {
                HandleCapturedFileEvent(fileSummary, sourceProcessName, deliberate, clipboardSequence);
                if (settings.RichTextHistoryEnabled && settings.IncludeImagesInRichText && settings.AutoAddImageFilesToRichText)
                {
                    string imageFilePath;
                    string ignoredFailureMessage;
                    if (RichImageData.TryGetSingleClipboardImageFile(out imageFilePath, out ignoredFailureMessage))
                    {
                        AddCopiedImageFileToRichTextAsync(imageFilePath, sourceProcessName);
                    }
                }
                return;
            }

            if (!Clipboard.ContainsText(TextDataFormat.UnicodeText))
            {
                clipMergeDetector.Reset();
                sounds.Skip(settings.SoundsEnabled);
                return;
            }

            string text;
            try
            {
                text = Clipboard.GetText(TextDataFormat.UnicodeText);
            }
            catch
            {
                return;
            }

            if (string.IsNullOrEmpty(text))
            {
                clipMergeDetector.Reset();
                if (deliberate)
                {
                    sounds.Skip(settings.SoundsEnabled);
                }
                return;
            }

            var richText = settings.RichTextHistoryEnabled ? RichTextData.CaptureFromClipboard() : null;
            var rawText = text;

            if (!deliberate && store.HasRecentlyTouchedRemoteText(text, CurrentDeviceName(), 90000))
            {
                return;
            }

            var sensitiveMatch = deliberate ? null : SensitiveDataExclusion.FindMatch(text, settings);
            if (sensitiveMatch != null)
            {
                clipMergeDetector.Reset();
                sounds.Exclude(settings.SoundsEnabled);
                return;
            }

            if (!deliberate && settings.AutoRemoveUrlTracking)
            {
                var cleaned = UrlTrackingCleaner.CleanText(text);
                if (!string.Equals(cleaned, text, StringComparison.Ordinal))
                {
                    text = cleaned;
                    richText = null;
                    try
                    {
                        IgnoreClipboardChanges(1);
                        Clipboard.SetText(text, TextDataFormat.UnicodeText);
                    }
                    catch
                    {
                        ClearIgnoredClipboardChanges();
                    }
                }
            }

            var group = settings.AutoGroupByApp ? FriendlyProcessName(sourceProcessName) : string.Empty;
            var textObservation = new ClipMergeObservation
            {
                Kind = ClipMergeKind.Text,
                Signature = rawText,
                SourceApplication = NormalizeProcessName(sourceProcessName),
                ChangeIdentifier = clipboardSequence,
                Payload = text
            };
            var mergeDecision = clipMergeDetector.Observe(
                textObservation,
                ClipboardFloodGuard.MonotonicMilliseconds(),
                settings.ClipMergeEnabled,
                settings.ClipMergeWindowMilliseconds,
                deliberate);
            if (mergeDecision.SuppressDuplicate)
            {
                return;
            }
            ClipEntry storedEntry;
            if (mergeDecision.ShouldMerge)
            {
                var baseText = Convert.ToString(mergeDecision.Base.Payload) ?? string.Empty;
                var mergedText = baseText + ClipMergeDetector.ResolveSeparator(settings.ClipMergeSeparatorMode, settings.ClipMergeCustomSeparator) + text;
                storedEntry = store.MergeCapturedText(
                    mergeDecision.Base.HistoryId,
                    mergeDecision.FirstTap.HistoryId,
                    mergedText,
                    settings.MaxHistoryEntries,
                    settings.MaxHistoryDays,
                    group);
                if (storedEntry != null)
                {
                    try
                    {
                        IgnoreClipboardChanges(1);
                        Clipboard.SetText(mergedText, TextDataFormat.UnicodeText);
                    }
                    catch
                    {
                        ClearIgnoredClipboardChanges();
                    }
                    textObservation.Signature = mergedText;
                    textObservation.Payload = mergedText;
                    clipMergeDetector.CompleteMerge(textObservation, storedEntry.Id);
                    RememberReceivedHistoryTab(LinkClassifier.IsLinkOnlyText(mergedText) ? HistoryTabs.Links : HistoryTabs.Text);
                    sounds.Merge(settings.SoundsEnabled);
                    return;
                }
            }

            storedEntry = store.AddText(text, settings.DuplicateMode, settings.MaxHistoryEntries, settings.MaxHistoryDays, group, richText);
            clipMergeDetector.SetCurrentHistoryId(storedEntry == null ? string.Empty : storedEntry.Id);
            if (IsStorageUnavailable())
            {
                sounds.Skip(settings.SoundsEnabled);
                UpdateTray();
                return;
            }

            RememberReceivedHistoryTab(richText != null ? HistoryTabs.RichText : LinkClassifier.IsLinkOnlyText(text) ? HistoryTabs.Links : HistoryTabs.Text);

            sounds.Copy(settings.SoundsEnabled);
            QueueAutomaticWebsiteTitle(storedEntry, deliberate);
        }

        private void AddCopiedImageFileToRichTextAsync(string path, string sourceProcessName)
        {
            ThreadPool.QueueUserWorkItem(_ =>
            {
                var capture = RichImageData.CaptureFromFile(path);
                if (capture == null)
                {
                    Program.WriteRuntimeLog("Clipman could not add the copied image file to Rich Text history because it was unavailable or invalid.", null);
                    return;
                }
                BeginInvokeIfReady(() =>
                {
                    if (!settings.RichTextHistoryEnabled || !settings.IncludeImagesInRichText || !settings.AutoAddImageFilesToRichText) return;
                    if (store.EmbeddedImageByteCount() + capture.ImageBytes > RichImageData.MaximumDatabaseImageBytes)
                    {
                        Program.WriteRuntimeLog("Clipman did not add a copied image file to Rich Text history because the 8 MiB history image budget is full.", null);
                        return;
                    }
                    var group = settings.AutoGroupByApp ? FriendlyProcessName(sourceProcessName) : string.Empty;
                    store.AddText(capture.Text, settings.DuplicateMode, settings.MaxHistoryEntries, settings.MaxHistoryDays, group, capture.RichText);
                    if (IsStorageUnavailable()) UpdateTray();
                });
            });
        }

        private void ClipboardFloodRecoveryTimerTick(object sender, EventArgs e)
        {
            clipboardFloodRecoveryTimer.Stop();
            try
            {
                HandleClipboardUpdate(false, NativeMethods.GetClipboardSequenceNumber(), true);
            }
            catch (ExternalException ex)
            {
                if ((uint)ex.ErrorCode != 0x800401D0U) throw;
                clipboardFloodRecoveryTimer.Start();
            }
        }

        private void RememberReceivedHistoryTab(string tabId)
        {
            if (!settings.DynamicHistoryMode) return;
            lastReceivedHistoryTab = tabId;
            receivedHistoryTabPending = true;
        }

        private void HandleCapturedFileEvent(ClipboardEventSummary summary, string sourceProcessName, bool deliberate, uint clipboardSequence)
        {
            if (summary == null || summary.Files == null || summary.Files.Count == 0) return;
            if (string.IsNullOrWhiteSpace(summary.Operation)) summary.Operation = "Copy";
            var observation = new ClipMergeObservation
            {
                Kind = ClipMergeKind.Files,
                Signature = FileMergeSignature(summary.Files, summary.Operation),
                SourceApplication = NormalizeProcessName(sourceProcessName),
                Operation = summary.Operation,
                ChangeIdentifier = clipboardSequence,
                Payload = CloneClipboardEvent(summary)
            };
            var decision = clipMergeDetector.Observe(
                observation,
                ClipboardFloodGuard.MonotonicMilliseconds(),
                settings.ClipMergeEnabled,
                settings.ClipMergeWindowMilliseconds,
                deliberate);

            if (decision.SuppressDuplicate)
            {
                return;
            }

            if (decision.ShouldMerge)
            {
                var baseSummary = decision.Base.Payload as ClipboardEventSummary;
                if (baseSummary != null)
                {
                    if (string.Equals(summary.Operation, "Move", StringComparison.OrdinalIgnoreCase) &&
                        (!ClipMergeFilePolicy.AreSourcesAvailable(baseSummary.Files) ||
                         !ClipMergeFilePolicy.AreSourcesAvailable(summary.Files)))
                    {
                        clipMergeDetector.RetainFirstTap(decision.FirstTap);
                        return;
                    }
                    var mergedFiles = baseSummary.Files
                        .Concat(summary.Files)
                        .Where(path => !string.IsNullOrWhiteSpace(path))
                        .Select(path => path.Trim())
                        .Distinct(StringComparer.OrdinalIgnoreCase)
                        .ToList();
                    var merged = new ClipboardEventSummary
                    {
                        CapturedAt = DateTime.Now,
                        Source = summary.Source,
                        Operation = summary.Operation,
                        SourceMachine = CurrentDeviceName(),
                        ContainsText = true,
                        FileCount = mergedFiles.Count,
                        Files = mergedFiles,
                        Formats = baseSummary.Formats.Concat(summary.Formats).Distinct(StringComparer.OrdinalIgnoreCase).ToList()
                    };
                    var saved = fileEventStore.MergeCapturedEvents(decision.Base.HistoryId, decision.FirstTap.HistoryId, merged);
                    if (saved != null && string.IsNullOrWhiteSpace(fileEventStore.LastStorageError))
                    {
                        WriteMergedFilesToClipboard(mergedFiles, merged.Operation);
                        observation.Signature = FileMergeSignature(mergedFiles, merged.Operation);
                        observation.Payload = CloneClipboardEvent(merged);
                        clipMergeDetector.CompleteMerge(observation, saved.Id);
                        RememberReceivedHistoryTab(HistoryTabs.Files);
                        sounds.Merge(settings.SoundsEnabled);
                        return;
                    }
                }
            }

            var stored = fileEventStore.Add(summary);
            clipMergeDetector.SetCurrentHistoryId(stored == null ? string.Empty : stored.Id);
            if (settings.AutoRemoveUnavailableFileHistoryEvents)
            {
                fileEventStore.RemoveUnavailableEvents();
            }
            if (string.IsNullOrWhiteSpace(fileEventStore.LastStorageError))
            {
                RememberReceivedHistoryTab(HistoryTabs.Files);
                sounds.Copy(settings.SoundsEnabled);
            }
            else
            {
                sounds.Skip(settings.SoundsEnabled);
            }
        }

        private void WriteMergedFilesToClipboard(IEnumerable<string> paths, string operation)
        {
            var files = (paths ?? Enumerable.Empty<string>()).Where(path => !string.IsNullOrWhiteSpace(path)).ToList();
            if (files.Count == 0) return;
            var fileList = new StringCollection();
            fileList.AddRange(files.ToArray());
            var data = new DataObject();
            data.SetFileDropList(fileList);
            data.SetText(string.Join(Environment.NewLine, files), TextDataFormat.UnicodeText);
            var effect = string.Equals(operation, "Move", StringComparison.OrdinalIgnoreCase) ? 2 : 1;
            data.SetData("Preferred DropEffect", false, new MemoryStream(BitConverter.GetBytes(effect)));
            try
            {
                IgnoreClipboardChanges(1);
                Clipboard.SetDataObject(data, true);
            }
            catch
            {
                ClearIgnoredClipboardChanges();
            }
        }

        private static string FileMergeSignature(IEnumerable<string> paths, string operation)
        {
            return (operation ?? string.Empty).Trim().ToUpperInvariant() + "\n" + string.Join("\n",
                (paths ?? Enumerable.Empty<string>())
                    .Where(path => !string.IsNullOrWhiteSpace(path))
                    .Select(path => path.Trim().ToUpperInvariant())
                    .OrderBy(path => path, StringComparer.Ordinal));
        }

        private List<ClipboardEventSummary> GetRecentClipboardEvents()
        {
            return fileEventStore.GetEvents(settings.FileHistorySortMode, settings.FileHistorySortDescending);
        }

        private int DeleteRecentClipboardEvents(List<string> ids)
        {
            return fileEventStore.DeleteMany(ids);
        }

        private int ClearRecentClipboardEvents()
        {
            return fileEventStore.Clear();
        }

        private int RemoveUnavailableRecentClipboardEvents()
        {
            return fileEventStore.RemoveUnavailableEvents();
        }

        private bool ToggleRecentClipboardEventPinned(string id)
        {
            return fileEventStore.TogglePinned(id);
        }

        private void MoveRecentClipboardEvents(List<string> ids, int direction)
        {
            fileEventStore.MoveEvents(ids, direction);
        }

        private bool ClearTextHistory()
        {
            var password = CurrentDatabasePassword();
            if (!string.IsNullOrEmpty(password))
            {
                var entered = PasswordPromptForm.Ask(
                    "Clear Clipman history",
                    "Enter the history password to clear all saved text clipboard entries.");
                if (!string.Equals(entered, password, StringComparison.Ordinal))
                {
                    MessageBox.Show("The history password did not match. Clipboard history was not cleared.", "Clipman", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return false;
                }
            }

            var message =
                "Clear all saved text clipboard history?" +
                Environment.NewLine +
                Environment.NewLine +
                "This will remove every text entry from the current Clipman database. A timestamped backup will be created first.";
            if (MessageBox.Show(message, "Clear Clipman history", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes)
            {
                return false;
            }

            BackupDatabase(settings.DatabasePath, "before-clear-history");
            store.ReplaceAll(new List<ClipEntry>());
            return true;
        }

        private static void BackupDatabase(string databasePath, string reason)
        {
            if (string.IsNullOrWhiteSpace(databasePath) || !File.Exists(databasePath)) return;
            var directory = Path.GetDirectoryName(databasePath);
            var name = Path.GetFileNameWithoutExtension(databasePath);
            var extension = Path.GetExtension(databasePath);
            if (string.IsNullOrEmpty(directory)) directory = AppDomain.CurrentDomain.BaseDirectory;
            if (string.IsNullOrEmpty(name)) name = "clipman-history";
            if (string.IsNullOrEmpty(extension)) extension = ".clipdb";
            var safeReason = string.IsNullOrWhiteSpace(reason) ? "backup" : reason.Trim();
            var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
            var backupPath = Path.Combine(directory, name + "." + safeReason + "-" + stamp + extension);
            File.Copy(databasePath, backupPath, false);
        }

        private static ClipboardEventSummary CloneClipboardEvent(ClipboardEventSummary source)
        {
            if (source == null) return null;
            return new ClipboardEventSummary
            {
                Id = source.Id,
                CapturedAt = source.CapturedAt,
                Source = source.Source ?? string.Empty,
                Operation = source.Operation ?? string.Empty,
                SourceMachine = source.SourceMachine ?? string.Empty,
                ContainsText = source.ContainsText,
                FileCount = source.FileCount,
                Files = source.Files == null ? new List<string>() : source.Files.ToList(),
                Formats = source.Formats == null ? new List<string>() : source.Formats.ToList(),
                Pinned = source.Pinned,
                ManualOrder = source.ManualOrder
            };
        }

        private ClipboardEventSummary ReadClipboardEventSummary(string sourceProcessName)
        {
            var data = Clipboard.GetDataObject();
            if (data == null) return null;
            var formats = data.GetFormats(false) ?? new string[0];
            var hasText = data.GetDataPresent(DataFormats.UnicodeText, false) || data.GetDataPresent(DataFormats.Text, false);
            var hasFiles = data.GetDataPresent(DataFormats.FileDrop, false);
            if (!hasFiles && hasText)
            {
                return null;
            }

            var summary = new ClipboardEventSummary
            {
                CapturedAt = DateTime.Now,
                Source = FriendlyProcessName(sourceProcessName),
                SourceMachine = CurrentDeviceName(),
                ContainsText = hasText,
                Formats = formats.ToList(),
                Operation = ClipboardDropEffect(data)
            };

            if (hasFiles)
            {
                var files = data.GetData(DataFormats.FileDrop, false) as string[];
                if (files != null)
                {
                    summary.Files = files.ToList();
                    summary.FileCount = files.Length;
                }
            }

            return summary;
        }

        private static string ClipboardDropEffect(IDataObject data)
        {
            try
            {
                if (!data.GetDataPresent("Preferred DropEffect", false)) return string.Empty;
                var stream = data.GetData("Preferred DropEffect", false) as MemoryStream;
                if (stream == null || stream.Length < 4) return string.Empty;
                var bytes = stream.ToArray();
                var value = BitConverter.ToInt32(bytes, 0);
                return DescribeDropEffect(value);
            }
            catch
            {
                return string.Empty;
            }
        }

        internal static string DescribeDropEffect(int value)
        {
            var parts = new List<string>();
            if ((value & 1) == 1) parts.Add("Copy");
            if ((value & 2) == 2) parts.Add("Move");
            if ((value & 4) == 4) parts.Add("Link");
            var knownBits = value & 7;
            if (parts.Count > 0 && knownBits == value)
            {
                return string.Join(" or ", parts);
            }

            switch (value)
            {
                case 0: return string.Empty;
                default: return "Unknown operation " + value;
            }
        }

        private ContextMenuStrip BuildTrayMenu()
        {
            var menu = new ContextMenuStrip();
            var storageMessage = StorageUnavailableMessage();
            if (!string.IsNullOrWhiteSpace(storageMessage))
            {
                var unavailable = new ToolStripMenuItem("Storage unavailable")
                {
                    Enabled = false,
                    ToolTipText = storageMessage
                };
                menu.Items.Add(unavailable);
                menu.Items.Add("&Retry storage", null, (s, e) => RetryStorage());
                menu.Items.Add("-");
            }

            menu.Items.Add("&Show or hide history\t" + settings.ShowHistoryHotkey, null, (s, e) => ToggleHistoryWindow());
            menu.Items.Add((settings.Active ? "Turn &off" : "Turn &on") + "\t" + settings.ToggleActiveHotkey, null, (s, e) => ToggleActive());
            var saveClipboardText = "Save current &clipboard to history";
            if (!string.IsNullOrWhiteSpace(settings.SaveCurrentClipboardHotkey))
            {
                saveClipboardText += "\t" + settings.SaveCurrentClipboardHotkey;
            }
            menu.Items.Add(saveClipboardText, null, (s, e) => SaveCurrentClipboardToHistory());
            menu.Items.Add("&Secrets...\tCtrl+Shift+E", null, (s, e) => ShowSecrets());
            menu.Items.Add("&Preferences...", null, (s, e) => ShowPreferencesFromTray());
            menu.Items.Add("Open &settings folder\tCtrl+Shift+O", null, (s, e) => OpenSettingsFolder());
            menu.Items.Add("-");
            menu.Items.Add("E&xit", null, (s, e) => ExitThread());
            return menu;
        }

        private void OpenSettingsFolder()
        {
            try
            {
                Directory.CreateDirectory(settingsStore.SettingsDirectory);
                Process.Start(new ProcessStartInfo
                {
                    FileName = settingsStore.SettingsDirectory,
                    UseShellExecute = true
                });
            }
            catch (Exception ex)
            {
                MessageBox.Show("Clipman could not open the settings folder.\r\n\r\n" + ex.Message, "Clipman", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        private void RetryStorage()
        {
            if (Interlocked.CompareExchange(ref storageRetryInProgress, 1, 0) != 0) return;

            ThreadPool.QueueUserWorkItem(delegate
            {
                var result = StorageRetryOperation.Execute(store.Reload, fileEventStore.Reload);
                if (result.TextHistoryError != null)
                {
                    store.RecordServerRetryFailure(result.TextHistoryError);
                }
                if (!result.Succeeded) Program.WriteRuntimeLog("The explicit storage retry failed.", result.Error);

                Interlocked.Exchange(ref storageRetryInProgress, 0);
                try
                {
                    if (invoker != null && invoker.IsHandleCreated)
                    {
                        invoker.BeginInvoke(new Action(delegate
                        {
                            UpdateTray();
                            if (!result.Succeeded)
                            {
                                MessageBox.Show(
                                    "Clipman could not reconnect to storage. It will keep using the local cache and retry automatically.\r\n\r\n" + result.Error.Message,
                                    "Clipman storage unavailable",
                                    MessageBoxButtons.OK,
                                    MessageBoxIcon.Warning);
                            }
                        }));
                    }
                }
                catch (InvalidOperationException)
                {
                }
            });
        }

        private void RegisterHotkeys()
        {
            NativeMethods.UnregisterHotKey(messageWindow.Handle, ShowHotkeyId);
            NativeMethods.UnregisterHotKey(messageWindow.Handle, ToggleHotkeyId);
            NativeMethods.UnregisterHotKey(messageWindow.Handle, SaveCurrentClipboardHotkeyId);
            NativeMethods.UnregisterHotKey(messageWindow.Handle, ToggleHotkeyAlternateId);
            foreach (var hotkeyId in quickCopyHotkeyEntryIds.Keys.ToList())
            {
                NativeMethods.UnregisterHotKey(messageWindow.Handle, hotkeyId);
            }
            foreach (var hotkeyId in secretHotkeyEntryIds.Keys.ToList())
            {
                NativeMethods.UnregisterHotKey(messageWindow.Handle, hotkeyId);
            }
            quickCopyHotkeyEntryIds.Clear();
            secretHotkeyEntryIds.Clear();
            showHotkeyRegistered = false;
            toggleHotkeyRegistered = false;
            saveCurrentClipboardHotkeyRegistered = false;
            toggleAlternateHotkeyRegistered = false;
            quickCopyHotkeysRegistered = 0;
            secretHotkeysRegistered = 0;
            PruneInvalidQuickPasteBindings();

            HotkeyDefinition show;
            if (HotkeyDefinition.TryParse(settings.ShowHistoryHotkey, out show))
            {
                showHotkeyRegistered = NativeMethods.RegisterHotKey(messageWindow.Handle, ShowHotkeyId, GlobalHotkeyModifiers(show.Modifiers), show.Key);
            }

            HotkeyDefinition toggle;
            if (HotkeyDefinition.TryParse(settings.ToggleActiveHotkey, out toggle))
            {
                toggleHotkeyRegistered = NativeMethods.RegisterHotKey(messageWindow.Handle, ToggleHotkeyId, GlobalHotkeyModifiers(toggle.Modifiers), toggle.Key);
                if (settings.ToggleActiveHotkey.Trim().Equals("Ctrl+Alt+`", StringComparison.OrdinalIgnoreCase))
                {
                    toggleAlternateHotkeyRegistered = NativeMethods.RegisterHotKey(messageWindow.Handle, ToggleHotkeyAlternateId, GlobalHotkeyModifiers(toggle.Modifiers), Keys.Oem8);
                }
            }

            HotkeyDefinition saveCurrentClipboard;
            if (HotkeyDefinition.TryParse(settings.SaveCurrentClipboardHotkey, out saveCurrentClipboard))
            {
                saveCurrentClipboardHotkeyRegistered = NativeMethods.RegisterHotKey(messageWindow.Handle, SaveCurrentClipboardHotkeyId, GlobalHotkeyModifiers(saveCurrentClipboard.Modifiers), saveCurrentClipboard.Key);
            }

            var quickCopyId = QuickCopyHotkeyBaseId;
            var usedHotkeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            usedHotkeys.Add((settings.ShowHistoryHotkey ?? string.Empty).Trim());
            usedHotkeys.Add((settings.ToggleActiveHotkey ?? string.Empty).Trim());
            if (!string.IsNullOrWhiteSpace(settings.SaveCurrentClipboardHotkey))
            {
                usedHotkeys.Add(settings.SaveCurrentClipboardHotkey.Trim());
            }
            foreach (var binding in (settings.QuickCopyHotkeys ?? new List<QuickCopyBinding>())
                .Where(b => b != null && !string.IsNullOrWhiteSpace(b.EntryId) && !string.IsNullOrWhiteSpace(b.Hotkey))
                .OrderBy(b => b.EntryId, StringComparer.OrdinalIgnoreCase))
            {
                var normalizedHotkey = binding.Hotkey.Trim();
                if (!usedHotkeys.Add(normalizedHotkey)) continue;

                HotkeyDefinition quickCopy;
                if (!HotkeyDefinition.TryParse(normalizedHotkey, out quickCopy)) continue;

                while (quickCopyHotkeyEntryIds.ContainsKey(quickCopyId))
                {
                    quickCopyId++;
                }

                if (NativeMethods.RegisterHotKey(messageWindow.Handle, quickCopyId, GlobalHotkeyModifiers(quickCopy.Modifiers), quickCopy.Key))
                {
                    quickCopyHotkeyEntryIds[quickCopyId] = binding.EntryId.Trim();
                    quickCopyHotkeysRegistered++;
                }
                quickCopyId++;
            }

            var secretId = SecretHotkeyBaseId;
            foreach (var secret in GetSecretEntriesSafe()
                .Where(s => s != null && !string.IsNullOrWhiteSpace(s.Id) && !string.IsNullOrWhiteSpace(s.Hotkey))
                .OrderBy(s => s.Id, StringComparer.OrdinalIgnoreCase))
            {
                var normalizedHotkey = secret.Hotkey.Trim();
                if (!usedHotkeys.Add(normalizedHotkey)) continue;

                HotkeyDefinition secretHotkey;
                if (!HotkeyDefinition.TryParse(normalizedHotkey, out secretHotkey)) continue;

                while (secretHotkeyEntryIds.ContainsKey(secretId))
                {
                    secretId++;
                }

                if (NativeMethods.RegisterHotKey(messageWindow.Handle, secretId, GlobalHotkeyModifiers(secretHotkey.Modifiers), secretHotkey.Key))
                {
                    secretHotkeyEntryIds[secretId] = secret.Id.Trim();
                    secretHotkeysRegistered++;
                }
                secretId++;
            }
        }

        private static NativeMethods.Modifiers GlobalHotkeyModifiers(NativeMethods.Modifiers modifiers)
        {
            return modifiers | NativeMethods.Modifiers.NoRepeat;
        }

        private void PruneInvalidQuickPasteBindings()
        {
            if (settings.QuickCopyHotkeys == null)
            {
                settings.QuickCopyHotkeys = new List<QuickCopyBinding>();
                return;
            }

            var cleaned = new List<QuickCopyBinding>();
            var usedEntryIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var usedHotkeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var changed = false;

            foreach (var binding in settings.QuickCopyHotkeys)
            {
                var entryId = binding == null ? string.Empty : (binding.EntryId ?? string.Empty).Trim();
                var hotkey = binding == null ? string.Empty : (binding.Hotkey ?? string.Empty).Trim();
                HotkeyDefinition parsed;
                var entry = string.IsNullOrWhiteSpace(entryId) ? null : store.GetEntryById(entryId);

                if (string.IsNullOrWhiteSpace(entryId) ||
                    string.IsNullOrWhiteSpace(hotkey) ||
                    !HotkeyDefinition.TryParse(hotkey, out parsed) ||
                    entry == null ||
                    string.IsNullOrEmpty(entry.Text) ||
                    !usedEntryIds.Add(entryId) ||
                    !usedHotkeys.Add(hotkey))
                {
                    changed = true;
                    continue;
                }

                if (!string.Equals(binding.EntryId, entryId, StringComparison.Ordinal) ||
                    !string.Equals(binding.Hotkey, hotkey, StringComparison.Ordinal))
                {
                    changed = true;
                }

                cleaned.Add(new QuickCopyBinding { EntryId = entryId, Hotkey = hotkey, Mode = QuickPasteModes.Normalize(binding.Mode) });
            }

            if (changed || cleaned.Count != settings.QuickCopyHotkeys.Count)
            {
                settings.QuickCopyHotkeys = cleaned;
                settingsStore.Save(settings);
            }
        }

        private void SaveSettings()
        {
            settingsStore.Save(settings);
        }

        private void PlayLaunchStateSound()
        {
            if (settings.Active)
            {
                sounds.On(settings.SoundsEnabled);
            }
            else
            {
                sounds.Off(settings.SoundsEnabled);
            }
        }

        private string ForegroundProcessName()
        {
            try
            {
                uint processId;
                var hwnd = NativeMethods.GetForegroundWindow();
                if (hwnd == IntPtr.Zero) return string.Empty;
                NativeMethods.GetWindowThreadProcessId(hwnd, out processId);
                if (processId == 0) return string.Empty;
                if ((int)processId == Process.GetCurrentProcess().Id) return "clipman";
                var process = Process.GetProcessById((int)processId);
                return NormalizeProcessName(process.ProcessName);
            }
            catch
            {
                return string.Empty;
            }
        }

        private string ClipboardOwnerProcessName()
        {
            try
            {
                uint processId;
                var hwnd = NativeMethods.GetClipboardOwner();
                if (hwnd == IntPtr.Zero) return string.Empty;
                NativeMethods.GetWindowThreadProcessId(hwnd, out processId);
                if (processId == 0) return string.Empty;
                if ((int)processId == Process.GetCurrentProcess().Id) return "clipman";
                var process = Process.GetProcessById((int)processId);
                return NormalizeProcessName(process.ProcessName);
            }
            catch
            {
                return string.Empty;
            }
        }

        private bool IsIgnoredProcess(string processName)
        {
            processName = NormalizeProcessName(processName);
            if (IsClipmanProcess(processName)) return true;
            if (settings.IgnoredProcesses == null || settings.IgnoredProcesses.Count == 0) return false;
            return settings.IgnoredProcesses.Any(p =>
                IgnoredProcessMatches(NormalizeProcessName(p), processName));
        }

        private static bool IgnoredProcessMatches(string ignoredProcessName, string processName)
        {
            if (string.IsNullOrWhiteSpace(ignoredProcessName) || string.IsNullOrWhiteSpace(processName)) return false;
            if (string.Equals(ignoredProcessName, processName, StringComparison.OrdinalIgnoreCase)) return true;
            return processName.StartsWith(ignoredProcessName + ".", StringComparison.OrdinalIgnoreCase) ||
                processName.StartsWith(ignoredProcessName + "-", StringComparison.OrdinalIgnoreCase) ||
                processName.StartsWith(ignoredProcessName + "_", StringComparison.OrdinalIgnoreCase) ||
                processName.StartsWith(ignoredProcessName + " ", StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsClipmanProcess(string processName)
        {
            return string.Equals(NormalizeProcessName(processName), "clipman", StringComparison.OrdinalIgnoreCase);
        }

        private static string NormalizeProcessName(string processName)
        {
            if (string.IsNullOrWhiteSpace(processName)) return string.Empty;
            var trimmed = processName.Trim();
            return trimmed.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
                ? Path.GetFileNameWithoutExtension(trimmed)
                : trimmed;
        }

        private static string FriendlyProcessName(string processName)
        {
            var normalized = NormalizeProcessName(processName);
            if (string.IsNullOrWhiteSpace(normalized)) return string.Empty;
            return normalized.Substring(0, 1).ToUpperInvariant() + (normalized.Length > 1 ? normalized.Substring(1) : string.Empty);
        }

        private string ClipboardFloodProtectionStatus(long nowMilliseconds)
        {
            var activeSources = clipboardFloodGuards.ActiveSources(nowMilliseconds)
                .Select(FriendlyProcessName)
                .Where(name => !string.IsNullOrWhiteSpace(name))
                .OrderBy(name => name, StringComparer.OrdinalIgnoreCase)
                .ToList();
            return activeSources.Count == 0
                ? "ready"
                : "suppressing rapid updates from " + string.Join(", ", activeSources);
        }

        private static string FormatDiagnosticTime(long unixMs)
        {
            if (unixMs <= 0) return "Never";
            return TimeUtil.FromUnixMs(unixMs).ToString("yyyy-MM-dd HH:mm:ss");
        }

        private string BuildDiagnosticsText()
        {
            var diagnosticNowMilliseconds = ClipboardFloodGuard.MonotonicMilliseconds();
            var sharedExecutableSettingsDirectory = SharedExecutableSettingsDirectory();
            var sharedUpdateCoordinationEnabled = SharedUpdateStateStore.CanCoordinateExecutable(
                sharedExecutableSettingsDirectory,
                Application.ExecutablePath);
            var sharedState = sharedUpdateCoordinationEnabled
                ? SharedUpdateStateStore.Load(sharedExecutableSettingsDirectory)
                : new SharedUpdateState();
            var serverStatus = store.GetServerSyncStatus();
            var entries = store.GetEntries();
            var richEntries = entries.Where(e => RichTextData.Normalize(e.RichText) != null).ToList();
            var richHtmlEntries = richEntries.Count(e => !string.IsNullOrEmpty(e.RichText.HtmlFragment));
            var richRtfEntries = richEntries.Count(e => !string.IsNullOrEmpty(e.RichText.RtfBase64));
            long richBytes = richEntries.Sum(e => (long)Encoding.UTF8.GetByteCount(e.RichText.HtmlFragment ?? string.Empty) + RichTextData.DecodedRtfByteCount(e.RichText.RtfBase64));
            var ignored = settings.IgnoredProcesses == null || settings.IgnoredProcesses.Count == 0
                ? "None"
                : string.Join(", ", settings.IgnoredProcesses);
            return
                "Clipman diagnostics\r\n\r\n" +
                "Active: " + settings.Active + "\r\n" +
                "Sounds enabled: " + settings.SoundsEnabled + "\r\n" +
                "Storage mode: " + settings.StorageMode + "\r\n" +
                "Server host: " + (string.IsNullOrWhiteSpace(settings.ServerUrl) ? "not set" : ServerSettingsSanitizer.CleanTransportUrl(settings.ServerUrl)) + "\r\n" +
                "Server sync enabled: " + serverStatus.Enabled + "\r\n" +
                "Server sync configured: " + serverStatus.Configured + "\r\n" +
                "Server sync revision: " + (string.IsNullOrWhiteSpace(serverStatus.Revision) ? "None" : serverStatus.Revision) + "\r\n" +
                "Server sync last poll: " + FormatDiagnosticTime(serverStatus.LastPollUnixMs) + "\r\n" +
                "Server sync last success: " + FormatDiagnosticTime(serverStatus.LastSuccessUnixMs) + "\r\n" +
                "Server sync last upload: " + FormatDiagnosticTime(serverStatus.LastUploadUnixMs) + "\r\n" +
                "Server sync next retry: " + FormatDiagnosticTime(serverStatus.NextPollUnixMs) + "\r\n" +
                "Server sync consecutive failures: " + serverStatus.ConsecutiveFailures + "\r\n" +
                "Database path: " + settings.DatabasePath + "\r\n" +
                "Database path type: " + (settings.UseDefaultDatabasePath ? "Default beside Clipman" : "Explicit") + "\r\n" +
                "Database storage status: " + (string.IsNullOrWhiteSpace(store.LastStorageError) ? "OK" : "Unavailable: " + store.LastStorageError) + "\r\n" +
                "Entries: " + entries.Count + "\r\n" +
                "Rich text history: " + (settings.RichTextHistoryEnabled ? "enabled" : "disabled") + "\r\n" +
                "Rich text images: " + (settings.IncludeImagesInRichText ? "enabled" : "disabled") + "\r\n" +
                "Automatically add copied image files to Rich Text: " + (settings.AutoAddImageFilesToRichText ? "enabled" : "disabled") + "\r\n" +
                "Rich text payloads: " + richEntries.Count + " entries (HTML " + richHtmlEntries + ", RTF " + richRtfEntries + ", " + richBytes + " bytes)\r\n" +
                "File history path: " + fileEventStore.DatabasePath + "\r\n" +
                "File history storage status: " + (string.IsNullOrWhiteSpace(fileEventStore.LastStorageError) ? "OK" : "Unavailable: " + fileEventStore.LastStorageError) + "\r\n" +
                "File history events: " + fileEventStore.GetEvents().Count + "\r\n" +
                "File history diagnostics limit: " + settings.DiagnosticsFileHistoryLimit + "\r\n" +
                "Auto remove unavailable file history events: " + settings.AutoRemoveUnavailableFileHistoryEvents + "\r\n" +
                "Show history hotkey: " + settings.ShowHistoryHotkey + " (" + (showHotkeyRegistered ? "registered" : "not registered") + ")\r\n" +
                "Toggle hotkey: " + settings.ToggleActiveHotkey + " (" + (toggleHotkeyRegistered ? "registered" : "not registered") + ")\r\n" +
                "Save current clipboard hotkey: " + (string.IsNullOrWhiteSpace(settings.SaveCurrentClipboardHotkey) ? "Not assigned" : settings.SaveCurrentClipboardHotkey + " (" + (saveCurrentClipboardHotkeyRegistered ? "registered" : "not registered") + ")") + "\r\n" +
                "Toggle alternate UK key: " + (toggleAlternateHotkeyRegistered ? "registered" : "not registered or not needed") + "\r\n" +
                "Quick Paste bindings: " + ((settings.QuickCopyHotkeys == null ? 0 : settings.QuickCopyHotkeys.Count) + " configured, " + quickCopyHotkeysRegistered + " registered") + "\r\n" +
                "Secrets: " + (GetSecretEntriesSafe().Count + " configured, " + secretHotkeysRegistered + " hotkeys registered") + "\r\n" +
                "Auto-copy received and command text: " + (settings.AutoCopyLatestRemoteText ? "on" : "off") + "\r\n" +
                "Paste after Enter: " + (settings.PasteAfterEnter ? "on" : "off") + "\r\n" +
                "Dynamic history mode: " + (settings.DynamicHistoryMode ? "on" : "off") + "\r\n" +
                "Build stamp: " + BuildInfo.BuildStampUtcMs + "\r\n" +
                "Executable hash: " + SharedUpdateStateStore.CurrentExeHash() + "\r\n" +
                "Shared executable update coordination: " + (sharedUpdateCoordinationEnabled ? "enabled for install-local Settings" : "disabled for separately stored settings") + "\r\n" +
                "Shared update state path: " + (sharedUpdateCoordinationEnabled ? SharedUpdateStateStore.StatePath(sharedExecutableSettingsDirectory) : "Not used") + "\r\n" +
                "Shared update state build stamp: " + (sharedState == null ? 0 : sharedState.BuildStampUtcMs) + "\r\n" +
                "Remove duplicates: " + settings.RemoveDuplicates + "\r\n" +
                "Duplicate mode: " + settings.DuplicateMode + "\r\n" +
                "Auto group by app: " + settings.AutoGroupByApp + "\r\n" +
                "Auto remove URL tracking: " + settings.AutoRemoveUrlTracking + "\r\n" +
                "Sensitive data mode: " + SensitiveDataExclusion.NormalizeMode(settings.SensitiveDataMode) + "\r\n" +
                "Sensitive data presets: " + SensitiveDataPresetSummary() + "\r\n" +
                "Last clipboard privacy signal: " + lastClipboardPrivacySignal + "\r\n" +
                "Clipboard flood protection: " + ClipboardFloodProtectionStatus(diagnosticNowMilliseconds) + "\r\n" +
                "Clipboard flood protection activations: " + clipboardFloodGuards.SuppressionCount + "\r\n" +
                "Clipboard flood events suppressed: " + clipboardFloodGuards.SuppressedEventCount + "\r\n" +
                "Run at startup: " + settings.RunAtStartup + "\r\n" +
                "Add clipboard item on startup: " + settings.CaptureClipboardOnStartup + "\r\n" +
                "Startup registration present: " + StartupRegistration.IsEnabled() + "\r\n" +
                "Update check frequency: " + settings.UpdateCheckFrequency + "\r\n" +
                "Install updates silently: " + settings.InstallUpdatesSilently + "\r\n" +
                "Database encryption enabled: " + settings.DatabaseEncryptionEnabled + "\r\n" +
                "Runtime crash log: " + Program.RuntimeLogPath() + "\r\n" +
                "User sound override folder: " + Path.Combine(settingsStore.SettingsDirectory, "sounds") + "\r\n" +
                "Group filter: " + settings.GroupFilter + "\r\n" +
                "Foreground process: " + FriendlyProcessName(ForegroundProcessName()) + "\r\n" +
                "Clipboard owner process: " + FriendlyProcessName(ClipboardOwnerProcessName()) + "\r\n" +
                "Maximum entries: " + (settings.MaxHistoryEntries <= 0 ? "No limit" : settings.MaxHistoryEntries.ToString()) + "\r\n" +
                "Maximum age: " + (settings.MaxHistoryDays <= 0 ? "No limit" : settings.MaxHistoryDays + " days") + "\r\n" +
                "Ignored applications: " + ignored + "\r\n\r\n" +
                BuildRecentClipboardEventsText();
        }

        private string SensitiveDataPresetSummary()
        {
            if (settings.SensitiveDataPresetIds == null || settings.SensitiveDataPresetIds.Count == 0)
            {
                return "None";
            }

            var names = SensitiveDataExclusion.BuiltInPresets
                .Where(p => settings.SensitiveDataPresetIds.Any(id => string.Equals(id, p.Id, StringComparison.OrdinalIgnoreCase)))
                .Select(p => p.Name)
                .ToList();
            return names.Count == 0 ? "None" : string.Join(", ", names);
        }

        private string BuildRecentClipboardEventsText()
        {
            var snapshots = fileEventStore.GetEvents();
            var total = snapshots.Count;
            var limit = settings.DiagnosticsFileHistoryLimit;
            if (limit < 0) limit = 0;
            if (limit > 200) limit = 200;

            if (total == 0)
            {
                return "File and non-text clipboard events: none recorded.";
            }

            if (limit == 0)
            {
                return "File and non-text clipboard events: " + total + " recorded. Details omitted by diagnostics preference.";
            }

            var lines = new List<string> { "File and non-text clipboard events: showing " + Math.Min(limit, total) + " of " + total + "." };
            foreach (var item in snapshots.Take(limit))
            {
                var title = item.CapturedAt.ToString("yyyy-MM-dd HH:mm:ss") +
                    " | Source: " + (string.IsNullOrWhiteSpace(item.Source) ? "Unknown" : item.Source);
                if (!string.IsNullOrWhiteSpace(item.Operation))
                {
                    title += " | Operation: " + item.Operation;
                }
                if (item.FileCount > 0)
                {
                    title += " | Files: " + item.FileCount;
                }
                if (item.ContainsText)
                {
                    title += " | Also contains text";
                }
                lines.Add(title);

                if (item.Files != null && item.Files.Count > 0)
                {
                    foreach (var file in item.Files.Take(20))
                    {
                        lines.Add("  " + file);
                    }
                    if (item.FileCount > 20)
                    {
                        lines.Add("  ... " + (item.FileCount - 20) + " more file(s)");
                    }
                }
                else if (item.Formats != null && item.Formats.Count > 0)
                {
                    lines.Add("  Formats: " + string.Join(", ", item.Formats.Take(12)));
                }
            }
            if (total > limit)
            {
                lines.Add("... " + (total - limit) + " more event(s) omitted by diagnostics preference.");
            }

            return string.Join("\r\n", lines);
        }

        private void StoreChanged(object sender, EventArgs e)
        {
            if (store.LastChangeWasExternal)
            {
                if (invoker != null && invoker.IsHandleCreated)
                {
                    invoker.BeginInvoke(new Action(MaybeAutoCopyLatestRemoteEntry));
                }
            }
            if (historyForm != null && !historyForm.IsDisposed)
            {
                historyForm.BeginInvoke(new Action(() => historyForm.Reload()));
            }
        }

        private void QuickPasteEntry(string entryId)
        {
            var entry = store.GetEntryById(entryId);
            if (entry == null || string.IsNullOrEmpty(entry.Text))
            {
                sounds.Skip(settings.SoundsEnabled);
                return;
            }

            try
            {
                var mode = QuickPasteModeForEntry(entryId);
                if (mode == QuickPasteModes.CopyOnly)
                {
                    IgnoreClipboardChanges(1);
                    SetEntryClipboard(entry);
                    store.MarkUsed(entry.Id);
                    sounds.Copy(settings.SoundsEnabled);
                    return;
                }

                IDataObject previousClipboard = null;
                if (mode == QuickPasteModes.PasteRestore)
                {
                    try
                    {
                        previousClipboard = SnapshotClipboardData();
                    }
                    catch
                    {
                        previousClipboard = null;
                    }
                }

                IgnoreClipboardChanges(mode == QuickPasteModes.PasteKeep ? 1 : 2);
                SetEntryClipboard(entry);
                store.MarkUsed(entry.Id);
                sounds.Copy(settings.SoundsEnabled);
                if (mode == QuickPasteModes.PasteKeep)
                {
                    BeginPasteOnly();
                }
                else
                {
                    BeginPasteThenRestore(previousClipboard);
                }
            }
            catch
            {
                ClearIgnoredClipboardChanges();
                sounds.Skip(settings.SoundsEnabled);
            }
        }

        private string QuickPasteModeForEntry(string entryId)
        {
            if (string.IsNullOrWhiteSpace(entryId) || settings.QuickCopyHotkeys == null) return QuickPasteModes.PasteRestore;
            var binding = settings.QuickCopyHotkeys.FirstOrDefault(b =>
                b != null && string.Equals(b.EntryId, entryId, StringComparison.OrdinalIgnoreCase));
            return binding == null ? QuickPasteModes.PasteRestore : QuickPasteModes.Normalize(binding.Mode);
        }

        private void QuickPasteSecret(SecretEntry secret)
        {
            if (secret == null || string.IsNullOrEmpty(secret.Value))
            {
                sounds.Skip(settings.SoundsEnabled);
                return;
            }

            try
            {
                IDataObject previousClipboard = null;
                try
                {
                    previousClipboard = SnapshotClipboardData();
                }
                catch
                {
                    previousClipboard = null;
                }

                IgnoreClipboardChanges(2);
                Clipboard.SetText(secret.Value, TextDataFormat.UnicodeText);
                sounds.Copy(settings.SoundsEnabled);
                BeginPasteThenRestore(previousClipboard);
            }
            catch
            {
                ClearIgnoredClipboardChanges();
                sounds.Skip(settings.SoundsEnabled);
            }
        }

        private List<SecretEntry> GetSecretEntriesSafe()
        {
            if (secretStore == null) return new List<SecretEntry>();
            try
            {
                return secretStore.GetEntries();
            }
            catch (Exception ex)
            {
                Debug.WriteLine("Could not read secrets store: " + ex);
                return new List<SecretEntry>();
            }
        }

        private void BeginPasteOnly()
        {
            ThreadPool.QueueUserWorkItem(_ =>
            {
                WaitForHotkeyModifiersReleased();
                BeginInvokeIfReady(SendCtrlVPaste);
            });
        }

        private void RememberPreviousForegroundWindow()
        {
            var foreground = NativeMethods.GetForegroundWindow();
            if (foreground == IntPtr.Zero) return;

            uint processId;
            NativeMethods.GetWindowThreadProcessId(foreground, out processId);
            if (processId == (uint)Process.GetCurrentProcess().Id) return;
            previousForegroundWindow = foreground;
        }

        private void PasteClipboardIntoPreviousApplication()
        {
            var target = previousForegroundWindow;
            previousForegroundWindow = IntPtr.Zero;
            if (target == IntPtr.Zero || !NativeMethods.IsWindow(target))
            {
                sounds.Skip(settings.SoundsEnabled);
                return;
            }

            ThreadPool.QueueUserWorkItem(_ =>
            {
                WaitForHotkeyModifiersReleased();
                BeginInvokeIfReady(() => ActivatePreviousWindowAndPaste(target, 2));
            });
        }

        private void ActivatePreviousWindowAndPaste(IntPtr target, int attemptsRemaining)
        {
            if (!NativeMethods.IsWindow(target))
            {
                sounds.Skip(settings.SoundsEnabled);
                return;
            }

            NativeMethods.SetForegroundWindow(target);
            var timer = new System.Windows.Forms.Timer { Interval = 100 };
            timer.Tick += (sender, args) =>
            {
                timer.Stop();
                timer.Dispose();
                if (NativeMethods.GetForegroundWindow() == target)
                {
                    SendCtrlVPaste();
                }
                else if (attemptsRemaining > 0)
                {
                    ActivatePreviousWindowAndPaste(target, attemptsRemaining - 1);
                }
                else
                {
                    sounds.Skip(settings.SoundsEnabled);
                }
            };
            timer.Start();
        }

        private void BeginPasteThenRestore(IDataObject previousClipboard)
        {
            ThreadPool.QueueUserWorkItem(_ =>
            {
                WaitForHotkeyModifiersReleased();
                BeginInvokeIfReady(SendCtrlVPaste);
                Thread.Sleep(600);
                BeginInvokeIfReady(() => RestoreClipboard(previousClipboard));
            });
        }

        private static IDataObject SnapshotClipboardData()
        {
            return SnapshotClipboardData(Clipboard.GetDataObject());
        }

        internal static IDataObject SnapshotClipboardData(IDataObject source)
        {
            if (source == null) return null;

            var snapshot = new DataObject();
            var copied = false;

            copied |= SnapshotText(source, snapshot, DataFormats.UnicodeText, TextDataFormat.UnicodeText);
            copied |= SnapshotText(source, snapshot, DataFormats.Text, TextDataFormat.Text);
            copied |= SnapshotText(source, snapshot, DataFormats.OemText, TextDataFormat.Text);
            copied |= SnapshotText(source, snapshot, DataFormats.Rtf, TextDataFormat.Rtf);
            copied |= SnapshotText(source, snapshot, DataFormats.Html, TextDataFormat.Html);
            copied |= SnapshotText(source, snapshot, DataFormats.CommaSeparatedValue, TextDataFormat.CommaSeparatedValue);

            try
            {
                if (source.GetDataPresent(DataFormats.FileDrop, false))
                {
                    var files = source.GetData(DataFormats.FileDrop, false) as string[];
                    if (files != null && files.Length > 0)
                    {
                        var fileList = new StringCollection();
                        fileList.AddRange(files);
                        snapshot.SetFileDropList(fileList);
                        copied = true;
                    }
                }
            }
            catch
            {
            }

            copied |= SnapshotImage(source, snapshot);
            copied |= SnapshotStream(source, snapshot, DataFormats.WaveAudio, MaximumClipboardSnapshotStreamLength);

            // Explorer uses this small stream to distinguish a cut from a copy. It is
            // independently cloneable, unlike delayed OLE formats such as metafiles.
            copied |= SnapshotStream(source, snapshot, "Preferred DropEffect", 64);

            return copied ? snapshot : null;
        }

        private static bool SnapshotImage(IDataObject source, DataObject snapshot)
        {
            try
            {
                if (!source.GetDataPresent(DataFormats.Bitmap, false)) return false;
                var image = source.GetData(DataFormats.Bitmap, false) as Image;
                if (image == null) return false;
                snapshot.SetImage(new Bitmap(image));
                return true;
            }
            catch
            {
                return false;
            }
        }

        private static bool SnapshotStream(IDataObject source, DataObject snapshot, string format, int maximumLength)
        {
            try
            {
                if (!source.GetDataPresent(format, false)) return false;
                var data = source.GetData(format, false);
                var stream = data as Stream;
                if (stream != null)
                {
                    if (stream.CanSeek && stream.Length > maximumLength) return false;
                    var copy = new MemoryStream();
                    var originalPosition = stream.CanSeek ? stream.Position : 0;
                    try
                    {
                        if (stream.CanSeek) stream.Position = 0;
                        CopyBounded(stream, copy, maximumLength);
                    }
                    finally
                    {
                        if (stream.CanSeek) stream.Position = originalPosition;
                    }
                    copy.Position = 0;
                    snapshot.SetData(format, false, copy);
                    return true;
                }

                var bytes = data as byte[];
                if (bytes != null && bytes.Length <= maximumLength)
                {
                    snapshot.SetData(format, false, bytes.ToArray());
                    return true;
                }
            }
            catch
            {
            }
            return false;
        }

        private static bool SnapshotText(IDataObject source, DataObject snapshot, string dataFormat, TextDataFormat textFormat)
        {
            try
            {
                if (!source.GetDataPresent(dataFormat, false)) return false;
                var text = source.GetData(dataFormat, false) as string;
                if (text == null || text.Length > MaximumClipboardSnapshotTextLength) return false;
                snapshot.SetText(text, textFormat);
                return true;
            }
            catch
            {
                return false;
            }
        }

        private static void CopyBounded(Stream source, Stream destination, int maximumLength)
        {
            var buffer = new byte[81920];
            var total = 0;
            while (true)
            {
                var read = source.Read(buffer, 0, Math.Min(buffer.Length, maximumLength - total + 1));
                if (read <= 0) return;
                total += read;
                if (total > maximumLength) throw new InvalidDataException("Clipboard format exceeds the snapshot limit.");
                destination.Write(buffer, 0, read);
            }
        }

        private void BeginInvokeIfReady(Action action)
        {
            if (action == null) return;
            if (invoker == null || invoker.IsDisposed || !invoker.IsHandleCreated) return;
            try
            {
                invoker.BeginInvoke(action);
            }
            catch
            {
                ClearIgnoredClipboardChanges();
            }
        }

        private static void WaitForHotkeyModifiersReleased()
        {
            var deadline = DateTime.UtcNow.AddMilliseconds(1200);
            while (DateTime.UtcNow < deadline && AnyHotkeyModifierDown())
            {
                Thread.Sleep(20);
            }
            Thread.Sleep(40);
        }

        private static bool AnyHotkeyModifierDown()
        {
            return IsKeyDown(NativeMethods.VK_CONTROL) ||
                   IsKeyDown(NativeMethods.VK_SHIFT) ||
                   IsKeyDown(NativeMethods.VK_MENU) ||
                   IsKeyDown(NativeMethods.VK_LWIN) ||
                   IsKeyDown(NativeMethods.VK_RWIN);
        }

        private static bool IsKeyDown(int virtualKey)
        {
            return (NativeMethods.GetAsyncKeyState(virtualKey) & unchecked((short)0x8000)) != 0;
        }

        private static void SendCtrlVPaste()
        {
            if (!KeyboardInput.SendControlVPaste())
            {
                throw new InvalidOperationException("Windows did not accept the paste keyboard input.");
            }
        }

        private void RestoreClipboard(IDataObject previousClipboard)
        {
            try
            {
                if (previousClipboard == null)
                {
                    Clipboard.Clear();
                }
                else
                {
                    Clipboard.SetDataObject(previousClipboard, true);
                }
            }
            catch
            {
                ClearIgnoredClipboardChanges();
            }
        }

        private void IgnoreClipboardChanges(int count)
        {
            if (count <= 0) return;
            clipMergeDetector.Reset();
            ignoredClipboardChangeCount += count;
        }

        private void ClearIgnoredClipboardChanges()
        {
            ignoredClipboardChangeCount = 0;
        }

        private void ResetRemoteAutoCopyBaseline()
        {
            var entry = store == null ? null : store.GetNewestRemoteEntry(CurrentDeviceName());
            if (entry == null)
            {
                lastAutoCopiedRemoteEntryId = string.Empty;
                lastAutoCopiedRemoteEntryStamp = 0;
                return;
            }

            lastAutoCopiedRemoteEntryId = entry.Id ?? string.Empty;
            lastAutoCopiedRemoteEntryStamp = entry.CreatedUnixMs;
        }

        private void MaybeAutoCopyLatestRemoteEntry()
        {
            if (!settings.AutoCopyLatestRemoteText) return;

            var entry = store.GetNewestRemoteEntry(CurrentDeviceName());
            if (entry == null || string.IsNullOrEmpty(entry.Text)) return;

            var stamp = entry.CreatedUnixMs;
            if (stamp < lastAutoCopiedRemoteEntryStamp)
            {
                return;
            }
            if (stamp == lastAutoCopiedRemoteEntryStamp &&
                string.Equals(entry.Id ?? string.Empty, lastAutoCopiedRemoteEntryId, StringComparison.Ordinal))
            {
                return;
            }

            lastAutoCopiedRemoteEntryId = entry.Id ?? string.Empty;
            lastAutoCopiedRemoteEntryStamp = stamp;
            IgnoreClipboardChanges(1);
            SetEntryClipboard(entry);
            sounds.Remote(settings.SoundsEnabled);
        }

        private void MaybeCopyCommandEntry(string entryId)
        {
            if (!settings.AutoCopyLatestRemoteText) return;

            var entry = store.GetEntryById(entryId);
            if (entry == null || string.IsNullOrEmpty(entry.Text)) return;

            try
            {
                IgnoreClipboardChanges(1);
                SetEntryClipboard(entry);
                sounds.Copy(settings.SoundsEnabled);
            }
            catch (Exception ex)
            {
                ClearIgnoredClipboardChanges();
                Program.WriteRuntimeLog("Could not put a command-line history addition on the clipboard.", ex);
                sounds.Skip(settings.SoundsEnabled);
            }
        }

        private static void SetEntryClipboard(ClipEntry entry)
        {
            var text = ResolvedEntryText(entry);
            var data = new DataObject();
            data.SetText(text, TextDataFormat.UnicodeText);
            if (entry != null && !entry.IsTemplate && string.Equals(text, entry.Text ?? string.Empty, StringComparison.Ordinal))
            {
                RichTextData.AddToDataObject(data, entry.RichText, entry);
            }
            Clipboard.SetDataObject(data, true);
        }

        private static string ResolvedEntryText(ClipEntry entry)
        {
            if (entry == null) return string.Empty;
            var text = entry.Text ?? string.Empty;
            return entry.IsTemplate ? TemplateResolver.Resolve(text) : text;
        }

        private void FileEventStoreChanged(object sender, EventArgs e)
        {
            if (historyForm != null && !historyForm.IsDisposed)
            {
                historyForm.BeginInvoke(new Action(() => historyForm.RefreshFileClipboardEvents()));
            }
        }

        private string TrayText()
        {
            var storageMessage = StorageUnavailableMessage();
            if (!string.IsNullOrWhiteSpace(storageMessage))
            {
                return ShortTrayText("Clipman: storage unavailable");
            }

            return settings.Active ? "Clipman: on" : "Clipman: off";
        }

        private bool IsStorageUnavailable()
        {
            return !string.IsNullOrWhiteSpace(StorageUnavailableMessage());
        }

        private string StorageUnavailableMessage()
        {
            var parts = new List<string>();
            if (!string.IsNullOrWhiteSpace(store.LastStorageError))
            {
                parts.Add("Text history: " + store.LastStorageError);
            }

            if (!string.IsNullOrWhiteSpace(fileEventStore.LastStorageError))
            {
                parts.Add("File history: " + fileEventStore.LastStorageError);
            }

            return string.Join("; ", parts);
        }

        private static string ShortTrayText(string text)
        {
            if (string.IsNullOrEmpty(text)) return string.Empty;
            return text.Length <= 63 ? text : text.Substring(0, 63);
        }

        private void UpdateTray()
        {
            notifyIcon.Text = TrayText();
            notifyIcon.Icon = BuildIcon(settings.Active);
            notifyIcon.ContextMenuStrip = BuildTrayMenu();
            if (historyForm != null && !historyForm.IsDisposed && historyForm.IsHandleCreated)
            {
                historyForm.BeginInvoke(new Action(historyForm.RefreshSteadyStatus));
            }
        }

        private string HistorySteadyStatusText()
        {
            var monitoring = settings.Active ? string.Empty : "Monitoring off. ";
            var fileStorageError = fileEventStore == null ? string.Empty : fileEventStore.LastStorageError;
            var sync = store == null ? null : store.GetServerSyncStatus();
            if (IsServerStorageEnabled())
            {
                if (sync == null || !sync.Enabled || !sync.Configured)
                {
                    return monitoring + "Server is not configured; using local cache.";
                }
                if (sync.ConsecutiveFailures > 0)
                {
                    return monitoring + "Server unavailable; using local cache.";
                }
                if (sync.LastSuccessUnixMs <= 0)
                {
                    return monitoring + "Connecting to Clipman Server.";
                }
                if (!string.IsNullOrWhiteSpace(fileStorageError))
                {
                    return monitoring + "File history storage unavailable.";
                }
                return settings.Active ? "Ready. Server sync connected." : "Monitoring off. Server sync connected.";
            }
            if ((store != null && !string.IsNullOrWhiteSpace(store.LastStorageError)) || !string.IsNullOrWhiteSpace(fileStorageError))
            {
                return monitoring + "Storage unavailable.";
            }
            return settings.Active ? "Ready. Using local or shared-folder history." : "Monitoring off. Using local or shared-folder history.";
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                if (closeEvent != null) closeEvent.Dispose();
                if (showEvent != null) showEvent.Dispose();
                if (recoverEvent != null) recoverEvent.Dispose();
                if (pauseEvent != null) pauseEvent.Dispose();
                if (resumeEvent != null) resumeEvent.Dispose();
                if (toggleEvent != null) toggleEvent.Dispose();
                if (historyChangedEvent != null) historyChangedEvent.Dispose();
                if (historyAddedEvent != null) historyAddedEvent.Dispose();
                if (invoker != null) invoker.Dispose();
                if (sharedStateWatcher != null) sharedStateWatcher.Dispose();
                if (executableWatcher != null) executableWatcher.Dispose();
                if (sharedStateTimer != null) sharedStateTimer.Dispose();
                if (updateCheckTimer != null) updateCheckTimer.Dispose();
                if (clipboardFloodRecoveryTimer != null) clipboardFloodRecoveryTimer.Dispose();
                NativeMethods.RemoveClipboardFormatListener(messageWindow.Handle);
                NativeMethods.UnregisterHotKey(messageWindow.Handle, ShowHotkeyId);
                NativeMethods.UnregisterHotKey(messageWindow.Handle, ToggleHotkeyId);
                NativeMethods.UnregisterHotKey(messageWindow.Handle, ToggleHotkeyAlternateId);
                foreach (var hotkeyId in quickCopyHotkeyEntryIds.Keys.ToList())
                {
                    NativeMethods.UnregisterHotKey(messageWindow.Handle, hotkeyId);
                }
                notifyIcon.Visible = false;
                notifyIcon.Dispose();
                store.Dispose();
                fileEventStore.Dispose();
                messageWindow.Dispose();
                messageWindow.DestroyHandle();
            }
            base.Dispose(disposing);
        }

        private void WaitForClose()
        {
            try
            {
                closeEvent.WaitOne();
                if (invoker != null && invoker.IsHandleCreated)
                {
                    invoker.BeginInvoke(new Action(ExitThread));
                }
            }
            catch
            {
            }
        }

        private void WaitForShow()
        {
            while (true)
            {
                try
                {
                    showEvent.WaitOne();
                    showEvent.Reset();
                    if (invoker != null && invoker.IsHandleCreated)
                    {
                        invoker.BeginInvoke(new Action(ShowHistory));
                    }
                }
                catch
                {
                    return;
                }
            }
        }

        private void WaitForState(EventWaitHandle ev, bool active)
        {
            while (true)
            {
                try
                {
                    ev.WaitOne();
                    ev.Reset();
                    if (invoker != null && invoker.IsHandleCreated)
                    {
                        invoker.BeginInvoke(new Action(() => SetActive(active, true)));
                    }
                }
                catch
                {
                    return;
                }
            }
        }

        private void WaitForToggle()
        {
            while (true)
            {
                try
                {
                    toggleEvent.WaitOne();
                    toggleEvent.Reset();
                    if (invoker != null && invoker.IsHandleCreated)
                    {
                        invoker.BeginInvoke(new Action(ToggleActive));
                    }
                }
                catch
                {
                    return;
                }
            }
        }

        private void StartSharedUpdateWatchers()
        {
            var sharedExecutableSettingsDirectory = SharedExecutableSettingsDirectory();
            if (!SharedUpdateStateStore.CanCoordinateExecutable(sharedExecutableSettingsDirectory, Application.ExecutablePath)) return;
            try
            {
                Directory.CreateDirectory(sharedExecutableSettingsDirectory);
                sharedStateTimer = new System.Threading.Timer(delegate
                {
                    try
                    {
                        CheckSharedUpdateState();
                    }
                    catch (Exception ex)
                    {
                        Program.WriteRuntimeLog("Shared executable update coordination check failed.", ex);
                    }
                }, null, Timeout.Infinite, Timeout.Infinite);

                sharedStateWatcher = new FileSystemWatcher(sharedExecutableSettingsDirectory, "clipman-shared-state*.json")
                {
                    NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName | NotifyFilters.CreationTime
                };
                sharedStateWatcher.Changed += SharedUpdateStateChanged;
                sharedStateWatcher.Created += SharedUpdateStateChanged;
                sharedStateWatcher.Renamed += SharedUpdateStateChanged;
                sharedStateWatcher.EnableRaisingEvents = true;

                executableWatcher = new FileSystemWatcher(appDirectory, "clipman.exe")
                {
                    NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName | NotifyFilters.CreationTime
                };
                executableWatcher.Changed += SharedUpdateStateChanged;
                executableWatcher.Created += SharedUpdateStateChanged;
                executableWatcher.Renamed += SharedUpdateStateChanged;
                executableWatcher.EnableRaisingEvents = true;
            }
            catch
            {
            }
        }

        private void RestartSharedUpdateWatchers()
        {
            try
            {
                if (sharedStateWatcher != null)
                {
                    sharedStateWatcher.Dispose();
                    sharedStateWatcher = null;
                }
                if (executableWatcher != null)
                {
                    executableWatcher.Dispose();
                    executableWatcher = null;
                }
                if (sharedStateTimer != null)
                {
                    sharedStateTimer.Dispose();
                    sharedStateTimer = null;
                }
                StartSharedUpdateWatchers();
                ScheduleSharedUpdateCheck(5000);
            }
            catch
            {
            }
        }

        private void ReopenFileHistoryStore()
        {
            try
            {
                if (fileEventStore != null)
                {
                    fileEventStore.Changed -= FileEventStoreChanged;
                    fileEventStore.Dispose();
                }
            }
            catch
            {
            }

            fileEventStore = new FileClipboardEventStore(settingsStore.DefaultFileHistoryDatabasePath(), CurrentDatabasePassword);
            fileEventStore.Changed += FileEventStoreChanged;
        }

        private void ApplyStartupRegistration(bool showErrors)
        {
            try
            {
                StartupRegistration.SetEnabled(settings.RunAtStartup);
            }
            catch (Exception ex)
            {
                if (showErrors)
                {
                    MessageBox.Show("Could not update the Windows startup entry.\r\n\r\n" + ex.Message, "Clipman startup", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            }
        }

        private void ScheduleUpdateChecks()
        {
            try
            {
                if (updateCheckTimer != null)
                {
                    updateCheckTimer.Dispose();
                    updateCheckTimer = null;
                }

                var frequency = settings.UpdateCheckFrequency ?? "Never";
                if (string.Equals(frequency, "Never", StringComparison.OrdinalIgnoreCase))
                {
                    return;
                }

                var period = Timeout.Infinite;
                if (string.Equals(frequency, "Hourly", StringComparison.OrdinalIgnoreCase))
                {
                    period = (int)TimeSpan.FromHours(1).TotalMilliseconds;
                }
                else if (string.Equals(frequency, "Daily", StringComparison.OrdinalIgnoreCase))
                {
                    period = (int)TimeSpan.FromDays(1).TotalMilliseconds;
                }

                updateCheckTimer = new System.Threading.Timer(delegate { CheckForUpdatesAutomatically(); }, null, 30000, period);
            }
            catch
            {
            }
        }

        private void CheckForUpdatesAutomatically()
        {
            try
            {
                if (invoker != null && invoker.IsHandleCreated)
                {
                    invoker.BeginInvoke(new Action(() =>
                        UpdateService.CheckForUpdatesAutomatic(UpdateWindowOwner(), AppVersion(), ExitThread, settings.InstallUpdatesSilently)));
                }
            }
            catch
            {
            }
        }

        private void ResolveDatabasePassword()
        {
            var databaseIsEncrypted = false;
            var fileHistoryIsEncrypted = false;
            try
            {
                databaseIsEncrypted = ClipDatabaseFile.IsEncryptedFile(settings.DatabasePath);
            }
            catch
            {
            }
            try
            {
                fileHistoryIsEncrypted = ClipDatabaseFile.IsEncryptedFile(settingsStore.DefaultFileHistoryDatabasePath());
            }
            catch
            {
            }
            if (!databaseIsEncrypted && !fileHistoryIsEncrypted && !settings.DatabaseEncryptionEnabled && string.IsNullOrWhiteSpace(settings.ProtectedDatabasePassword))
            {
                databasePassword = string.Empty;
                settings.DatabaseEncryptionEnabled = false;
                settings.RememberDatabasePassword = false;
                settings.ProtectedDatabasePassword = string.Empty;
                return;
            }

            if (!string.IsNullOrWhiteSpace(settings.ProtectedDatabasePassword))
            {
                settings.DatabaseEncryptionEnabled = true;
                settings.RememberDatabasePassword = true;
                try
                {
                    var password = settingsStore.DatabasePassword(settings);
                    if (!string.IsNullOrEmpty(password))
                    {
                        databasePassword = password;
                        return;
                    }
                }
                catch
                {
                }
            }

            if (!string.IsNullOrEmpty(databasePassword))
            {
                settings.DatabaseEncryptionEnabled = true;
                if (settings.RememberDatabasePassword && string.IsNullOrWhiteSpace(settings.ProtectedDatabasePassword))
                {
                    settings.ProtectedDatabasePassword = DatabasePasswordProtector.Protect(databasePassword);
                    settingsStore.Save(settings);
                }
                return;
            }

            if (!databaseIsEncrypted && !fileHistoryIsEncrypted)
            {
                settings.DatabaseEncryptionEnabled = false;
                settings.RememberDatabasePassword = false;
                settings.ProtectedDatabasePassword = string.Empty;
                settingsStore.Save(settings);
                return;
            }

            var entered = PasswordPromptForm.Ask(
                "Clipman history password",
                "This machine needs the password for the encrypted Clipman history database.");
            if (string.IsNullOrEmpty(entered))
            {
                throw new OperationCanceledException("Clipman history password was not provided.");
            }
            databasePassword = entered;
            settings.DatabaseEncryptionEnabled = true;
            if (settings.RememberDatabasePassword)
            {
                settings.ProtectedDatabasePassword = DatabasePasswordProtector.Protect(entered);
            }
            else
            {
                settings.ProtectedDatabasePassword = string.Empty;
            }
            settingsStore.Save(settings);
        }

        private void ResolveDatabaseLocation()
        {
            if (IsServerStorageEnabled())
            {
                if (settings.UseDefaultDatabasePath || string.IsNullOrWhiteSpace(settings.DatabasePath))
                {
                    settings.UseDefaultDatabasePath = true;
                    settings.DatabasePath = settingsStore.DefaultDatabasePath();
                    settingsStore.Save(settings);
                }
                return;
            }

            if (settings.UseDefaultDatabasePath || string.IsNullOrWhiteSpace(settings.DatabasePath))
            {
                settings.UseDefaultDatabasePath = true;
                settings.DatabasePath = settingsStore.DefaultDatabasePath();
                settingsStore.Save(settings);
                return;
            }

            if (File.Exists(settings.DatabasePath))
            {
                return;
            }

            var message =
                "Clipman cannot find the configured history database:" +
                Environment.NewLine +
                Environment.NewLine +
                settings.DatabasePath +
                Environment.NewLine +
                Environment.NewLine +
                "Choose Yes to browse for the data folder that contains the database." +
                Environment.NewLine +
                "Choose No to use the default database beside Clipman." +
                Environment.NewLine +
                "Choose Cancel to stop Clipman.";
            var choice = MessageBox.Show(
                message,
                "Clipman database not found",
                MessageBoxButtons.YesNoCancel,
                MessageBoxIcon.Warning,
                MessageBoxDefaultButton.Button1);

            if (choice == DialogResult.Cancel)
            {
                throw new OperationCanceledException("Clipman database location was not selected.");
            }

            if (choice == DialogResult.Yes)
            {
                using (var dialog = new FolderBrowserDialog())
                {
                    dialog.Description = "Choose the Clipman data folder. Clipman will use clipman-history.clipdb inside this folder.";
                    dialog.ShowNewFolderButton = true;
                    var oldDir = Path.GetDirectoryName(settings.DatabasePath);
                    if (!string.IsNullOrWhiteSpace(oldDir) && Directory.Exists(oldDir))
                    {
                        dialog.SelectedPath = oldDir;
                    }

                    if (dialog.ShowDialog() != DialogResult.OK)
                    {
                        throw new OperationCanceledException("Clipman database location was not selected.");
                    }

                    settings.DatabasePath = Path.Combine(dialog.SelectedPath, "clipman-history.clipdb");
                    settings.UseDefaultDatabasePath = settingsStore.IsCurrentDefaultDatabasePath(settings.DatabasePath);
                    settingsStore.Save(settings);
                    return;
                }
            }

            settings.UseDefaultDatabasePath = true;
            settings.DatabasePath = settingsStore.DefaultDatabasePath();
            settingsStore.Save(settings);
        }

        private string EffectiveTextHistoryDatabasePath()
        {
            return settingsStore.EffectiveTextHistoryDatabasePath(settings);
        }

        private void WaitForRecover()
        {
            while (true)
            {
                try
                {
                    recoverEvent.WaitOne();
                    recoverEvent.Reset();
                    if (invoker != null && invoker.IsHandleCreated)
                    {
                        invoker.BeginInvoke(new Action(delegate
                        {
                            if (IsStorageUnavailable()) RetryStorage();
                        }));
                    }
                }
                catch
                {
                    return;
                }
            }
        }

        private void WaitForHistoryChanged()
        {
            while (true)
            {
                try
                {
                    historyChangedEvent.WaitOne();
                    historyChangedEvent.Reset();
                    store.ReloadExternalChangeAndSync();
                }
                catch (ObjectDisposedException)
                {
                    return;
                }
                catch (Exception ex)
                {
                    Program.WriteRuntimeLog("Could not reload and synchronize an external history change.", ex);
                }
            }
        }

        private void WaitForHistoryAdded()
        {
            while (true)
            {
                try
                {
                    historyAddedEvent.WaitOne();
                    historyAddedEvent.Reset();
                    var entryId = InstanceStateStore.TakePendingCommandEntry((long)TimeSpan.FromMinutes(5).TotalMilliseconds);
                    store.ReloadExternalChange();
                    if (!string.IsNullOrEmpty(entryId) && invoker != null && invoker.IsHandleCreated)
                    {
                        invoker.BeginInvoke(new Action(() => MaybeCopyCommandEntry(entryId)));
                    }
                    store.SyncExternalChange();
                }
                catch (ObjectDisposedException)
                {
                    return;
                }
                catch (Exception ex)
                {
                    Program.WriteRuntimeLog("Could not process and synchronize a command-line history addition.", ex);
                }
            }
        }

        private string ServerCacheDatabasePath()
        {
            return settingsStore.EffectiveTextHistoryDatabasePath(new AppSettings { StorageMode = "Server" });
        }

        private void MergeServerCacheIntoConfiguredDatabase(string serverCachePath)
        {
            if (string.IsNullOrWhiteSpace(serverCachePath) || !File.Exists(serverCachePath)) return;
            if (string.IsNullOrWhiteSpace(settings.DatabasePath)) return;
            try
            {
                var targetPath = settings.DatabasePath;
                if (string.Equals(Path.GetFullPath(serverCachePath), Path.GetFullPath(targetPath), StringComparison.OrdinalIgnoreCase)) return;

                var targetDatabase = File.Exists(targetPath)
                    ? ClipDatabaseFile.Load(targetPath, CurrentDatabasePassword())
                    : new ClipDatabase();
                var cacheDatabase = ClipDatabaseFile.Load(serverCachePath, CurrentDatabasePassword());
                SyncConflictResolver.MergeInto(targetDatabase, cacheDatabase);

                var dir = Path.GetDirectoryName(targetPath);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                ClipDatabaseFile.SaveAtomic(targetPath, targetDatabase, CurrentDatabasePassword());
            }
            catch (Exception ex)
            {
                Debug.WriteLine("Could not merge the server cache into the selected local database: " + ex.Message);
            }
        }

        private void SeedServerCacheFromConfiguredDatabase()
        {
            if (!IsServerStorageEnabled()) return;
            var cachePath = EffectiveTextHistoryDatabasePath();
            if (File.Exists(cachePath)) return;
            if (string.IsNullOrWhiteSpace(settings.DatabasePath)) return;
            if (!File.Exists(settings.DatabasePath)) return;
            if (string.Equals(Path.GetFullPath(cachePath), Path.GetFullPath(settings.DatabasePath), StringComparison.OrdinalIgnoreCase)) return;

            try
            {
                var dir = Path.GetDirectoryName(cachePath);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                File.Copy(settings.DatabasePath, cachePath, false);
            }
            catch
            {
            }
        }

        private string CurrentDatabasePassword()
        {
            return databasePassword ?? string.Empty;
        }

        private string CurrentDeviceName()
        {
            var name = settings == null ? string.Empty : (settings.DeviceName ?? string.Empty).Trim();
            return name.Length == 0 ? (Environment.MachineName ?? string.Empty).Trim() : name;
        }

        private string DefaultSecretsDatabasePath()
        {
            return settingsStore.DefaultSecretsDatabasePath();
        }

        private void ReopenSecretStore()
        {
            try
            {
                secretStore = new SecretStore(DefaultSecretsDatabasePath(), CurrentDatabasePassword);
                if (secretsForm != null && !secretsForm.IsDisposed)
                {
                    secretsForm.Close();
                    secretsForm = null;
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine("Could not reopen secrets store: " + ex);
                secretStore = null;
            }
        }

        private bool IsServerStorageEnabled()
        {
            return string.Equals(settings.StorageMode, "Server", StringComparison.OrdinalIgnoreCase);
        }

        private void ConfigureTextHistoryServerStorage()
        {
            if (store == null) return;
            store.ConfigureServerStorage(
                IsServerStorageEnabled(),
                settings.ServerUrl,
                settings.ServerToken,
                settings.ServerCaCertPem,
                settings.ServerCaHost);
        }

        private IWin32Window UpdateWindowOwner()
        {
            return historyForm != null && !historyForm.IsDisposed ? historyForm : null;
        }

        private static string AppVersion()
        {
            var version = typeof(ClipmanApplicationContext).Assembly.GetName().Version;
            return version == null ? "1.1.0" : version.Major + "." + version.Minor + "." + version.Build;
        }

        private string SharedExecutableSettingsDirectory()
        {
            return Path.Combine(appDirectory, "Settings");
        }

        private void SharedUpdateStateChanged(object sender, FileSystemEventArgs e)
        {
            ScheduleSharedUpdateCheck(10000);
        }

        private void ScheduleSharedUpdateCheck(int delayMs)
        {
            try
            {
                if (sharedStateTimer != null)
                {
                    sharedStateTimer.Change(delayMs, Timeout.Infinite);
                }
            }
            catch
            {
            }
        }

        private void CheckSharedUpdateState()
        {
            var sharedExecutableSettingsDirectory = SharedExecutableSettingsDirectory();
            if (!SharedUpdateStateStore.CanCoordinateExecutable(sharedExecutableSettingsDirectory, Application.ExecutablePath)) return;
            SharedUpdateState closeState;
            if (SharedUpdateStateStore.HasActiveCloseRequest(sharedExecutableSettingsDirectory, Application.ExecutablePath, lastHandledCloseRequestId, out closeState))
            {
                lastHandledCloseRequestId = closeState.CloseRequestId ?? string.Empty;
                if (invoker != null && invoker.IsHandleCreated)
                {
                    invoker.BeginInvoke(new Action(StartStandDownRestartHelper));
                }
                return;
            }

            SharedUpdateState state;
            string reason;
            if (!SharedUpdateStateStore.ShouldRestartForState(sharedExecutableSettingsDirectory, Application.ExecutablePath, out state, out reason))
            {
                if (SharedUpdateStateStore.IsNewerStateFromAnotherMachine(state))
                {
                    if (invoker != null && invoker.IsHandleCreated)
                    {
                        invoker.BeginInvoke(new Action(StartStandDownRestartHelper));
                    }
                    return;
                }

                if (!string.IsNullOrWhiteSpace(reason))
                {
                    ScheduleSharedUpdateCheck(15000);
                }
                else
                {
                    ScheduleSharedUpdateCheck(60000);
                }
                return;
            }

            if (invoker != null && invoker.IsHandleCreated)
            {
                invoker.BeginInvoke(new Action(RestartForSharedUpdate));
            }
        }

        private void RestartForSharedUpdate()
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = Application.ExecutablePath,
                    WorkingDirectory = appDirectory,
                    UseShellExecute = true
                });
            }
            catch
            {
                return;
            }

            ExitThread();
        }

        private void StartStandDownRestartHelper()
        {
            var sharedExecutableSettingsDirectory = SharedExecutableSettingsDirectory();
            if (!SharedUpdateStateStore.CanCoordinateExecutable(sharedExecutableSettingsDirectory, Application.ExecutablePath)) return;
            try
            {
                var tempRoot = Path.Combine(Path.GetTempPath(), "ClipmanRestart-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(tempRoot);
                var helperExe = Path.Combine(tempRoot, "clipman-restart-helper.exe");
                File.Copy(Application.ExecutablePath, helperExe, true);
                Process.Start(new ProcessStartInfo
                {
                    FileName = helperExe,
                    Arguments =
                        "--wait-restart" +
                        " --restart-exe " + Quote(Application.ExecutablePath) +
                        " --restart-working-dir " + Quote(appDirectory) +
                        " --restart-state " + Quote(SharedUpdateStateStore.StatePath(sharedExecutableSettingsDirectory)) +
                        " --restart-current-build " + BuildInfo.BuildStampUtcMs +
                        " --restart-wait-pid " + Process.GetCurrentProcess().Id +
                        " --restart-timeout-ms 120000",
                    WorkingDirectory = tempRoot,
                    UseShellExecute = false,
                    CreateNoWindow = true
                });
                ExitThread();
            }
            catch
            {
            }
        }

        private static string Quote(string value)
        {
            if (value == null) return "\"\"";
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private static Icon BuildIcon(bool active)
        {
            var bitmap = new Bitmap(16, 16);
            using (var g = Graphics.FromImage(bitmap))
            using (var back = new SolidBrush(active ? Color.ForestGreen : Color.DarkRed))
            using (var pen = new Pen(Color.White, 2))
            {
                g.Clear(Color.Transparent);
                g.FillRectangle(back, 1, 1, 14, 14);
                g.DrawRectangle(Pens.Black, 1, 1, 14, 14);
                if (active)
                {
                    g.DrawLine(pen, 4, 8, 7, 11);
                    g.DrawLine(pen, 7, 11, 12, 4);
                }
                else
                {
                    g.DrawLine(pen, 5, 5, 11, 11);
                    g.DrawLine(pen, 11, 5, 5, 11);
                }
            }

            return Icon.FromHandle(bitmap.GetHicon());
        }

        private sealed class MessageWindow : NativeWindow, IDisposable
        {
            private const int ClipboardSettleMilliseconds = 40;
            private readonly ClipmanApplicationContext app;
            private readonly System.Windows.Forms.Timer clipboardSettleTimer;

            public MessageWindow(ClipmanApplicationContext app)
            {
                this.app = app;
                clipboardSettleTimer = new System.Windows.Forms.Timer { Interval = ClipboardSettleMilliseconds };
                clipboardSettleTimer.Tick += ClipboardSettleTimerTick;
                CreateHandle(new CreateParams());
            }

            public void Dispose()
            {
                clipboardSettleTimer.Stop();
                clipboardSettleTimer.Tick -= ClipboardSettleTimerTick;
                clipboardSettleTimer.Dispose();
            }

            private void ClipboardSettleTimerTick(object sender, EventArgs e)
            {
                clipboardSettleTimer.Stop();
                app.HandleClipboardUpdate(false, app.clipboardNotifications.TakePending());
            }

            protected override void WndProc(ref Message m)
            {
                if (m.Msg == NativeMethods.WM_HOTKEY)
                {
                    app.HandleHotkey(m.WParam.ToInt32());
                    return;
                }

                if (m.Msg == NativeMethods.WM_CLIPBOARDUPDATE)
                {
                    app.clipboardNotifications.Observe(NativeMethods.GetClipboardSequenceNumber());
                    clipboardSettleTimer.Stop();
                    clipboardSettleTimer.Start();
                    return;
                }

                base.WndProc(ref m);
            }
        }

    }
}
