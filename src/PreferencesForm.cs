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
        private readonly CheckBox autoRemoveUrlTracking;
        private readonly CheckBox saveListPosition;
        private readonly CheckBox active;
        private readonly CheckBox runAtStartup;
        private readonly ComboBox updateCheckFrequency;
        private readonly CheckBox installUpdatesSilently;
        private readonly TabControl preferencesTabs;
        private readonly TextBox databasePath;
        private readonly TextBox databasePassword;
        private readonly TextBox databasePasswordConfirm;
        private readonly CheckBox showDatabasePassword;
        private readonly Action<string> copySensitiveText;
        private readonly ShortcutButton closeButton;
        private readonly NumericUpDown maxHistoryEntries;
        private readonly NumericUpDown maxHistoryDays;
        private readonly CheckBox autoRemoveUnavailableFileHistoryEvents;
        private readonly NumericUpDown diagnosticsFileHistoryLimit;
        private readonly TextBox ignoredProcesses;
        private readonly CheckBox sendToEnabled;
        private readonly CheckBox showHistoryAfterSendTo;
        private bool loading;

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
                AccessibleDescription = "Preference sections. Press Control 1 through Control 5 to switch tabs."
            };

            var general = new TabPage("General");
            var fileHistory = new TabPage("File history");
            var hotkeys = new TabPage("Hotkeys");
            var storage = new TabPage("Storage and Password");
            var integration = new TabPage("Startup and updates");
            general.AccessibleDescription = "General preferences. Shortcut Ctrl+1.";
            fileHistory.AccessibleDescription = "File history preferences. Shortcut Ctrl+2.";
            hotkeys.AccessibleDescription = "Hotkeys preferences. Shortcut Ctrl+3.";
            storage.AccessibleDescription = "Storage and Password preferences. Shortcut Ctrl+4.";
            integration.AccessibleDescription = "Startup and updates preferences. Shortcut Ctrl+5.";

            active = NewCheckBox("Clipboard monitoring &active", settings.Active);
            soundsEnabled = NewCheckBox("Play &sounds", settings.SoundsEnabled);
            autoGroupByApp = NewCheckBox("Automatically group &new clips by source application", settings.AutoGroupByApp);
            autoRemoveUrlTracking = NewCheckBox("Automatically remove URL &tracking from copied text", settings.AutoRemoveUrlTracking);
            saveListPosition = NewCheckBox("Save list &position", settings.SaveListPosition);
            removeDuplicates = NewCheckBox("&Remove duplicate entries", settings.RemoveDuplicates);
            duplicateMode = NewComboBox("Duplicate handling", new[] { "MoveToTop", "Ignore", "KeepBoth" }, string.IsNullOrWhiteSpace(settings.DuplicateMode) ? "MoveToTop" : settings.DuplicateMode);
            removeDuplicates.Checked = !string.Equals(Convert.ToString(duplicateMode.SelectedItem), "KeepBoth", StringComparison.OrdinalIgnoreCase);
            maxHistoryEntries = NewNumeric(Clamp(settings.MaxHistoryEntries, 0, 100000), 0, 100000, 100);
            maxHistoryDays = NewNumeric(Clamp(settings.MaxHistoryDays, 0, 3650), 0, 3650, 1);

            var generalLayout = NewRows();
            AddFullRow(generalLayout, active);
            AddFullRow(generalLayout, soundsEnabled);
            AddFullRow(generalLayout, autoGroupByApp);
            AddFullRow(generalLayout, autoRemoveUrlTracking);
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
            AddFullRow(hotkeyLayout, NewNote("Global hotkeys must use at least two keys and cannot be modifier-only."));
            hotkeys.Controls.Add(hotkeyLayout);

            databasePath = NewTextBox(DisplayDatabaseFolder(settings.DatabasePath));
            databasePath.Leave += (s, e) => ApplyNow();
            databasePassword = new TextBox
            {
                Width = 260,
                UseSystemPasswordChar = true,
                AccessibleName = "History database password",
                AccessibleDescription = "Password used to encrypt the shared Clipman history database. It is protected by Windows for this user account."
            };
            databasePasswordConfirm = new TextBox
            {
                Width = 260,
                UseSystemPasswordChar = true,
                AccessibleName = "Confirm history database password",
                AccessibleDescription = "Retype the history database password. The password and confirmation must match before Clipman saves it."
            };
            showDatabasePassword = NewCheckBox("Sho&w history password", false);
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
            var browse = new Button { Text = "&Browse...", Width = 90 };
            browse.Click += (s, e) => BrowseDatabase();
            var generatePassword = new Button { Text = "&Generate password", Width = 130 };
            generatePassword.Click += (s, e) => GenerateDatabasePassword();
            var clearPassword = new Button { Text = "&Use no password", Width = 130 };
            clearPassword.Click += (s, e) => UseNoDatabasePassword();
            var addRunningApp = new Button { Text = "Add &running app...", Width = 125 };
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
            AddRow(storageLayout, "&Data folder:", dbPanel);
            AddFullRow(storageLayout, NewNote("Choose the folder that contains Clipman's settings and history files. Clipman uses clipman-history.clipdb inside this folder, plus machine-specific settings and file-history files."));
            AddRow(storageLayout, "History &password:", passwordPanel);
            AddRow(storageLayout, "&Confirm password:", passwordConfirmPanel);
            AddFullRow(storageLayout, passwordActionsPanel);
            AddFullRow(storageLayout, NewNote("Leave the password fields blank for no password on a new database. To change or add encryption, type the same password in both fields. To remove a saved password, choose Use no password. The password is protected by Windows per user and machine, so copying a settings file to another computer does not carry a working key."));
            AddRow(storageLayout, "Ignored &applications:", ignoredPanel);
            AddFullRow(storageLayout, NewNote("One process name per line, such as keepass, chrome, or passwordmanager.exe."));
            storage.Controls.Add(storageLayout);

            runAtStartup = NewCheckBox("Run Clipman at Windows &startup", settings.RunAtStartup);
            updateCheckFrequency = NewComboBox("Update check frequency", new[] { "Never", "At startup", "Hourly", "Daily" }, DisplayUpdateFrequency(settings.UpdateCheckFrequency));
            installUpdatesSilently = NewCheckBox("&Install updates silently when possible", settings.InstallUpdatesSilently);
            sendToEnabled = NewCheckBox("Add Clipman to the Windows Send &To menu for text files", settings.SendToEnabled);
            showHistoryAfterSendTo = NewCheckBox("Show history window &after Send To imports", settings.ShowHistoryAfterSendTo);

            var integrationLayout = NewRows();
            AddFullRow(integrationLayout, runAtStartup);
            AddRow(integrationLayout, "Check for &updates:", updateCheckFrequency);
            AddFullRow(integrationLayout, installUpdatesSilently);
            AddFullRow(integrationLayout, NewNote("Silent installs only run when a GitHub release contains a Clipman ZIP package. Settings are preserved."));
            AddFullRow(integrationLayout, sendToEnabled);
            AddFullRow(integrationLayout, showHistoryAfterSendTo);
            integration.Controls.Add(integrationLayout);

            preferencesTabs.TabPages.Add(general);
            preferencesTabs.TabPages.Add(fileHistory);
            preferencesTabs.TabPages.Add(hotkeys);
            preferencesTabs.TabPages.Add(storage);
            preferencesTabs.TabPages.Add(integration);
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
                    duplicateMode.SelectedItem = removeDuplicates.Checked ? "MoveToTop" : "KeepBoth";
                }
                ApplyNow();
            };
            duplicateMode.SelectedIndexChanged += (s, e) =>
            {
                if (!loading)
                {
                    removeDuplicates.Checked = !string.Equals(Convert.ToString(duplicateMode.SelectedItem), "KeepBoth", StringComparison.OrdinalIgnoreCase);
                }
                ApplyNow();
            };
            soundsEnabled.CheckedChanged += (s, e) => ApplyNow();
            autoGroupByApp.CheckedChanged += (s, e) => ApplyNow();
            autoRemoveUrlTracking.CheckedChanged += (s, e) => ApplyNow();
            saveListPosition.CheckedChanged += (s, e) => ApplyNow();
            active.CheckedChanged += (s, e) => ApplyNow();
            autoRemoveUnavailableFileHistoryEvents.CheckedChanged += (s, e) => ApplyNow();
            diagnosticsFileHistoryLimit.ValueChanged += (s, e) => ApplyNow();
            runAtStartup.CheckedChanged += (s, e) => ApplyNow();
            updateCheckFrequency.SelectedIndexChanged += (s, e) => ApplyNow();
            installUpdatesSilently.CheckedChanged += (s, e) => ApplyNow();
            maxHistoryEntries.ValueChanged += (s, e) => ApplyNow();
            maxHistoryDays.ValueChanged += (s, e) => ApplyNow();
            showDatabasePassword.CheckedChanged += (s, e) => ToggleDatabasePasswordVisibility();
            sendToEnabled.CheckedChanged += (s, e) => ApplyNow();
            showHistoryAfterSendTo.CheckedChanged += (s, e) => ApplyNow();
        }

        private void ApplyNow()
        {
            if (loading) return;

            HotkeyDefinition parsed;
            if (!HotkeyDefinition.TryParse(showHotkey.Text, out parsed) ||
                !HotkeyDefinition.TryParse(toggleHotkey.Text, out parsed) ||
                string.IsNullOrWhiteSpace(databasePath.Text))
            {
                return;
            }

            if (!ValidateDatabasePasswordInput(false)) return;

            settings.ShowHistoryHotkey = showHotkey.Text.Trim();
            settings.ToggleActiveHotkey = toggleHotkey.Text.Trim();
            settings.DuplicateMode = Convert.ToString(duplicateMode.SelectedItem);
            settings.RemoveDuplicates = !string.Equals(settings.DuplicateMode, "KeepBoth", StringComparison.OrdinalIgnoreCase);
            settings.SoundsEnabled = soundsEnabled.Checked;
            settings.AutoGroupByApp = autoGroupByApp.Checked;
            settings.AutoRemoveUrlTracking = autoRemoveUrlTracking.Checked;
            settings.SaveListPosition = saveListPosition.Checked;
            settings.Active = active.Checked;
            settings.AutoRemoveUnavailableFileHistoryEvents = autoRemoveUnavailableFileHistoryEvents.Checked;
            settings.DiagnosticsFileHistoryLimit = (int)diagnosticsFileHistoryLimit.Value;
            settings.RunAtStartup = runAtStartup.Checked;
            settings.UpdateCheckFrequency = StoredUpdateFrequency(Convert.ToString(updateCheckFrequency.SelectedItem));
            settings.InstallUpdatesSilently = installUpdatesSilently.Checked;
            settings.LastPreferencesTab = preferencesTabs == null ? 0 : preferencesTabs.SelectedIndex;
            if (databasePassword.Text.Length > 0)
            {
                settings.ProtectedDatabasePassword = DatabasePasswordProtector.Protect(databasePassword.Text);
                settings.DatabaseEncryptionEnabled = true;
            }
            else
            {
                settings.DatabaseEncryptionEnabled = !string.IsNullOrWhiteSpace(settings.ProtectedDatabasePassword);
            }
            settings.DatabasePath = DatabasePathFromFolderOrFile(databasePath.Text);
            settings.UseDefaultDatabasePath = IsCurrentDefaultDatabasePath(settings.DatabasePath);
            settings.MaxHistoryEntries = (int)maxHistoryEntries.Value;
            settings.MaxHistoryDays = (int)maxHistoryDays.Value;
            settings.SendToEnabled = sendToEnabled.Checked;
            settings.ShowHistoryAfterSendTo = showHistoryAfterSendTo.Checked;
            settings.IgnoredProcesses = ignoredProcesses.Lines
                .Select(l => l.Trim())
                .Where(l => l.Length > 0)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
            if (applySettings != null)
            {
                var focused = ActiveControl;
                applySettings(settings);
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

            ApplyNow();
            base.OnFormClosing(e);
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
            if (!string.IsNullOrWhiteSpace(settings.ProtectedDatabasePassword))
            {
                var result = MessageBox.Show(this, "Remove the saved history password and rewrite the Clipman database without password encryption?", "Clipman history password", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                if (result != DialogResult.Yes) return;
            }

            databasePassword.Text = string.Empty;
            databasePasswordConfirm.Text = string.Empty;
            settings.ProtectedDatabasePassword = string.Empty;
            settings.DatabaseEncryptionEnabled = false;
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
                RemoveDuplicates = current.RemoveDuplicates,
                SoundsEnabled = current.SoundsEnabled,
                SaveListPosition = current.SaveListPosition,
                Active = current.Active,
                DatabasePath = current.DatabasePath,
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
                AutoRemoveUnavailableFileHistoryEvents = current.AutoRemoveUnavailableFileHistoryEvents,
                DiagnosticsFileHistoryLimit = current.DiagnosticsFileHistoryLimit,
                RunAtStartup = current.RunAtStartup,
                UpdateCheckFrequency = current.UpdateCheckFrequency,
                InstallUpdatesSilently = current.InstallUpdatesSilently,
                DatabaseEncryptionEnabled = current.DatabaseEncryptionEnabled,
                ProtectedDatabasePassword = current.ProtectedDatabasePassword,
                UseDefaultDatabasePath = current.UseDefaultDatabasePath
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
                ReadOnly = true,
                AccessibleName = accessibleName,
                AccessibleDescription = "Press a global key combination with at least two modifiers, such as Control Alt Backslash or Control Shift H. Modifier-only and unsafe Windows shortcuts are rejected."
            };
            box.KeyDown += HotkeyBoxKeyDown;
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
    }
}
