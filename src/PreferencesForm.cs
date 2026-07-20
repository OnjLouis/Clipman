using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class PreferencesForm : Form
    {
        private readonly AppSettings settings;
        private readonly Action<AppSettings> applySettings;
        private readonly TextBox showHotkey;
        private readonly TextBox toggleHotkey;
        private readonly CheckBox removeDuplicates;
        private readonly ComboBox duplicateMode;
        private readonly CheckBox soundsEnabled;
        private readonly CheckBox autoGroupByApp;
        private readonly CheckBox autoCopyLatestRemoteText;
        private readonly CheckBox autoRemoveUrlTracking;
        private readonly CheckBox linksHistoryEnabled;
        private readonly CheckBox saveListPosition;
        private readonly CheckBox active;
        private readonly CheckBox runAtStartup;
        private readonly CheckBox captureClipboardOnStartup;
        private readonly ComboBox updateCheckFrequency;
        private readonly CheckBox installUpdatesSilently;
        private readonly TabControl preferencesTabs;
        private readonly TextBox databasePath;
        private readonly ComboBox storageMode;
        private readonly TextBox serverUrl;
        private readonly TextBox serverToken;
        private readonly TextBox databasePassword;
        private readonly TextBox databasePasswordConfirm;
        private readonly CheckBox showDatabasePassword;
        private readonly CheckBox rememberDatabasePassword;
        private bool passwordClearRequested;
        private readonly Action<string> copySensitiveText;
        private readonly ShortcutButton closeButton;
        private readonly NumericUpDown maxHistoryEntries;
        private readonly NumericUpDown maxHistoryDays;
        private readonly CheckBox autoRemoveUnavailableFileHistoryEvents;
        private readonly NumericUpDown diagnosticsFileHistoryLimit;
        private readonly TextBox ignoredProcesses;
        private readonly CheckBox sendToEnabled;
        private readonly CheckBox showHistoryAfterSendTo;
        private readonly ComboBox sensitiveDataMode;
        private readonly CheckedListBox sensitiveDataPresets;
        private bool loading;
        private bool acceptedSingleModifierHotkeyWarning;

        public PreferencesForm(AppSettings current, Action<AppSettings> applySettings, Action<string> copySensitiveText)
        {
            this.applySettings = applySettings;
            this.copySensitiveText = copySensitiveText;
            settings = CloneSettings(current);

            Text = "Clipman Preferences";
            StartPosition = FormStartPosition.CenterParent;
            Width = 800;
            Height = 610;
            MinimizeBox = false;
            MaximizeBox = false;
            ShowInTaskbar = false;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            KeyPreview = true;

            loading = true;

            preferencesTabs = new TabControl
            {
                Left = 10,
                Top = 10,
                Width = 760,
                Height = 515,
                Anchor = AnchorStyles.Left | AnchorStyles.Top | AnchorStyles.Right | AnchorStyles.Bottom,
                AccessibleName = "Preference sections",
                AccessibleDescription = "Preference sections. Press Control 1 through Control 6 to switch tabs."
            };

            var general = new TabPage("General");
            var fileHistory = new TabPage("File history");
            var hotkeys = new TabPage("Hotkeys");
            var storage = new TabPage("Storage and Password");
            var integration = new TabPage("Startup and updates");
            var sensitiveData = new TabPage("Sensitive data");
            general.AccessibleDescription = "General preferences. Shortcut Ctrl+1.";
            fileHistory.AccessibleDescription = "File history preferences. Shortcut Ctrl+2.";
            hotkeys.AccessibleDescription = "Hotkeys preferences. Shortcut Ctrl+3.";
            storage.AccessibleDescription = "Storage and Password preferences. Shortcut Ctrl+4.";
            integration.AccessibleDescription = "Startup and updates preferences. Shortcut Ctrl+5.";
            sensitiveData.AccessibleDescription = "Sensitive data preferences. Shortcut Ctrl+6.";

            active = NewCheckBox("Clipboard monitoring &active", settings.Active);
            soundsEnabled = NewCheckBox("Play &sounds", settings.SoundsEnabled);
            autoGroupByApp = NewCheckBox("Automatically group &new clips by source application", settings.AutoGroupByApp);
            autoCopyLatestRemoteText = NewCheckBox("Put new text received from another &machine on the clipboard", settings.AutoCopyLatestRemoteText);
            autoCopyLatestRemoteText.AccessibleDescription = "When checked, Clipman copies newly created text entries received from another machine onto this machine's clipboard. Reusing an older entry on another machine does not trigger this. This is off by default.";
            autoRemoveUrlTracking = NewCheckBox("Automatically remove URL &tracking from copied text", settings.AutoRemoveUrlTracking);
            linksHistoryEnabled = NewCheckBox("Show &Links history tab", settings.LinksHistoryEnabled);
            linksHistoryEnabled.AccessibleDescription = "When checked, copied HTTP and HTTPS links that are the whole clipboard entry also appear in a separate Links history tab. When unchecked, links remain in Text history.";
            saveListPosition = NewCheckBox("Save list &position", settings.SaveListPosition);
            removeDuplicates = NewCheckBox("&Remove duplicate entries", settings.RemoveDuplicates);
            duplicateMode = NewComboBox("Duplicate handling", new[] { "Move to top", "Ignore", "Keep both" }, DisplayDuplicateMode(settings.DuplicateMode));
            removeDuplicates.Checked = !string.Equals(StoredDuplicateMode(Convert.ToString(duplicateMode.SelectedItem)), "KeepBoth", StringComparison.OrdinalIgnoreCase);
            maxHistoryEntries = NewNumeric(Clamp(settings.MaxHistoryEntries, 0, 100000), 0, 100000, 100);
            maxHistoryDays = NewNumeric(Clamp(settings.MaxHistoryDays, 0, 3650), 0, 3650, 1);

            var generalLayout = NewRows();
            AddFullRow(generalLayout, active);
            AddFullRow(generalLayout, soundsEnabled);
            AddFullRow(generalLayout, autoGroupByApp);
            AddFullRow(generalLayout, autoCopyLatestRemoteText);
            AddFullRow(generalLayout, autoRemoveUrlTracking);
            AddFullRow(generalLayout, linksHistoryEnabled);
            AddFullRow(generalLayout, saveListPosition);
            AddFullRow(generalLayout, removeDuplicates);
            AddRow(generalLayout, "&Duplicate handling:", duplicateMode);
            AddRow(generalLayout, "Maximum &entries:", maxHistoryEntries);
            AddRow(generalLayout, "Maximum entry a&ge, days:", maxHistoryDays);
            AddFullRow(generalLayout, NewNote("Use 0 for no limit. Pinned entries are kept."));
            general.Controls.Add(generalLayout);

            autoRemoveUnavailableFileHistoryEvents = NewCheckBox("Automatically remove &unavailable file-history events", settings.AutoRemoveUnavailableFileHistoryEvents);
            diagnosticsFileHistoryLimit = NewNumeric(Clamp(settings.DiagnosticsFileHistoryLimit, 0, 200), 0, 200, 1);
            var fileHistoryLayout = NewRows();
            AddFullRow(fileHistoryLayout, autoRemoveUnavailableFileHistoryEvents);
            AddFullRow(fileHistoryLayout, NewNote("Unavailable events include non-file clipboard events that cannot be restored as files, and file events where all referenced paths are now missing."));
            AddRow(fileHistoryLayout, "&Diagnostics event limit:", diagnosticsFileHistoryLimit);
            AddFullRow(fileHistoryLayout, NewNote("Use 0 to include no file-history event details in diagnostics. The total event count is still shown."));
            fileHistory.Controls.Add(fileHistoryLayout);

            showHotkey = NewHotkeyBox(settings.ShowHistoryHotkey, "Show or hide clipboard history global hotkey");
            toggleHotkey = NewHotkeyBox(settings.ToggleActiveHotkey, "Toggle clipboard monitoring global hotkey");
            var hotkeyLayout = NewRows();
            AddRow(hotkeyLayout, "&Show history hotkey:", showHotkey);
            AddRow(hotkeyLayout, "&Toggle on/off hotkey:", toggleHotkey);
            AddFullRow(hotkeyLayout, NewNote("Most global hotkeys should use at least two modifiers. For compatibility, one modifier is allowed with function keys, Grave, or Backslash. Single-modifier letters, numbers, comma, and ordinary editing keys are rejected."));
            hotkeys.Controls.Add(hotkeyLayout);

            databasePath = NewTextBox(DisplayDatabaseFolder(settings.DatabasePath));
            storageMode = NewComboBox("History storage type", new[] { "Local or shared folder", "Clipman Server" }, DisplayStorageMode(settings.StorageMode));
            serverUrl = NewTextBox(settings.ServerUrl);
            serverUrl.AccessibleName = "Clipman Server host";
            serverToken = NewTextBox(settings.ServerToken);
            serverToken.UseSystemPasswordChar = true;
            serverToken.AccessibleName = "Clipman Server token";
            serverToken.AccessibleDescription = "Server authentication token. The token is hidden on screen and saved with Windows user protection.";
            databasePassword = new TextBox
            {
                Width = 260,
                UseSystemPasswordChar = true,
                AccessibleName = "History database password",
                AccessibleDescription = "Password used to encrypt the shared Clipman history database. Leave blank to keep the current password."
            };
            databasePasswordConfirm = new TextBox
            {
                Width = 260,
                UseSystemPasswordChar = true,
                AccessibleName = "Confirm history database password",
                AccessibleDescription = "Retype the history database password. The password and confirmation must match before Clipman saves it."
            };
            showDatabasePassword = NewCheckBox("Sho&w history password", false);
            rememberDatabasePassword = NewCheckBox("&Remember history password on this computer", settings.RememberDatabasePassword);
            rememberDatabasePassword.AccessibleDescription = "When checked, Clipman stores the history password with Windows user protection. When unchecked, Clipman asks for the password when it starts and keeps it only for the current session.";
            ignoredProcesses = new TextBox
            {
                Width = 455,
                Height = 115,
                Multiline = true,
                ScrollBars = ScrollBars.Vertical,
                Text = string.Join(Environment.NewLine, settings.IgnoredProcesses ?? new List<string>()),
                AccessibleName = "Ignored applications"
            };
            ignoredProcesses.Leave += (s, e) => ApplyNow();
            databasePath.Leave += (s, e) => ApplyNow();
            var browse = new Button { Text = "&Browse...", Width = 90 };
            browse.Click += (s, e) => BrowseDatabase();
            var generatePassword = new Button { Text = "&Generate password", Width = 130 };
            generatePassword.Click += (s, e) => GenerateDatabasePassword();
            var clearPassword = new Button { Text = "Use &no password", Width = 130 };
            clearPassword.Click += (s, e) => UseNoDatabasePassword();
            var addRunningApp = new Button { Text = "Add runn&ing app...", Width = 125 };
            addRunningApp.Click += (s, e) => AddRunningApplication();

            var dbPanel = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight };
            dbPanel.Controls.Add(databasePath);
            dbPanel.Controls.Add(browse);
            var passwordPanel = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight };
            passwordPanel.Controls.Add(databasePassword);
            var passwordConfirmPanel = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight };
            passwordConfirmPanel.Controls.Add(databasePasswordConfirm);
            passwordConfirmPanel.Controls.Add(showDatabasePassword);
            var passwordActionsPanel = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight };
            passwordActionsPanel.Controls.Add(generatePassword);
            passwordActionsPanel.Controls.Add(clearPassword);
            var ignoredPanel = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight };
            ignoredPanel.Controls.Add(ignoredProcesses);
            ignoredPanel.Controls.Add(addRunningApp);

            var storageLayout = NewRows();
            AddRow(storageLayout, "Storage &type:", storageMode);
            AddRow(storageLayout, "&Data folder:", dbPanel);
            AddFullRow(storageLayout, NewNote("Choose the folder that contains Clipman's settings, sounds, logs, file history, and local text-history cache. In server mode, Clipman syncs that text-history cache with a Clipman Server."));
            AddRow(storageLayout, "Server &host:", serverUrl);
            AddRow(storageLayout, "Server t&oken:", serverToken);
            AddFullRow(storageLayout, NewNote("Enter a host and port such as home-server:49152. Clipman will infer the local server protocol. Server mode stores the raw clipman-history.clipdb on a Clipman Server. The server never knows the history password; encryption still happens on this computer."));
            AddRow(storageLayout, "History &password:", passwordPanel);
            AddRow(storageLayout, "&Confirm password:", passwordConfirmPanel);
            AddFullRow(storageLayout, rememberDatabasePassword);
            AddFullRow(storageLayout, passwordActionsPanel);
            AddFullRow(storageLayout, NewNote("Leave the password fields blank to keep the current password. To change or add encryption, type the same password in both fields. When Remember is unchecked, Clipman does not save an unlockable password in settings and will ask for it when it starts. To remove encryption, choose Use no password."));
            AddRow(storageLayout, "Ignored &applications:", ignoredPanel);
            AddFullRow(storageLayout, NewNote("One process name per line, such as keepass, chrome, or passwordmanager.exe."));
            storage.Controls.Add(storageLayout);

            runAtStartup = NewCheckBox("Run Clipman at Windows &startup", settings.RunAtStartup);
            captureClipboardOnStartup = NewCheckBox("Add current &clipboard item to Clipman on start", settings.CaptureClipboardOnStartup);
            captureClipboardOnStartup.AccessibleDescription = "When checked, Clipman tries to add the current Windows clipboard item to history once when Clipman starts. This is off by default and still follows monitoring, ignored application, privacy signal, and sensitive data settings.";
            updateCheckFrequency = NewComboBox("Update check frequency", new[] { "Never", "At startup", "Hourly", "Daily" }, DisplayUpdateFrequency(settings.UpdateCheckFrequency));
            installUpdatesSilently = NewCheckBox("&Install updates silently when possible", settings.InstallUpdatesSilently);
            sendToEnabled = NewCheckBox("Add Clipman to the Windows Send &To menu for text files", settings.SendToEnabled);
            showHistoryAfterSendTo = NewCheckBox("Show history window &after Send To imports", settings.ShowHistoryAfterSendTo);

            var integrationLayout = NewRows();
            AddFullRow(integrationLayout, runAtStartup);
            AddFullRow(integrationLayout, captureClipboardOnStartup);
            AddRow(integrationLayout, "Check for &updates:", updateCheckFrequency);
            AddFullRow(integrationLayout, installUpdatesSilently);
            AddFullRow(integrationLayout, NewNote("Silent installs only run when a GitHub release contains a Clipman ZIP package. Settings are preserved."));
            AddFullRow(integrationLayout, sendToEnabled);
            AddFullRow(integrationLayout, showHistoryAfterSendTo);
            integration.Controls.Add(integrationLayout);

            sensitiveDataMode = NewComboBox("Sensitive data mode", new[] { "Off", "Exclude from history" }, DisplaySensitiveDataMode(settings.SensitiveDataMode));
            sensitiveDataPresets = new CheckedListBox
            {
                Width = 455,
                Height = 145,
                CheckOnClick = true,
                AccessibleName = "Sensitive data exclusion presets",
                AccessibleDescription = "Checked presets are excluded from automatic clipboard history when sensitive data mode is set to Exclude from history."
            };
            var enabledSensitivePresets = new HashSet<string>(settings.SensitiveDataPresetIds ?? new List<string>(), StringComparer.OrdinalIgnoreCase);
            foreach (var preset in SensitiveDataExclusion.BuiltInPresets)
            {
                sensitiveDataPresets.Items.Add(preset, enabledSensitivePresets.Contains(preset.Id));
            }
            var sensitiveLayout = NewRows();
            AddRow(sensitiveLayout, "&Sensitive data mode:", sensitiveDataMode);
            AddRow(sensitiveLayout, "Exclusion &presets:", sensitiveDataPresets);
            AddFullRow(sensitiveLayout, NewNote("Sensitive data exclusions apply only to automatic clipboard capture. They do not change the Windows clipboard, existing history, Send To imports, explicit imports, or entries you manually copy from Clipman."));
            AddFullRow(sensitiveLayout, NewNote("Built-in presets are deliberately off by default. Credit card detection uses a Luhn check to reduce false positives. International phone numbers include compact E.164-style numbers such as +447890123456 and common spaced, dashed, dotted, or bracketed variants."));
            sensitiveData.Controls.Add(sensitiveLayout);

            preferencesTabs.TabPages.Add(general);
            preferencesTabs.TabPages.Add(fileHistory);
            preferencesTabs.TabPages.Add(hotkeys);
            preferencesTabs.TabPages.Add(storage);
            preferencesTabs.TabPages.Add(integration);
            preferencesTabs.TabPages.Add(sensitiveData);
            preferencesTabs.SelectedIndex = Clamp(settings.LastPreferencesTab, 0, preferencesTabs.TabPages.Count - 1);
            preferencesTabs.SelectedIndexChanged += (s, e) => ApplyNow();
            Controls.Add(preferencesTabs);

            closeButton = new ShortcutButton
            {
                Text = "Close",
                ShortcutText = "Esc",
                ShortcutKeys = Keys.Escape,
                Left = 690,
                Top = 535,
                Width = 80,
                Anchor = AnchorStyles.Right | AnchorStyles.Bottom,
                AccessibleName = "Close",
                AccessibleDescription = "Closes Preferences. Shortcut Escape."
            };
            closeButton.Click += (s, e) => Close();
            Controls.Add(closeButton);
            AcceptButton = closeButton;
            CancelButton = closeButton;

            WireLiveEvents();
            loading = false;
        }

        public void SetActiveChecked(bool value)
        {
            if (active == null) return;
            loading = true;
            try
            {
                active.Checked = value;
                settings.Active = value;
            }
            finally
            {
                loading = false;
            }
        }

        private void WireLiveEvents()
        {
            showHotkey.TextChanged += (s, e) => ApplyNow();
            toggleHotkey.TextChanged += (s, e) => ApplyNow();
            removeDuplicates.CheckedChanged += (s, e) =>
            {
                if (!loading)
                {
                    duplicateMode.SelectedItem = removeDuplicates.Checked ? "Move to top" : "Keep both";
                }
                ApplyNow();
            };
            duplicateMode.SelectedIndexChanged += (s, e) =>
            {
                if (!loading)
                {
                    var storedDuplicateMode = StoredDuplicateMode(Convert.ToString(duplicateMode.SelectedItem));
                    if (removeDuplicates.Checked == string.Equals(storedDuplicateMode, "KeepBoth", StringComparison.OrdinalIgnoreCase))
                    {
                        loading = true;
                        try
                        {
                            removeDuplicates.Checked = !string.Equals(storedDuplicateMode, "KeepBoth", StringComparison.OrdinalIgnoreCase);
                        }
                        finally
                        {
                            loading = false;
                        }
                    }
                }
                ApplyNow();
            };
            soundsEnabled.CheckedChanged += (s, e) => ApplyNow();
            autoGroupByApp.CheckedChanged += (s, e) => ApplyNow();
            autoCopyLatestRemoteText.CheckedChanged += (s, e) => ApplyNow();
            autoRemoveUrlTracking.CheckedChanged += (s, e) => ApplyNow();
            linksHistoryEnabled.CheckedChanged += (s, e) => ApplyNow();
            saveListPosition.CheckedChanged += (s, e) => ApplyNow();
            active.CheckedChanged += (s, e) => ApplyNow();
            autoRemoveUnavailableFileHistoryEvents.CheckedChanged += (s, e) => ApplyNow();
            diagnosticsFileHistoryLimit.ValueChanged += (s, e) => ApplyNow();
            runAtStartup.CheckedChanged += (s, e) => ApplyNow();
            captureClipboardOnStartup.CheckedChanged += (s, e) => ApplyNow();
            updateCheckFrequency.SelectedIndexChanged += (s, e) => ApplyNow();
            installUpdatesSilently.CheckedChanged += (s, e) => ApplyNow();
            maxHistoryEntries.ValueChanged += (s, e) => ApplyNow();
            maxHistoryDays.ValueChanged += (s, e) => ApplyNow();
            showDatabasePassword.CheckedChanged += (s, e) => ToggleDatabasePasswordVisibility();
            sendToEnabled.CheckedChanged += (s, e) => ApplyNow();
            showHistoryAfterSendTo.CheckedChanged += (s, e) => ApplyNow();
            sensitiveDataMode.SelectedIndexChanged += (s, e) => ApplyNow();
            sensitiveDataPresets.ItemCheck += (s, e) => BeginInvoke(new Action(ApplyNow));
        }

        private void ApplyNow()
        {
            if (loading) return;

            HotkeyDefinition parsed;
            if (!HotkeyDefinition.TryParse(showHotkey.Text, out parsed) ||
                !HotkeyDefinition.TryParse(toggleHotkey.Text, out parsed) ||
                HotkeysConflict(showHotkey.Text, toggleHotkey.Text) ||
                string.IsNullOrWhiteSpace(databasePath.Text))
            {
                return;
            }

            if (!ValidateDatabasePasswordInput(false)) return;

            settings.ShowHistoryHotkey = showHotkey.Text.Trim();
            settings.ToggleActiveHotkey = toggleHotkey.Text.Trim();
            settings.DuplicateMode = StoredDuplicateMode(Convert.ToString(duplicateMode.SelectedItem));
            settings.RemoveDuplicates = !string.Equals(settings.DuplicateMode, "KeepBoth", StringComparison.OrdinalIgnoreCase);
            settings.SoundsEnabled = soundsEnabled.Checked;
            settings.AutoGroupByApp = autoGroupByApp.Checked;
            settings.AutoCopyLatestRemoteText = autoCopyLatestRemoteText.Checked;
            settings.AutoRemoveUrlTracking = autoRemoveUrlTracking.Checked;
            settings.LinksHistoryEnabled = linksHistoryEnabled.Checked;
            settings.LastSelectedHistoryTab = HistoryTabs.Normalize(settings.LastSelectedHistoryTab, settings.LinksHistoryEnabled);
            settings.SaveListPosition = saveListPosition.Checked;
            settings.Active = active.Checked;
            settings.AutoRemoveUnavailableFileHistoryEvents = autoRemoveUnavailableFileHistoryEvents.Checked;
            settings.DiagnosticsFileHistoryLimit = (int)diagnosticsFileHistoryLimit.Value;
            settings.RunAtStartup = runAtStartup.Checked;
            settings.CaptureClipboardOnStartup = captureClipboardOnStartup.Checked;
            settings.UpdateCheckFrequency = StoredUpdateFrequency(Convert.ToString(updateCheckFrequency.SelectedItem));
            settings.InstallUpdatesSilently = installUpdatesSilently.Checked;
            settings.LastPreferencesTab = preferencesTabs == null ? 0 : preferencesTabs.SelectedIndex;
            settings.RememberDatabasePassword = rememberDatabasePassword.Checked;
            settings.PlainDatabasePassword = string.Empty;
            settings.PasswordClearRequested = passwordClearRequested;
            if (databasePassword.Text.Length > 0)
            {
                settings.PasswordClearRequested = false;
                settings.PlainDatabasePassword = databasePassword.Text;
                settings.ProtectedDatabasePassword = settings.RememberDatabasePassword ? DatabasePasswordProtector.Protect(databasePassword.Text) : string.Empty;
                settings.DatabaseEncryptionEnabled = true;
            }
            else
            {
                if (!settings.RememberDatabasePassword)
                {
                    settings.ProtectedDatabasePassword = string.Empty;
                }
                settings.DatabaseEncryptionEnabled = settings.DatabaseEncryptionEnabled || !string.IsNullOrWhiteSpace(settings.ProtectedDatabasePassword);
            }
            settings.DatabasePath = DatabasePathFromFolderOrFile(databasePath.Text);
            settings.UseDefaultDatabasePath = IsCurrentDefaultDatabasePath(settings.DatabasePath);
            settings.StorageMode = StoredStorageMode(Convert.ToString(storageMode.SelectedItem));
            settings.ServerUrl = ServerSettingsSanitizer.CleanUrl(serverUrl.Text);
            settings.ServerToken = ServerSettingsSanitizer.CleanToken(serverToken.Text);
            if (!loading)
            {
                UpdateTextIfChanged(serverUrl, settings.ServerUrl);
                UpdateTextIfChanged(serverToken, settings.ServerToken);
            }
            settings.MaxHistoryEntries = (int)maxHistoryEntries.Value;
            settings.MaxHistoryDays = (int)maxHistoryDays.Value;
            settings.SendToEnabled = sendToEnabled.Checked;
            settings.ShowHistoryAfterSendTo = showHistoryAfterSendTo.Checked;
            settings.SensitiveDataMode = StoredSensitiveDataMode(Convert.ToString(sensitiveDataMode.SelectedItem));
            settings.SensitiveDataPresetIds = sensitiveDataPresets.CheckedItems
                .OfType<SensitiveDataPreset>()
                .Select(p => p.Id)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
            settings.IgnoredProcesses = ignoredProcesses.Lines
                .Select(l => l.Trim())
                .Where(l => l.Length > 0)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
            if (applySettings != null)
            {
                var focused = ActiveControl;
                try
                {
                    applySettings(settings);
                }
                catch (Exception ex)
                {
                    MessageBox.Show(
                        this,
                        "Clipman could not save these preferences. The previous settings are still active.\r\n\r\n" + ex.Message,
                        "Clipman Preferences",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Warning);
                    return;
                }
                passwordClearRequested = false;
                settings.PasswordClearRequested = false;
                BeginInvoke(new Action(() =>
                {
                    if (IsDisposed) return;
                    Activate();
                    if (focused != null && !focused.IsDisposed)
                    {
                        focused.Focus();
                    }
                }));
            }
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape)
            {
                Close();
                e.Handled = true;
                return;
            }

            base.OnKeyDown(e);
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            if ((keyData & Keys.Control) == Keys.Control &&
                (keyData & Keys.Alt) == 0 &&
                (keyData & Keys.Shift) == 0 &&
                SelectPreferencesTabByShortcut(keyData & Keys.KeyCode))
            {
                return true;
            }

            return base.ProcessCmdKey(ref msg, keyData);
        }

        private bool SelectPreferencesTabByShortcut(Keys key)
        {
            if (preferencesTabs == null) return false;

            var index = -1;
            if (key >= Keys.D1 && key <= Keys.D9)
            {
                index = key - Keys.D1;
            }
            else if (key == Keys.D0)
            {
                index = 9;
            }
            else if (key >= Keys.NumPad1 && key <= Keys.NumPad9)
            {
                index = key - Keys.NumPad1;
            }
            else if (key == Keys.NumPad0)
            {
                index = 9;
            }

            if (index < 0 || index >= preferencesTabs.TabPages.Count) return false;
            preferencesTabs.SelectedIndex = index;
            return true;
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (!ValidateDatabasePasswordInput(true))
            {
                e.Cancel = true;
                return;
            }

            if (!ConfirmSingleModifierHotkeys())
            {
                e.Cancel = true;
                return;
            }

            ApplyNow();
            base.OnFormClosing(e);
        }

        private bool ConfirmSingleModifierHotkeys()
        {
            if (acceptedSingleModifierHotkeyWarning)
            {
                return true;
            }

            if (!HotkeyDefinition.IsSingleModifierHotkey(showHotkey.Text) &&
                !HotkeyDefinition.IsSingleModifierHotkey(toggleHotkey.Text))
            {
                return true;
            }

            var result = MessageBox.Show(
                this,
                "One of your global hotkeys uses only one modifier. Clipman allows this for compatibility, but it is more likely to conflict with other apps or keyboard layouts. Keep this hotkey anyway?",
                "Clipman hotkeys",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning);
            if (result == DialogResult.Yes)
            {
                acceptedSingleModifierHotkeyWarning = true;
                return true;
            }

            preferencesTabs.SelectedIndex = 2;
            showHotkey.Focus();
            return false;
        }

        private bool ValidateDatabasePasswordInput(bool showMessage)
        {
            if ((databasePassword.Text.Length > 0 || databasePasswordConfirm.Text.Length > 0) &&
                !string.Equals(databasePassword.Text, databasePasswordConfirm.Text, StringComparison.Ordinal))
            {
                if (showMessage)
                {
                    MessageBox.Show(this, "The history password and confirmation do not match.", "Clipman history password", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    databasePasswordConfirm.Focus();
                }
                return false;
            }

            return true;
        }

        private void BrowseDatabase()
        {
            using (var dialog = new FolderBrowserDialog())
            {
                dialog.Description = "Choose the Clipman data folder. Clipman will use clipman-history.clipdb inside this folder.";
                dialog.ShowNewFolderButton = true;
                var dir = DisplayDatabaseFolder(databasePath.Text);
                if (!string.IsNullOrEmpty(dir) && Directory.Exists(dir))
                {
                    dialog.SelectedPath = dir;
                }

                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    databasePath.Text = dialog.SelectedPath;
                    settings.UseDefaultDatabasePath = IsCurrentDefaultDatabasePath(DatabasePathFromFolderOrFile(dialog.SelectedPath));
                    ApplyNow();
                }
            }
        }

        private void AddRunningApplication()
        {
            using (var dialog = new RunningProcessPickerForm())
            {
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                var processName = NormalizeProcessName(dialog.SelectedProcessName);
                if (string.IsNullOrEmpty(processName)) return;

                var existing = ignoredProcesses.Lines
                    .Select(l => NormalizeProcessName(l))
                    .Where(l => l.Length > 0)
                    .ToList();
                if (!existing.Contains(processName, StringComparer.OrdinalIgnoreCase))
                {
                    var lines = ignoredProcesses.Lines
                        .Select(l => l.Trim())
                        .Where(l => l.Length > 0)
                        .ToList();
                    lines.Add(processName);
                    ignoredProcesses.Text = string.Join(Environment.NewLine, lines);
                    ApplyNow();
                }
            }
        }

        private void GenerateDatabasePassword()
        {
            var password = DatabasePasswordProtector.GeneratePassword();
            databasePassword.Text = password;
            databasePasswordConfirm.Text = password;
            copySensitiveText(password);
            ApplyNow();
            MessageBox.Show(this, "A new history password was generated and copied to the Windows clipboard. Clipman will not save this generated password in clipboard history. Save it somewhere safe and enter it on each computer that shares this Clipman database.", "Clipman history password", MessageBoxButtons.OK, MessageBoxIcon.Information);
            databasePassword.Focus();
        }

        private void UseNoDatabasePassword()
        {
            if (settings.DatabaseEncryptionEnabled || !string.IsNullOrWhiteSpace(settings.ProtectedDatabasePassword))
            {
                var result = MessageBox.Show(this, "Remove the saved history password and rewrite the Clipman database without password encryption?", "Clipman history password", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                if (result != DialogResult.Yes) return;
            }

            databasePassword.Text = string.Empty;
            databasePasswordConfirm.Text = string.Empty;
            settings.ProtectedDatabasePassword = string.Empty;
            settings.PlainDatabasePassword = string.Empty;
            passwordClearRequested = true;
            settings.PasswordClearRequested = true;
            settings.RememberDatabasePassword = false;
            settings.DatabaseEncryptionEnabled = false;
            rememberDatabasePassword.Checked = false;
            ApplyNow();
            MessageBox.Show(this, "Clipman will use this database without a history password.", "Clipman history password", MessageBoxButtons.OK, MessageBoxIcon.Information);
            databasePassword.Focus();
        }

        private void ToggleDatabasePasswordVisibility()
        {
            var hidden = !showDatabasePassword.Checked;
            databasePassword.UseSystemPasswordChar = hidden;
            databasePasswordConfirm.UseSystemPasswordChar = hidden;
        }

        private static AppSettings CloneSettings(AppSettings current)
        {
            return new AppSettings
            {
                ShowHistoryHotkey = current.ShowHistoryHotkey,
                ToggleActiveHotkey = current.ToggleActiveHotkey,
                QuickCopyHotkeys = current.QuickCopyHotkeys == null
                    ? new List<QuickCopyBinding>()
                    : current.QuickCopyHotkeys.Select(b => new QuickCopyBinding { EntryId = b.EntryId, Hotkey = b.Hotkey, Mode = QuickPasteModes.Normalize(b.Mode) }).ToList(),
                AutoCopyLatestRemoteText = current.AutoCopyLatestRemoteText,
                RemoveDuplicates = current.RemoveDuplicates,
                SoundsEnabled = current.SoundsEnabled,
                SaveListPosition = current.SaveListPosition,
                Active = current.Active,
                DatabasePath = current.DatabasePath,
                StorageMode = current.StorageMode,
                ServerUrl = current.ServerUrl,
                ServerToken = current.ServerToken,
                ProtectedServerToken = current.ProtectedServerToken,
                LastSelectedIndex = current.LastSelectedIndex,
                LastSelectedTab = current.LastSelectedTab,
                LastPreferencesTab = current.LastPreferencesTab,
                MaxHistoryEntries = current.MaxHistoryEntries,
                MaxHistoryDays = current.MaxHistoryDays,
                IgnoredProcesses = current.IgnoredProcesses == null ? new List<string>() : new List<string>(current.IgnoredProcesses),
                SortMode = current.SortMode,
                SortDescending = current.SortDescending,
                FileHistorySortMode = current.FileHistorySortMode,
                FileHistorySortDescending = current.FileHistorySortDescending,
                SendToEnabled = current.SendToEnabled,
                ShowHistoryAfterSendTo = current.ShowHistoryAfterSendTo,
                GroupFilter = current.GroupFilter,
                DuplicateMode = current.DuplicateMode,
                AutoGroupByApp = current.AutoGroupByApp,
                AutoRemoveUrlTracking = current.AutoRemoveUrlTracking,
                LinksHistoryEnabled = current.LinksHistoryEnabled,
                LastSelectedHistoryTab = current.LastSelectedHistoryTab,
                AutoRemoveUnavailableFileHistoryEvents = current.AutoRemoveUnavailableFileHistoryEvents,
                DiagnosticsFileHistoryLimit = current.DiagnosticsFileHistoryLimit,
                RunAtStartup = current.RunAtStartup,
                CaptureClipboardOnStartup = current.CaptureClipboardOnStartup,
                UpdateCheckFrequency = current.UpdateCheckFrequency,
                InstallUpdatesSilently = current.InstallUpdatesSilently,
                DatabaseEncryptionEnabled = current.DatabaseEncryptionEnabled,
                RememberDatabasePassword = current.RememberDatabasePassword,
                ProtectedDatabasePassword = current.ProtectedDatabasePassword,
                PlainDatabasePassword = string.Empty,
                PasswordClearRequested = false,
                UseDefaultDatabasePath = current.UseDefaultDatabasePath,
                SensitiveDataMode = SensitiveDataExclusion.NormalizeMode(current.SensitiveDataMode),
                SensitiveDataPresetIds = current.SensitiveDataPresetIds == null ? new List<string>() : new List<string>(current.SensitiveDataPresetIds)
            };
        }

        private static bool IsCurrentDefaultDatabasePath(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return true;
            try
            {
                var appDirectory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
                var defaultPath = Path.Combine(appDirectory, "Settings", "clipman-history.clipdb");
                return string.Equals(Path.GetFullPath(path), Path.GetFullPath(defaultPath), StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        private static string DisplayDatabaseFolder(string path)
        {
            var resolved = DatabasePathFromFolderOrFile(path);
            if (string.IsNullOrWhiteSpace(resolved))
            {
                return Path.Combine(AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar), "Settings");
            }

            var fileName = Path.GetFileName(resolved);
            if (string.Equals(Path.GetExtension(fileName), ".clipdb", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(fileName, "clipman-history.clipdb", StringComparison.OrdinalIgnoreCase))
            {
                return resolved;
            }

            if (Directory.Exists(resolved))
            {
                return resolved;
            }

            var directory = Path.GetDirectoryName(resolved);
            return string.IsNullOrWhiteSpace(directory) ? resolved : directory;
        }

        private static string DatabasePathFromFolderOrFile(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return string.Empty;

            var trimmed = path.Trim().TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (string.IsNullOrWhiteSpace(trimmed)) return string.Empty;

            if (Directory.Exists(trimmed))
            {
                return Path.Combine(trimmed, "clipman-history.clipdb");
            }

            var fileName = Path.GetFileName(trimmed);
            if (string.Equals(fileName, "clipman-history.clipdb", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(Path.GetExtension(fileName), ".clipdb", StringComparison.OrdinalIgnoreCase))
            {
                return trimmed;
            }

            return Path.Combine(trimmed, "clipman-history.clipdb");
        }

        private static TableLayoutPanel NewRows()
        {
            var panel = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 2,
                Padding = new Padding(12),
                AutoScroll = true
            };
            panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 185));
            panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            return panel;
        }

        private static void AddRow(TableLayoutPanel panel, string labelText, Control control)
        {
            var row = panel.RowCount++;
            panel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            panel.Controls.Add(new Label { Text = labelText, AutoSize = true, Padding = new Padding(0, 5, 0, 8) }, 0, row);
            control.Margin = new Padding(3, 3, 3, 8);
            panel.Controls.Add(control, 1, row);
        }

        private static void AddFullRow(TableLayoutPanel panel, Control control)
        {
            var row = panel.RowCount++;
            panel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            control.Margin = new Padding(3, 3, 3, 8);
            panel.Controls.Add(control, 0, row);
            panel.SetColumnSpan(control, 2);
        }

        private static Label NewNote(string text)
        {
            return new Label { Text = text, AutoSize = true, MaximumSize = new System.Drawing.Size(690, 0) };
        }

        private static TextBox NewTextBox(string text)
        {
            return new TextBox { Width = 455, Text = text ?? string.Empty };
        }

        private static NumericUpDown NewNumeric(int value, int min, int max, int increment)
        {
            return new NumericUpDown { Width = 110, Minimum = min, Maximum = max, Increment = increment, Value = value };
        }

        private static ComboBox NewComboBox(string accessibleName, IEnumerable<string> items, string selected)
        {
            var combo = new ComboBox
            {
                Width = 190,
                DropDownStyle = ComboBoxStyle.DropDownList,
                AccessibleName = accessibleName
            };
            foreach (var item in items) combo.Items.Add(item);
            combo.SelectedItem = selected;
            if (combo.SelectedIndex < 0) combo.SelectedIndex = 0;
            return combo;
        }

        private static TextBox NewHotkeyBox(string text, string accessibleName)
        {
            var box = new TextBox
            {
                Width = 180,
                Text = text ?? string.Empty,
                ReadOnly = false,
                ShortcutsEnabled = false,
                AccessibleName = accessibleName,
                AccessibleDescription = "Press a global key combination. Two modifiers are safest, such as Control Alt Backslash, Windows Alt H, or Control Shift H. One modifier is allowed only with function keys, Grave, or Backslash. Press Delete or Backspace to clear this hotkey. Modifier-only and unsafe Windows shortcuts are rejected."
            };
            box.KeyDown += HotkeyBoxKeyDown;
            box.KeyPress += SuppressHotkeyTextInput;
            return box;
        }

        private static CheckBox NewCheckBox(string text, bool isChecked)
        {
            return new CheckBox { Text = text, Width = 680, Checked = isChecked, AutoSize = true };
        }

        private static string NormalizeProcessName(string processName)
        {
            if (string.IsNullOrWhiteSpace(processName)) return string.Empty;
            var trimmed = processName.Trim();
            return trimmed.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
                ? Path.GetFileNameWithoutExtension(trimmed)
                : trimmed;
        }

        private static int Clamp(int value, int min, int max)
        {
            if (value < min) return min;
            if (value > max) return max;
            return value;
        }

        private static string DisplayUpdateFrequency(string value)
        {
            var stored = StoredUpdateFrequency(value);
            if (string.Equals(stored, "Startup", StringComparison.OrdinalIgnoreCase)) return "At startup";
            if (string.Equals(stored, "Hourly", StringComparison.OrdinalIgnoreCase)) return "Hourly";
            if (string.Equals(stored, "Daily", StringComparison.OrdinalIgnoreCase)) return "Daily";
            return "Never";
        }

        private static string StoredUpdateFrequency(string value)
        {
            if (string.Equals(value, "At startup", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(value, "Startup", StringComparison.OrdinalIgnoreCase))
            {
                return "Startup";
            }
            if (string.Equals(value, "Hourly", StringComparison.OrdinalIgnoreCase)) return "Hourly";
            if (string.Equals(value, "Daily", StringComparison.OrdinalIgnoreCase)) return "Daily";
            return "Never";
        }

        private static string DisplayDuplicateMode(string value)
        {
            if (string.Equals(value, "Ignore", StringComparison.OrdinalIgnoreCase)) return "Ignore";
            if (string.Equals(value, "KeepBoth", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(value, "Keep both", StringComparison.OrdinalIgnoreCase))
            {
                return "Keep both";
            }
            return "Move to top";
        }

        private static string StoredDuplicateMode(string value)
        {
            if (string.Equals(value, "Ignore", StringComparison.OrdinalIgnoreCase)) return "Ignore";
            if (string.Equals(value, "Keep both", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(value, "KeepBoth", StringComparison.OrdinalIgnoreCase))
            {
                return "KeepBoth";
            }
            return "MoveToTop";
        }

        private static string DisplayStorageMode(string value)
        {
            return string.Equals(value, "Server", StringComparison.OrdinalIgnoreCase)
                ? "Clipman Server"
                : "Local or shared folder";
        }

        private static string StoredStorageMode(string value)
        {
            return string.Equals(value, "Clipman Server", StringComparison.OrdinalIgnoreCase) ||
                   string.Equals(value, "Server", StringComparison.OrdinalIgnoreCase)
                ? "Server"
                : "File";
        }

        private static void UpdateTextIfChanged(TextBox box, string value)
        {
            var normalized = value ?? string.Empty;
            if (box != null && !string.Equals(box.Text, normalized, StringComparison.Ordinal))
            {
                var selectionStart = Math.Min(box.SelectionStart, normalized.Length);
                box.Text = normalized;
                box.SelectionStart = selectionStart;
            }
        }

        private static string DisplaySensitiveDataMode(string value)
        {
            return string.Equals(value, SensitiveDataExclusion.ModeExclude, StringComparison.OrdinalIgnoreCase)
                ? "Exclude from history"
                : "Off";
        }

        private static string StoredSensitiveDataMode(string value)
        {
            return string.Equals(value, "Exclude from history", StringComparison.OrdinalIgnoreCase)
                ? SensitiveDataExclusion.ModeExclude
                : SensitiveDataExclusion.ModeOff;
        }

        private static bool HotkeysConflict(params string[] hotkeys)
        {
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var hotkey in hotkeys ?? Enumerable.Empty<string>())
            {
                var normalized = (hotkey ?? string.Empty).Trim();
                if (normalized.Length == 0) continue;
                if (!seen.Add(normalized)) return true;
            }
            return false;
        }

        private static void HotkeyBoxKeyDown(object sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Tab || e.KeyCode == Keys.Escape || e.KeyCode == Keys.Enter)
            {
                return;
            }

            e.Handled = true;
            e.SuppressKeyPress = true;
            if (e.KeyCode == Keys.Back || e.KeyCode == Keys.Delete)
            {
                ((TextBox)sender).Clear();
                return;
            }

            if (HotkeyDefinition.IsModifierOnly(e.KeyData))
            {
                return;
            }

            var text = HotkeyDefinition.FromKeys(e.KeyData);
            HotkeyDefinition parsed;
            if (!string.IsNullOrWhiteSpace(text) && HotkeyDefinition.TryParse(text, out parsed))
            {
                ((TextBox)sender).Text = text;
                return;
            }

            System.Media.SystemSounds.Beep.Play();
        }

        private static void SuppressHotkeyTextInput(object sender, KeyPressEventArgs e)
        {
            e.Handled = true;
        }
    }
}
