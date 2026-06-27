using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class ClipmanApplicationContext : ApplicationContext
    {
        private const int ShowHotkeyId = 1001;
        private const int ToggleHotkeyId = 1002;
        private const int ToggleHotkeyAlternateId = 1004;
        private const int QuickCopyHotkeyBaseId = 2000;

        private readonly string appDirectory;
        private readonly SettingsStore settingsStore;
        private SoundService sounds;
        private readonly MessageWindow messageWindow;
        private readonly Control invoker;
        private readonly NotifyIcon notifyIcon;
        private readonly EventWaitHandle closeEvent;
        private readonly EventWaitHandle showEvent;
        private readonly EventWaitHandle pauseEvent;
        private readonly EventWaitHandle resumeEvent;
        private readonly EventWaitHandle toggleEvent;
        private readonly Thread closeThread;
        private readonly Thread showThread;
        private readonly Thread pauseThread;
        private readonly Thread resumeThread;
        private readonly Thread toggleThread;
        private FileSystemWatcher sharedStateWatcher;
        private FileSystemWatcher executableWatcher;
        private System.Threading.Timer sharedStateTimer;
        private System.Threading.Timer updateCheckTimer;
        private AppSettings settings;
        private ClipStore store;
        private FileClipboardEventStore fileEventStore;
        private HistoryForm historyForm;
        private PreferencesForm preferencesForm;
        private bool ignoreNextClipboardChange;
        private bool showHotkeyRegistered;
        private bool toggleHotkeyRegistered;
        private bool toggleAlternateHotkeyRegistered;
        private readonly Dictionary<int, string> quickCopyHotkeyEntryIds = new Dictionary<int, string>();
        private int quickCopyHotkeysRegistered;
        private string lastHandledCloseRequestId = string.Empty;
        private string lastAutoCopiedRemoteEntryId = string.Empty;
        private long lastAutoCopiedRemoteEntryStamp;
        private string databasePassword = string.Empty;

        public ClipmanApplicationContext()
        {
            appDirectory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            settingsStore = new SettingsStore(appDirectory);
            settings = settingsStore.Load();
            ResolveDatabaseLocation();
            ResolveDatabasePassword();
            SharedUpdateStateStore.PublishCurrentBuild(settingsStore.SettingsDirectory);
            sounds = new SoundService(appDirectory, settingsStore.SettingsDirectory);
            store = new ClipStore(settings.DatabasePath, CurrentDatabasePassword);
            store.Changed += StoreChanged;
            ResetRemoteAutoCopyBaseline();
            fileEventStore = new FileClipboardEventStore(settingsStore.DefaultFileHistoryDatabasePath(), CurrentDatabasePassword);
            fileEventStore.Changed += FileEventStoreChanged;

            invoker = new Control();
            invoker.CreateControl();

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

            RegisterHotkeys();
            ApplyStartupRegistration(false);
            PlayLaunchStateSound();

            closeEvent = new EventWaitHandle(false, EventResetMode.ManualReset, Program.CloseEventName);
            showEvent = new EventWaitHandle(false, EventResetMode.ManualReset, Program.ShowEventName);
            pauseEvent = new EventWaitHandle(false, EventResetMode.ManualReset, Program.PauseEventName);
            resumeEvent = new EventWaitHandle(false, EventResetMode.ManualReset, Program.ResumeEventName);
            toggleEvent = new EventWaitHandle(false, EventResetMode.ManualReset, Program.ToggleEventName);
            closeThread = new Thread(WaitForClose) { IsBackground = true, Name = "Clipman close event listener" };
            showThread = new Thread(WaitForShow) { IsBackground = true, Name = "Clipman show event listener" };
            pauseThread = new Thread(() => WaitForState(pauseEvent, false)) { IsBackground = true, Name = "Clipman pause event listener" };
            resumeThread = new Thread(() => WaitForState(resumeEvent, true)) { IsBackground = true, Name = "Clipman resume event listener" };
            toggleThread = new Thread(WaitForToggle) { IsBackground = true, Name = "Clipman toggle event listener" };
            closeThread.Start();
            showThread.Start();
            pauseThread.Start();
            resumeThread.Start();
            toggleThread.Start();
            StartSharedUpdateWatchers();
            ScheduleSharedUpdateCheck(5000);
            ScheduleUpdateChecks();
        }

        public void ShowHistory()
        {
            var created = false;
            if (historyForm == null || historyForm.IsDisposed)
            {
                historyForm = new HistoryForm(store, settings, SaveSettings, RegisterHotkeys, CopyEntryToClipboard, CopyEntriesToClipboard, GetRecentClipboardEvents, DeleteRecentClipboardEvents, ClearRecentClipboardEvents, RemoveUnavailableRecentClipboardEvents, ToggleRecentClipboardEventPinned, MoveRecentClipboardEvents, ClearTextHistory, ShowPreferences, ToggleActive, ExitThread, BuildDiagnosticsText);
                created = true;
            }

            if (historyForm.WindowState == FormWindowState.Minimized)
            {
                historyForm.WindowState = FormWindowState.Normal;
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
            if (preferencesForm != null && !preferencesForm.IsDisposed)
            {
                FocusPreferencesForm();
                return;
            }

            if (historyForm == null || historyForm.IsDisposed || !historyForm.Visible)
            {
                ShowHistory();
            }

            preferencesForm = new PreferencesForm(settings, ApplyPreferences, CopySensitiveTextToClipboard);
            preferencesForm.FormClosed += (s, e) => preferencesForm = null;
            preferencesForm.ShowDialog(historyForm);
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
            var databaseChanged = !string.Equals(settings.DatabasePath, updated.DatabasePath, StringComparison.OrdinalIgnoreCase);
            var activeChanged = settings.Active != updated.Active;
            var sendToChanged = settings.SendToEnabled != updated.SendToEnabled;
            var encryptionChanged =
                settings.DatabaseEncryptionEnabled != updated.DatabaseEncryptionEnabled ||
                settings.RememberDatabasePassword != updated.RememberDatabasePassword ||
                !string.Equals(settings.ProtectedDatabasePassword, updated.ProtectedDatabasePassword, StringComparison.Ordinal) ||
                !string.IsNullOrEmpty(updated.PlainDatabasePassword);
            var startupChanged = settings.RunAtStartup != updated.RunAtStartup;
            var updatePolicyChanged =
                !string.Equals(settings.UpdateCheckFrequency, updated.UpdateCheckFrequency, StringComparison.OrdinalIgnoreCase) ||
                settings.InstallUpdatesSilently != updated.InstallUpdatesSilently;
            var autoRemoteCopyTurnedOn = !settings.AutoCopyLatestRemoteText && updated.AutoCopyLatestRemoteText;
            var saveListPositionTurnedOff = settings.SaveListPosition && !updated.SaveListPosition;
            var oldSettingsDirectory = settingsStore.SettingsDirectory;
            settings.ShowHistoryHotkey = updated.ShowHistoryHotkey;
            settings.ToggleActiveHotkey = updated.ToggleActiveHotkey;
            settings.QuickCopyHotkeys = updated.QuickCopyHotkeys == null
                ? new List<QuickCopyBinding>()
                : updated.QuickCopyHotkeys.Select(b => new QuickCopyBinding { EntryId = b.EntryId, Hotkey = b.Hotkey }).ToList();
            settings.AutoCopyLatestRemoteText = updated.AutoCopyLatestRemoteText;
            settings.RemoveDuplicates = updated.RemoveDuplicates;
            settings.SoundsEnabled = updated.SoundsEnabled;
            settings.SaveListPosition = updated.SaveListPosition;
            settings.Active = updated.Active;
            settings.DatabasePath = updated.DatabasePath;
            settings.UseDefaultDatabasePath = updated.UseDefaultDatabasePath;
            settings.MaxHistoryEntries = updated.MaxHistoryEntries;
            settings.MaxHistoryDays = updated.MaxHistoryDays;
            settings.IgnoredProcesses = updated.IgnoredProcesses;
            settings.SortMode = updated.SortMode;
            settings.SortDescending = updated.SortDescending;
            settings.SendToEnabled = updated.SendToEnabled;
            settings.ShowHistoryAfterSendTo = updated.ShowHistoryAfterSendTo;
            settings.GroupFilter = updated.GroupFilter;
            settings.DuplicateMode = updated.DuplicateMode;
            settings.AutoGroupByApp = updated.AutoGroupByApp;
            settings.AutoRemoveUrlTracking = updated.AutoRemoveUrlTracking;
            settings.AutoRemoveUnavailableFileHistoryEvents = updated.AutoRemoveUnavailableFileHistoryEvents;
            settings.DiagnosticsFileHistoryLimit = updated.DiagnosticsFileHistoryLimit;
            settings.RunAtStartup = updated.RunAtStartup;
            settings.UpdateCheckFrequency = updated.UpdateCheckFrequency;
            settings.InstallUpdatesSilently = updated.InstallUpdatesSilently;
            settings.DatabaseEncryptionEnabled = updated.DatabaseEncryptionEnabled;
            settings.RememberDatabasePassword = updated.RememberDatabasePassword;
            if (!string.IsNullOrEmpty(updated.PlainDatabasePassword))
            {
                databasePassword = updated.PlainDatabasePassword;
            }
            settings.ProtectedDatabasePassword = updated.ProtectedDatabasePassword;
            if (!settings.DatabaseEncryptionEnabled)
            {
                databasePassword = string.Empty;
                settings.ProtectedDatabasePassword = string.Empty;
                settings.RememberDatabasePassword = false;
            }
            else if (settings.RememberDatabasePassword && string.IsNullOrWhiteSpace(settings.ProtectedDatabasePassword) && !string.IsNullOrEmpty(databasePassword))
            {
                settings.ProtectedDatabasePassword = DatabasePasswordProtector.Protect(databasePassword);
            }
            else if (!settings.RememberDatabasePassword)
            {
                settings.ProtectedDatabasePassword = string.Empty;
            }
            settings.LastPreferencesTab = updated.LastPreferencesTab;
            if (saveListPositionTurnedOff)
            {
                settings.LastSelectedIndex = -1;
            }
            settingsStore.Save(settings);
            var settingsDirectoryChanged = !string.Equals(oldSettingsDirectory, settingsStore.SettingsDirectory, StringComparison.OrdinalIgnoreCase);
            if (settingsDirectoryChanged)
            {
                SharedUpdateStateStore.PublishCurrentBuild(settingsStore.SettingsDirectory);
                RestartSharedUpdateWatchers();
                sounds = new SoundService(appDirectory, settingsStore.SettingsDirectory);
                ReopenFileHistoryStore();
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
                ResolveDatabasePassword();
                store.SetDatabasePath(settings.DatabasePath, CurrentDatabasePassword);
                ResetRemoteAutoCopyBaseline();
            }
            else if (encryptionChanged)
            {
                ResolveDatabasePassword();
                store.ChangeDatabasePassword();
                if (!settingsDirectoryChanged)
                {
                    fileEventStore.ChangeDatabasePassword();
                }
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
            if (databaseChanged && historyForm != null && !historyForm.IsDisposed)
            {
                historyForm.Reload();
            }
        }

        public void CopyEntryToClipboard(ClipEntry entry)
        {
            if (entry == null) return;
            ignoreNextClipboardChange = true;
            Clipboard.SetText(entry.Text ?? string.Empty, TextDataFormat.UnicodeText);
            store.MarkUsed(entry.Id);
        }

        public void CopyEntriesToClipboard(List<ClipEntry> entries)
        {
            if (entries == null || entries.Count == 0) return;
            var data = new DataObject();
            data.SetText(string.Join("\r\n\r\n", entries.Select(e => e.Text ?? string.Empty)), TextDataFormat.UnicodeText);
            data.SetData(ClipmanClipboardData.EntriesFormat, ClipmanClipboardData.SerializeEntries(entries));
            ignoreNextClipboardChange = true;
            Clipboard.SetDataObject(data, true);
            foreach (var entry in entries)
            {
                store.MarkUsed(entry.Id);
            }
        }

        private void CopySensitiveTextToClipboard(string text)
        {
            ignoreNextClipboardChange = true;
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
            else if (quickCopyHotkeyEntryIds.ContainsKey(id))
            {
                CopyQuickCopyEntryToClipboard(quickCopyHotkeyEntryIds[id]);
            }
        }

        internal void HandleClipboardUpdate()
        {
            if (ignoreNextClipboardChange)
            {
                ignoreNextClipboardChange = false;
                return;
            }

            if (!settings.Active)
            {
                sounds.Skip(settings.SoundsEnabled);
                return;
            }

            var sourceProcessName = ClipboardOwnerProcessName();
            if (string.IsNullOrWhiteSpace(sourceProcessName))
            {
                sourceProcessName = ForegroundProcessName();
            }

            if (IsClipmanProcess(sourceProcessName))
            {
                return;
            }

            if (IsIgnoredProcess(sourceProcessName))
            {
                sounds.Skip(settings.SoundsEnabled);
                return;
            }

            RecordClipboardEvent(sourceProcessName);

            if (!Clipboard.ContainsText(TextDataFormat.UnicodeText))
            {
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
                return;
            }

            if (settings.AutoRemoveUrlTracking)
            {
                var cleaned = UrlTrackingCleaner.CleanText(text);
                if (!string.Equals(cleaned, text, StringComparison.Ordinal))
                {
                    text = cleaned;
                    try
                    {
                        ignoreNextClipboardChange = true;
                        Clipboard.SetText(text, TextDataFormat.UnicodeText);
                    }
                    catch
                    {
                        ignoreNextClipboardChange = false;
                    }
                }
            }

            var group = settings.AutoGroupByApp ? FriendlyProcessName(sourceProcessName) : string.Empty;
            store.AddText(text, settings.DuplicateMode, settings.MaxHistoryEntries, settings.MaxHistoryDays, group);
            sounds.Copy(settings.SoundsEnabled);
        }

        private void RecordClipboardEvent(string sourceProcessName)
        {
            ClipboardEventSummary summary;
            try
            {
                summary = ReadClipboardEventSummary(sourceProcessName);
            }
            catch
            {
                return;
            }

            if (summary == null) return;
            fileEventStore.Add(summary);
            if (settings.AutoRemoveUnavailableFileHistoryEvents)
            {
                fileEventStore.RemoveUnavailableEvents();
            }
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
                Formats = source.Formats == null ? new List<string>() : source.Formats.ToList()
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
                SourceMachine = Environment.MachineName ?? string.Empty,
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
            menu.Items.Add("&Show or hide history\t" + settings.ShowHistoryHotkey, null, (s, e) => ToggleHistoryWindow());
            menu.Items.Add((settings.Active ? "Turn &off" : "Turn &on") + "\t" + settings.ToggleActiveHotkey, null, (s, e) => ToggleActive());
            menu.Items.Add("&Preferences...", null, (s, e) => ShowPreferences());
            menu.Items.Add("-");
            menu.Items.Add("E&xit", null, (s, e) => ExitThread());
            return menu;
        }

        private void RegisterHotkeys()
        {
            NativeMethods.UnregisterHotKey(messageWindow.Handle, ShowHotkeyId);
            NativeMethods.UnregisterHotKey(messageWindow.Handle, ToggleHotkeyId);
            NativeMethods.UnregisterHotKey(messageWindow.Handle, ToggleHotkeyAlternateId);
            foreach (var hotkeyId in quickCopyHotkeyEntryIds.Keys.ToList())
            {
                NativeMethods.UnregisterHotKey(messageWindow.Handle, hotkeyId);
            }
            quickCopyHotkeyEntryIds.Clear();
            showHotkeyRegistered = false;
            toggleHotkeyRegistered = false;
            toggleAlternateHotkeyRegistered = false;
            quickCopyHotkeysRegistered = 0;

            HotkeyDefinition show;
            if (HotkeyDefinition.TryParse(settings.ShowHistoryHotkey, out show))
            {
                showHotkeyRegistered = NativeMethods.RegisterHotKey(messageWindow.Handle, ShowHotkeyId, show.Modifiers, show.Key);
            }

            HotkeyDefinition toggle;
            if (HotkeyDefinition.TryParse(settings.ToggleActiveHotkey, out toggle))
            {
                toggleHotkeyRegistered = NativeMethods.RegisterHotKey(messageWindow.Handle, ToggleHotkeyId, toggle.Modifiers, toggle.Key);
                if (settings.ToggleActiveHotkey.Trim().Equals("Ctrl+Alt+`", StringComparison.OrdinalIgnoreCase))
                {
                    toggleAlternateHotkeyRegistered = NativeMethods.RegisterHotKey(messageWindow.Handle, ToggleHotkeyAlternateId, toggle.Modifiers, Keys.Oem8);
                }
            }

            var quickCopyId = QuickCopyHotkeyBaseId;
            var usedHotkeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
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

                if (NativeMethods.RegisterHotKey(messageWindow.Handle, quickCopyId, quickCopy.Modifiers, quickCopy.Key))
                {
                    quickCopyHotkeyEntryIds[quickCopyId] = binding.EntryId.Trim();
                    quickCopyHotkeysRegistered++;
                }
                quickCopyId++;
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
                string.Equals(NormalizeProcessName(p), processName, StringComparison.OrdinalIgnoreCase));
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

        private string BuildDiagnosticsText()
        {
            var sharedState = SharedUpdateStateStore.Load(settingsStore.SettingsDirectory);
            var ignored = settings.IgnoredProcesses == null || settings.IgnoredProcesses.Count == 0
                ? "None"
                : string.Join(", ", settings.IgnoredProcesses);
            return
                "Clipman diagnostics\r\n\r\n" +
                "Active: " + settings.Active + "\r\n" +
                "Sounds enabled: " + settings.SoundsEnabled + "\r\n" +
                "Database path: " + settings.DatabasePath + "\r\n" +
                "Database path type: " + (settings.UseDefaultDatabasePath ? "Default beside Clipman" : "Explicit") + "\r\n" +
                "Database storage status: " + (string.IsNullOrWhiteSpace(store.LastStorageError) ? "OK" : "Unavailable: " + store.LastStorageError) + "\r\n" +
                "Entries: " + store.GetEntries().Count + "\r\n" +
                "File history path: " + fileEventStore.DatabasePath + "\r\n" +
                "File history storage status: " + (string.IsNullOrWhiteSpace(fileEventStore.LastStorageError) ? "OK" : "Unavailable: " + fileEventStore.LastStorageError) + "\r\n" +
                "File history events: " + fileEventStore.GetEvents().Count + "\r\n" +
                "File history diagnostics limit: " + settings.DiagnosticsFileHistoryLimit + "\r\n" +
                "Auto remove unavailable file history events: " + settings.AutoRemoveUnavailableFileHistoryEvents + "\r\n" +
                "Show history hotkey: " + settings.ShowHistoryHotkey + " (" + (showHotkeyRegistered ? "registered" : "not registered") + ")\r\n" +
                "Toggle hotkey: " + settings.ToggleActiveHotkey + " (" + (toggleHotkeyRegistered ? "registered" : "not registered") + ")\r\n" +
                "Toggle alternate UK key: " + (toggleAlternateHotkeyRegistered ? "registered" : "not registered or not needed") + "\r\n" +
                "Quick copy bindings: " + ((settings.QuickCopyHotkeys == null ? 0 : settings.QuickCopyHotkeys.Count) + " configured, " + quickCopyHotkeysRegistered + " registered") + "\r\n" +
                "Auto-copy latest remote text: " + (settings.AutoCopyLatestRemoteText ? "on" : "off") + "\r\n" +
                "Build stamp: " + BuildInfo.BuildStampUtcMs + "\r\n" +
                "Executable hash: " + SharedUpdateStateStore.CurrentExeHash() + "\r\n" +
                "Shared update state path: " + SharedUpdateStateStore.StatePath(settingsStore.SettingsDirectory) + "\r\n" +
                "Shared update state build stamp: " + (sharedState == null ? 0 : sharedState.BuildStampUtcMs) + "\r\n" +
                "Remove duplicates: " + settings.RemoveDuplicates + "\r\n" +
                "Duplicate mode: " + settings.DuplicateMode + "\r\n" +
                "Auto group by app: " + settings.AutoGroupByApp + "\r\n" +
                "Auto remove URL tracking: " + settings.AutoRemoveUrlTracking + "\r\n" +
                "Run at startup: " + settings.RunAtStartup + "\r\n" +
                "Startup registration present: " + StartupRegistration.IsEnabled() + "\r\n" +
                "Update check frequency: " + settings.UpdateCheckFrequency + "\r\n" +
                "Install updates silently: " + settings.InstallUpdatesSilently + "\r\n" +
                "Database encryption enabled: " + settings.DatabaseEncryptionEnabled + "\r\n" +
                "User sound override folder: " + Path.Combine(settingsStore.SettingsDirectory, "sounds") + "\r\n" +
                "Group filter: " + settings.GroupFilter + "\r\n" +
                "Foreground process: " + FriendlyProcessName(ForegroundProcessName()) + "\r\n" +
                "Clipboard owner process: " + FriendlyProcessName(ClipboardOwnerProcessName()) + "\r\n" +
                "Maximum entries: " + (settings.MaxHistoryEntries <= 0 ? "No limit" : settings.MaxHistoryEntries.ToString()) + "\r\n" +
                "Maximum age: " + (settings.MaxHistoryDays <= 0 ? "No limit" : settings.MaxHistoryDays + " days") + "\r\n" +
                "Ignored applications: " + ignored + "\r\n\r\n" +
                BuildRecentClipboardEventsText();
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

        private void CopyQuickCopyEntryToClipboard(string entryId)
        {
            var entry = store.GetEntryById(entryId);
            if (entry == null || string.IsNullOrEmpty(entry.Text))
            {
                sounds.Skip(settings.SoundsEnabled);
                return;
            }

            ignoreNextClipboardChange = true;
            Clipboard.SetText(entry.Text ?? string.Empty, TextDataFormat.UnicodeText);
            store.MarkUsed(entry.Id);
            sounds.Copy(settings.SoundsEnabled);
        }

        private void ResetRemoteAutoCopyBaseline()
        {
            var entry = store == null ? null : store.GetNewestRemoteEntry(Environment.MachineName);
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

            var entry = store.GetNewestRemoteEntry(Environment.MachineName);
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
            ignoreNextClipboardChange = true;
            Clipboard.SetText(entry.Text ?? string.Empty, TextDataFormat.UnicodeText);
            sounds.Remote(settings.SoundsEnabled);
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
            return settings.Active ? "Clipman: on" : "Clipman: off";
        }

        private void UpdateTray()
        {
            notifyIcon.Text = TrayText();
            notifyIcon.Icon = BuildIcon(settings.Active);
            notifyIcon.ContextMenuStrip = BuildTrayMenu();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                if (closeEvent != null) closeEvent.Dispose();
                if (showEvent != null) showEvent.Dispose();
                if (pauseEvent != null) pauseEvent.Dispose();
                if (resumeEvent != null) resumeEvent.Dispose();
                if (toggleEvent != null) toggleEvent.Dispose();
                if (invoker != null) invoker.Dispose();
                if (sharedStateWatcher != null) sharedStateWatcher.Dispose();
                if (executableWatcher != null) executableWatcher.Dispose();
                if (sharedStateTimer != null) sharedStateTimer.Dispose();
                if (updateCheckTimer != null) updateCheckTimer.Dispose();
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
            try
            {
                Directory.CreateDirectory(settingsStore.SettingsDirectory);
                sharedStateTimer = new System.Threading.Timer(delegate { CheckSharedUpdateState(); }, null, Timeout.Infinite, Timeout.Infinite);

                sharedStateWatcher = new FileSystemWatcher(settingsStore.SettingsDirectory, "clipman-shared-state*.json")
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

        private string CurrentDatabasePassword()
        {
            return databasePassword ?? string.Empty;
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
            SharedUpdateState closeState;
            if (SharedUpdateStateStore.HasActiveCloseRequest(settingsStore.SettingsDirectory, lastHandledCloseRequestId, out closeState))
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
            if (!SharedUpdateStateStore.ShouldRestartForState(settingsStore.SettingsDirectory, out state, out reason))
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
                        " --restart-state " + Quote(SharedUpdateStateStore.StatePath(settingsStore.SettingsDirectory)) +
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

        private sealed class MessageWindow : NativeWindow
        {
            private readonly ClipmanApplicationContext app;

            public MessageWindow(ClipmanApplicationContext app)
            {
                this.app = app;
                CreateHandle(new CreateParams());
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
                    app.HandleClipboardUpdate();
                    return;
                }

                base.WndProc(ref m);
            }
        }

    }
}
