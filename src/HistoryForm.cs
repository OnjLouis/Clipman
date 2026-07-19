using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class HistoryForm : Form
    {
        private readonly ClipStore store;
        private readonly AppSettings settings;
        private readonly Action saveSettings;
        private readonly Action refreshHotkeys;
        private readonly Action<ClipEntry> copyEntry;
        private readonly Action<List<ClipEntry>> copyEntries;
        private readonly Func<List<ClipboardEventSummary>> recentClipboardEvents;
        private readonly Func<List<string>, int> deleteRecentClipboardEvents;
        private readonly Func<int> clearRecentClipboardEvents;
        private readonly Func<int> removeUnavailableRecentClipboardEvents;
        private readonly Func<string, bool> toggleRecentClipboardEventPinned;
        private readonly Action<List<string>, int> moveRecentClipboardEvents;
        private readonly Func<bool> clearTextHistory;
        private readonly Action showPreferences;
        private readonly Action showSecrets;
        private readonly Action toggleActive;
        private readonly Action exitApp;
        private readonly Func<string> diagnosticsText;
        private readonly TabControl tabs;
        private readonly TabPage textTab;
        private readonly TabPage linksTab;
        private readonly TabPage fileTab;
        private readonly ListView list;
        private readonly ListView fileEventsList;
        private readonly ComboBox groupFilter;
        private readonly FlowLayoutPanel filterPanel;
        private MenuStrip menuStrip;
        private readonly StatusStrip status;
        private readonly ToolStripStatusLabel statusText;
        private readonly ContextMenuStrip historyContextMenu;
        private readonly ContextMenuStrip fileEventsContextMenu;
        private ToolStripMenuItem preferencesMenuItem;
        private ToolStripMenuItem optionsMenuItem;
        private ToolStripMenuItem toggleMenuItem;
        private ToolStripMenuItem groupMenuItem;
        private ToolStripMenuItem quickPasteMenuItem;
        private ToolStripMenuItem sortMenuItem;
        private ToolStripMenuItem sortLastUsedMenuItem;
        private ToolStripMenuItem sortAddedMenuItem;
        private ToolStripMenuItem sortTextMenuItem;
        private ToolStripMenuItem sortGroupMenuItem;
        private ToolStripMenuItem sortMachineMenuItem;
        private ToolStripMenuItem sortManualMenuItem;
        private ToolStripMenuItem sortDirectionMenuItem;
        private ToolStripMenuItem groupEntryMenuItem;
        private List<ClipEntry> entries = new List<ClipEntry>();
        private string lastSearch = string.Empty;
        private string typeSearchBuffer = string.Empty;
        private DateTime lastTypeSearchUtc = DateTime.MinValue;
        private string fileTypeSearchBuffer = string.Empty;
        private DateTime lastFileTypeSearchUtc = DateTime.MinValue;
        private bool pendingHistoryFocus;
        private bool updatingGroupFilter;

        public HistoryForm(ClipStore store, AppSettings settings, Action saveSettings, Action refreshHotkeys, Action<ClipEntry> copyEntry, Action<List<ClipEntry>> copyEntries, Func<List<ClipboardEventSummary>> recentClipboardEvents, Func<List<string>, int> deleteRecentClipboardEvents, Func<int> clearRecentClipboardEvents, Func<int> removeUnavailableRecentClipboardEvents, Func<string, bool> toggleRecentClipboardEventPinned, Action<List<string>, int> moveRecentClipboardEvents, Func<bool> clearTextHistory, Action showPreferences, Action showSecrets, Action toggleActive, Action exitApp, Func<string> diagnosticsText)
        {
            this.store = store;
            this.settings = settings;
            this.saveSettings = saveSettings;
            this.refreshHotkeys = refreshHotkeys;
            this.copyEntry = copyEntry;
            this.copyEntries = copyEntries;
            this.recentClipboardEvents = recentClipboardEvents;
            this.deleteRecentClipboardEvents = deleteRecentClipboardEvents;
            this.clearRecentClipboardEvents = clearRecentClipboardEvents;
            this.removeUnavailableRecentClipboardEvents = removeUnavailableRecentClipboardEvents;
            this.toggleRecentClipboardEventPinned = toggleRecentClipboardEventPinned;
            this.moveRecentClipboardEvents = moveRecentClipboardEvents;
            this.clearTextHistory = clearTextHistory;
            this.showPreferences = showPreferences;
            this.showSecrets = showSecrets;
            this.toggleActive = toggleActive;
            this.exitApp = exitApp;
            this.diagnosticsText = diagnosticsText;

            Text = "Clipman";
            StartPosition = FormStartPosition.CenterScreen;
            Width = 900;
            Height = 600;
            KeyPreview = true;

            var menu = BuildMenu();
            MainMenuStrip = menu;
            Controls.Add(menu);

            tabs = new TabControl
            {
                Dock = DockStyle.Fill,
                AccessibleName = "Clipman sections"
            };
            textTab = new TabPage("Text history");
            linksTab = new TabPage("Links history");
            fileTab = new TabPage("File history");

            filterPanel = new FlowLayoutPanel
            {
                Dock = DockStyle.Bottom,
                Height = 34,
                FlowDirection = FlowDirection.LeftToRight,
                Padding = new Padding(8, 5, 0, 0),
                TabIndex = 1
            };
            var groupLabel = new Label
            {
                Text = "&Group:",
                Width = 52,
                Height = 24,
                TextAlign = ContentAlignment.MiddleLeft
            };
            groupFilter = new ComboBox
            {
                Width = 260,
                DropDownStyle = ComboBoxStyle.DropDownList,
                AccessibleName = "Group filter",
                AccessibleDescription = "Choose which clipboard group to show.",
                TabIndex = 0
            };
            groupFilter.KeyDown += (s, e) =>
            {
                if (e.KeyCode != Keys.Enter) return;
                e.Handled = true;
                ApplyGroupFilter();
            };
            groupFilter.Leave += (s, e) => ApplyGroupFilter();
            filterPanel.Controls.Add(groupLabel);
            filterPanel.Controls.Add(groupFilter);
            filterPanel.Controls.Add(CreateCloseButton());

            list = new ListView
            {
                Dock = DockStyle.Fill,
                View = View.Details,
                FullRowSelect = true,
                HideSelection = false,
                MultiSelect = true,
                AccessibleName = "Text history",
                AccessibleDescription = "Text clipboard entries. Press Enter to copy the selected entry to the clipboard.",
                TabIndex = 0
            };
            list.Columns.Add(string.Empty, 730);
            list.Columns.Add("Group", 130);
            list.Columns.Add("Machine", 120);
            list.Columns.Add("Last used", 170);
            list.Columns.Add("Added", 170);
            list.KeyDown += ListKeyDown;
            list.KeyPress += ListKeyPress;
            list.DoubleClick += (s, e) => CopySelected();
            historyContextMenu = BuildContextMenu();
            list.ContextMenuStrip = historyContextMenu;
            textTab.Controls.Add(list);
            textTab.Controls.Add(filterPanel);

            fileEventsList = new ListView
            {
                Dock = DockStyle.Fill,
                View = View.Details,
                FullRowSelect = true,
                HideSelection = false,
                MultiSelect = true,
                AccessibleName = "File history",
                AccessibleDescription = "Recent file and non-text clipboard events. Select one or more events with standard Windows list selection. Press Enter to put selected files back on the clipboard, Shift Enter to pin or unpin, Control Enter to go to one selected file or folder, Delete to remove selected unpinned events, Control Delete to clear normal file history, or Alt Delete to remove unavailable unpinned events."
            };
            fileEventsList.Columns.Add("Event", 420);
            fileEventsList.Columns.Add("Operation", 90);
            fileEventsList.Columns.Add("Files", 70);
            fileEventsList.Columns.Add("Source", 120);
            fileEventsList.Columns.Add("Time", 150);
            fileEventsList.Columns.Add("Pinned", 70);
            fileEventsList.KeyDown += FileEventsListKeyDown;
            fileEventsList.KeyPress += FileEventsListKeyPress;
            fileEventsList.DoubleClick += (s, e) => RestoreSelectedFileClipboardEvent();
            fileEventsContextMenu = BuildFileEventsContextMenu();
            fileEventsList.ContextMenuStrip = fileEventsContextMenu;
            var fileActionsPanel = new FlowLayoutPanel
            {
                Dock = DockStyle.Bottom,
                Height = 34,
                FlowDirection = FlowDirection.LeftToRight,
                Padding = new Padding(8, 5, 0, 0),
                TabIndex = 1
            };
            var clearFileHistoryButton = new ShortcutButton
            {
                Text = "Clear file history",
                ShortcutText = "Ctrl+Del",
                ShortcutKeys = Keys.Control | Keys.Delete,
                Width = 130,
                AccessibleName = "Clear file history",
                AccessibleDescription = "Clears all file-history events. Shortcut Control Delete."
            };
            clearFileHistoryButton.Click += (s, e) => ClearFileClipboardHistory();
            var removeUnavailableButton = new ShortcutButton
            {
                Text = "Remove unavailable",
                ShortcutText = "Alt+Del",
                ShortcutKeys = Keys.Alt | Keys.Delete,
                Width = 160,
                AccessibleName = "Remove unavailable file-history events",
                AccessibleDescription = "Removes file-history events that cannot be restored, including non-file clipboard events and events where all referenced files or folders are missing. Shortcut Alt Delete."
            };
            removeUnavailableButton.Click += (s, e) => RemoveUnavailableFileClipboardEvents();
            fileActionsPanel.Controls.Add(clearFileHistoryButton);
            fileActionsPanel.Controls.Add(removeUnavailableButton);
            fileActionsPanel.Controls.Add(CreateCloseButton());
            fileTab.Controls.Add(fileEventsList);
            fileTab.Controls.Add(fileActionsPanel);

            RebuildHistoryTabs();
            tabs.SelectedIndexChanged += (s, e) =>
            {
                var keepTabControlFocus = tabs.Focused;
                AttachTextControlsToActiveTextTab();
                SaveSelectedTab();
                UpdateMenuHotkeys();
                Reload();
                if (keepTabControlFocus)
                {
                    FocusHistoryTabControlNow();
                }
            };
            Controls.Add(tabs);

            statusText = new ToolStripStatusLabel("Ready");
            status = new StatusStrip();
            status.Items.Add(statusText);
            Controls.Add(status);

            RefreshGroupFilterItems();
            RefreshFileClipboardEvents();
            Reload();
        }

        private ShortcutButton CreateCloseButton()
        {
            var closeButton = new ShortcutButton
            {
                Text = "Close",
                ShortcutText = "Esc",
                ShortcutKeys = Keys.Escape,
                Width = 80,
                AccessibleName = "Close",
                AccessibleDescription = "Closes the history window. Shortcut Escape."
            };
            closeButton.Click += (s, e) => CloseHistoryWindow();
            return closeButton;
        }

        public void Reload()
        {
            Reload(null, -1);
        }

        public void RefreshFileClipboardEvents()
        {
            RefreshFileClipboardEvents(-1);
        }

        private void RefreshFileClipboardEvents(int preferredIndex)
        {
            if (fileEventsList == null) return;
            var events = recentClipboardEvents == null ? new List<ClipboardEventSummary>() : recentClipboardEvents() ?? new List<ClipboardEventSummary>();
            var selectedIndex = preferredIndex >= 0
                ? preferredIndex
                : fileEventsList.SelectedIndices.Count > 0 ? fileEventsList.SelectedIndices[0] : -1;
            fileEventsList.BeginUpdate();
            fileEventsList.Items.Clear();
            var insertedSeparator = false;
            var pinnedEventPosition = 0;
            foreach (var item in events)
            {
                if (!item.Pinned && !insertedSeparator && events.Any(e => e.Pinned))
                {
                    var separator = new ListViewItem("----- Normal entries -----");
                    separator.SubItems.Add(string.Empty);
                    separator.SubItems.Add(string.Empty);
                    separator.SubItems.Add(string.Empty);
                    separator.SubItems.Add(string.Empty);
                    separator.SubItems.Add(string.Empty);
                    separator.Tag = null;
                    separator.ForeColor = SystemColors.GrayText;
                    fileEventsList.Items.Add(separator);
                    insertedSeparator = true;
                }

                NormalizeFileClipboardEvent(item);
                var text = item.Pinned ? NumberedPinnedDisplayText(FileEventDisplayText(item), pinnedEventPosition++) : FileEventDisplayText(item);
                var row = new ListViewItem(text);
                row.SubItems.Add(NormalizeDropEffectText(item.Operation));
                row.SubItems.Add(item.FileCount > 0 ? item.FileCount.ToString() : string.Empty);
                row.SubItems.Add(item.Source ?? string.Empty);
                row.SubItems.Add(item.CapturedAt.ToString("yyyy-MM-dd HH:mm:ss"));
                row.SubItems.Add(item.Pinned ? "Pinned" : string.Empty);
                row.Tag = item;
                fileEventsList.Items.Add(row);
            }
            fileEventsList.EndUpdate();
            if (fileEventsList.Items.Count > 0)
            {
                if (selectedIndex < 0) selectedIndex = 0;
                if (selectedIndex >= fileEventsList.Items.Count) selectedIndex = fileEventsList.Items.Count - 1;
                selectedIndex = NormalizeFileSelectableIndex(selectedIndex);
                if (selectedIndex < 0) return;
                fileEventsList.Items[selectedIndex].Selected = true;
                fileEventsList.Items[selectedIndex].Focused = true;
                fileEventsList.Items[selectedIndex].EnsureVisible();
            }
        }

        private void Reload(string preferredSelectedId, int preferredIndex)
        {
            UpdateMenuHotkeys();
            RefreshGroupFilterItems();
            RefreshFileClipboardEvents();
            var selectedEntry = SelectedEntry();
            var selectedId = !string.IsNullOrEmpty(preferredSelectedId)
                ? preferredSelectedId
                : selectedEntry == null ? null : selectedEntry.Id;
            entries = TextEntriesForActiveTab(store.GetEntries(settings.SortMode, settings.GroupFilter, settings.SortDescending));
            list.BeginUpdate();
            list.Items.Clear();
            var insertedSeparator = false;
            var pinnedEntryPosition = 0;
            foreach (var entry in entries)
            {
                if (!entry.Pinned && !insertedSeparator && entries.Any(e => e.Pinned))
                {
                    var separator = new ListViewItem("----- Normal entries -----");
                    separator.SubItems.Add(string.Empty);
                    separator.SubItems.Add(string.Empty);
                    separator.SubItems.Add(string.Empty);
                    separator.SubItems.Add(string.Empty);
                    separator.Tag = null;
                    separator.ForeColor = SystemColors.GrayText;
                    list.Items.Add(separator);
                    insertedSeparator = true;
                }

                var item = new ListViewItem(EntryDisplayText(entry, ref pinnedEntryPosition));
                item.SubItems.Add(entry.Group ?? string.Empty);
                item.SubItems.Add(entry.SourceMachine ?? string.Empty);
                item.SubItems.Add(TimeUtil.FromUnixMs(entry.LastUsedUnixMs).ToString("yyyy-MM-dd HH:mm:ss"));
                item.SubItems.Add(TimeUtil.FromUnixMs(entry.CreatedUnixMs).ToString("yyyy-MM-dd HH:mm:ss"));
                item.Tag = entry;
                list.Items.Add(item);
            }
            list.EndUpdate();

            var index = -1;
            if (!string.IsNullOrEmpty(selectedId))
            {
                index = FindListIndexByEntryId(selectedId);
            }
            if (index < 0 && settings.SaveListPosition)
            {
                index = preferredIndex >= 0 ? preferredIndex : settings.LastSelectedIndex;
            }
            if (index < 0 && preferredIndex >= 0) index = preferredIndex;
            if (list.Items.Count == 0)
            {
                statusText.Text = entries.Count + TextHistoryStatusSuffix();
                return;
            }
            if (index >= list.Items.Count)
            {
                index = list.Items.Count - 1;
            }
            if (index < 0)
            {
                index = DefaultHistoryIndex();
            }
            index = NormalizeSelectableIndex(index);
            SelectIndex(index);
            statusText.Text = entries.Count + TextHistoryStatusSuffix();
        }

        public void RefreshTabsAndReload()
        {
            var selectedTab = CurrentHistoryTab();
            RebuildHistoryTabs();
            SelectHistoryTab(HistoryTabs.Normalize(selectedTab, settings.LinksHistoryEnabled), false);
            Reload();
        }

        private List<ClipEntry> TextEntriesForActiveTab(List<ClipEntry> source)
        {
            if (source == null) return new List<ClipEntry>();
            if (!settings.LinksHistoryEnabled) return source;
            var showingLinks = IsLinksHistoryTabActive();
            return source.Where(e => LinkClassifier.IsLinkOnlyText(e == null ? null : e.Text) == showingLinks).ToList();
        }

        private string TextHistoryStatusSuffix()
        {
            return IsLinksHistoryTabActive() ? " link entries." : " clipboard entries.";
        }

        public void FocusHistoryList()
        {
            FocusHistoryList(false);
        }

        public void FocusHistoryList(bool firstShow)
        {
            if (pendingHistoryFocus) return;
            pendingHistoryFocus = true;
            BeginInvoke(new Action(() =>
            {
                pendingHistoryFocus = false;
                if (!Visible) return;
                ResetListPositionIfDisabled();
                FocusActiveTabNow();
            }));
        }

        private void ResetListPositionIfDisabled()
        {
            if (settings.SaveListPosition) return;
            if (IsFileClipboardTabActive()) return;
            SelectDefaultHistoryIndex();
        }

        private MenuStrip BuildMenu()
        {
            var menu = new MenuStrip();
            menuStrip = menu;
            menu.MenuActivate += (s, e) => UpdateMenuHotkeys();
            menu.MenuDeactivate += (s, e) => BeginDelayedFocus(80);

            var file = new ToolStripMenuItem("&File");
            file.DropDownItems.Add("&Import...\tCtrl+I", null, (s, e) => Import(false));
            file.DropDownItems.Add("Import and &replace...", null, (s, e) => Import(true));
            file.DropDownItems.Add("&Export...\tCtrl+E", null, (s, e) => Export());
            file.DropDownItems.Add("-");
            file.DropDownItems.Add("Clear text &history...", null, (s, e) => ClearTextClipboardHistory());
            file.DropDownItems.Add("-");
            file.DropDownItems.Add("&Close\tEsc", null, (s, e) => CloseHistoryWindow());
            file.DropDownItems.Add("E&xit", null, (s, e) => exitApp());

            var edit = new ToolStripMenuItem("&Edit");
            edit.DropDownOpening += (s, e) => PopulateEditMenu(edit);
            PopulateEditMenu(edit);

            var actions = new ToolStripMenuItem("&Actions");
            actions.DropDownItems.Add("Copy as plain &text\tCtrl+Shift+C", null, (s, e) => CopySelectedPlainText(false));
            actions.DropDownItems.Add("T&rim leading and trailing whitespace\tCtrl+Shift+T", null, (s, e) => TransformSelected(TrimText, "Trimmed selected entry or entries."));
            actions.DropDownItems.Add("Convert to &single line\tCtrl+Shift+L", null, (s, e) => TransformSelected(SingleLineText, "Converted selected entry or entries to single line."));
            actions.DropDownItems.Add("Remove &blank lines\tCtrl+Shift+B", null, (s, e) => TransformSelected(RemoveBlankLines, "Removed blank lines from selected entry or entries."));
            actions.DropDownItems.Add("Remove URL trac&king\tCtrl+Shift+R", null, (s, e) => TransformSelected(UrlTrackingCleaner.CleanText, "Removed URL tracking from selected entry or entries."));
            actions.DropDownItems.Add("Clean link for sharin&g\tCtrl+Shift+S", null, (s, e) => TransformSelected(UrlTrackingCleaner.CleanForSharing, "Cleaned selected link or links for sharing."));
            var lineEndings = new ToolStripMenuItem("Line &endings");
            lineEndings.DropDownItems.Add("Convert to Windows &CRLF", null, (s, e) => TransformSelected(LineEndingNormalizer.ToWindows, "Converted selected entry or entries to Windows CRLF line endings."));
            lineEndings.DropDownItems.Add("Convert to Unix &LF", null, (s, e) => TransformSelected(LineEndingNormalizer.ToUnix, "Converted selected entry or entries to Unix LF line endings."));
            lineEndings.DropDownItems.Add("Convert to old Mac C&R", null, (s, e) => TransformSelected(LineEndingNormalizer.ToOldMac, "Converted selected entry or entries to old Mac CR line endings."));
            actions.DropDownItems.Add(lineEndings);
            actions.DropDownItems.Add("&Uppercase", null, (s, e) => TransformSelected(t => (t ?? string.Empty).ToUpperInvariant(), "Uppercased selected entry or entries."));
            actions.DropDownItems.Add("&Lowercase", null, (s, e) => TransformSelected(t => (t ?? string.Empty).ToLowerInvariant(), "Lowercased selected entry or entries."));
            actions.DropDownItems.Add("HTML enc&ode", null, (s, e) => TransformSelected(System.Net.WebUtility.HtmlEncode, "HTML-encoded selected entry or entries."));
            actions.DropDownItems.Add("&HTML decode", null, (s, e) => TransformSelected(System.Net.WebUtility.HtmlDecode, "HTML-decoded selected entry or entries."));
            actions.DropDownItems.Add("HTML to readable te&xt\tCtrl+Shift+H", null, (s, e) => TransformSelected(HtmlToText, "Converted selected HTML entry or entries to readable text."));
            actions.DropDownItems.Add("URL e&ncode\tCtrl+Shift+U", null, (s, e) => TransformSelected(UrlEncode, "URL-encoded selected entry or entries."));
            actions.DropDownItems.Add("URL &decode", null, (s, e) => TransformSelected(Uri.UnescapeDataString, "URL-decoded selected entry or entries."));
            actions.DropDownOpening += (s, e) => SetMenuItemsEnabled(actions, !IsFileClipboardTabActive());

            groupMenuItem = new ToolStripMenuItem("Grou&ps");
            groupMenuItem.DropDownOpening += (s, e) => PopulateGroupMenu();
            PopulateGroupMenu();

            quickPasteMenuItem = new ToolStripMenuItem("&Quick Paste");
            quickPasteMenuItem.DropDownOpening += (s, e) => PopulateQuickPasteMenu();
            PopulateQuickPasteMenu();

            var options = new ToolStripMenuItem("&Options");
            optionsMenuItem = options;
            preferencesMenuItem = new ToolStripMenuItem("&Preferences...\tCtrl+,", null, (s, e) => showPreferences());
            toggleMenuItem = new ToolStripMenuItem("&Toggle on/off", null, (s, e) => toggleActive());
            options.DropDownItems.Add(preferencesMenuItem);
            options.DropDownItems.Add("Se&crets...\tCtrl+Shift+E", null, (s, e) => showSecrets());
            options.DropDownItems.Add("Open &settings folder", null, (s, e) => OpenSettingsFolder());
            options.DropDownItems.Add(toggleMenuItem);

            var view = new ToolStripMenuItem("&View");
            sortMenuItem = new ToolStripMenuItem("S&ort by");
            sortMenuItem.DropDownOpening += (s, e) => UpdateMenuHotkeys();
            sortLastUsedMenuItem = new ToolStripMenuItem("&Last used", null, (s, e) => SetSortMode("LastUsed"));
            sortAddedMenuItem = new ToolStripMenuItem("&Added", null, (s, e) => SetSortMode("Added"));
            sortTextMenuItem = new ToolStripMenuItem("&Text", null, (s, e) => SetSortMode("Text"));
            sortGroupMenuItem = new ToolStripMenuItem("&Group", null, (s, e) => SetSortMode("Group"));
            sortMachineMenuItem = new ToolStripMenuItem("Mac&hine", null, (s, e) => SetSortMode("Machine"));
            sortManualMenuItem = new ToolStripMenuItem("&Manual order", null, (s, e) => SetSortMode("Manual"));
            sortDirectionMenuItem = new ToolStripMenuItem("", null, (s, e) => ToggleSortDirection());
            view.DropDownItems.Add("Text history\tAlt+T", null, (s, e) => SelectMainTab());
            view.DropDownItems.Add("Links history\tAlt+L", null, (s, e) => SelectLinksTab());
            view.DropDownItems.Add("File history\tAlt+I", null, (s, e) => SelectFileClipboardTab());
            view.DropDownItems.Add("-");
            view.DropDownItems.Add(sortDirectionMenuItem);
            view.DropDownItems.Add("-");
            sortMenuItem.DropDownItems.Add(sortLastUsedMenuItem);
            sortMenuItem.DropDownItems.Add(sortAddedMenuItem);
            sortMenuItem.DropDownItems.Add(sortTextMenuItem);
            sortMenuItem.DropDownItems.Add(sortGroupMenuItem);
            sortMenuItem.DropDownItems.Add(sortMachineMenuItem);
            sortMenuItem.DropDownItems.Add(sortManualMenuItem);
            view.DropDownItems.Add(sortMenuItem);
            view.DropDownItems.Add("Move &up\tAlt+Up", null, (s, e) => MoveSelectedActiveTab(-1));
            view.DropDownItems.Add("Move &down\tAlt+Down", null, (s, e) => MoveSelectedActiveTab(1));
            view.DropDownOpening += (s, e) => UpdateMenuHotkeys();

            var help = new ToolStripMenuItem("&Help");
            help.DropDownItems.Add("&Manual\tF1", null, (s, e) => OpenManual());
            help.DropDownItems.Add("&Check for updates...\tShift+F1", null, (s, e) => UpdateService.CheckForUpdates(this, AppVersion(), exitApp));
            help.DropDownItems.Add("&Version history", null, (s, e) => UpdateService.ShowVersionHistory(this, AppVersion()));
            help.DropDownItems.Add("&Project page\tCtrl+F1", null, (s, e) => UpdateService.OpenProjectPage());
            help.DropDownItems.Add("Con&tact", null, (s, e) => UpdateService.OpenContactPage());
            help.DropDownItems.Add("&Donate", null, (s, e) => UpdateService.OpenDonatePage());
            help.DropDownItems.Add("Dia&gnostics\tAlt+F1", null, (s, e) => ShowDiagnostics());
            help.DropDownItems.Add("&About Clipman", null, (s, e) => ShowAbout());

            menu.Items.Add(file);
            menu.Items.Add(edit);
            menu.Items.Add(groupMenuItem);
            menu.Items.Add(quickPasteMenuItem);
            menu.Items.Add(actions);
            menu.Items.Add(view);
            menu.Items.Add(options);
            menu.Items.Add(help);
            UpdateMenuHotkeys();
            return menu;
        }

        private void PopulateQuickPasteMenu()
        {
            if (quickPasteMenuItem == null) return;
            quickPasteMenuItem.DropDownItems.Clear();
            quickPasteMenuItem.Enabled = !IsFileClipboardTabActive();

            var targets = QuickPasteTargets().ToList();
            if (targets.Count == 0)
            {
                var none = new ToolStripMenuItem("No Quick Paste targets assigned");
                none.Enabled = false;
                quickPasteMenuItem.DropDownItems.Add(none);
                return;
            }

            foreach (var target in targets)
            {
                var item = new ToolStripMenuItem(QuickPasteTargetMenuText(target.Entry, target.Hotkey, target.Mode), null, (s, e) =>
                {
                    var selected = ((ToolStripMenuItem)s).Tag as ClipEntry;
                    FocusEntry(selected);
                })
                {
                    Tag = target.Entry
                };
                quickPasteMenuItem.DropDownItems.Add(item);
            }
        }

        private void PopulateGroupMenu()
        {
            if (groupMenuItem == null) return;
            groupMenuItem.DropDownItems.Clear();
            groupMenuItem.Enabled = !IsFileClipboardTabActive();

            var groups = GroupFilterItems();
            var reservedCount = 4;
            for (var index = 0; index < groups.Count; index++)
            {
                if (index == reservedCount)
                {
                    groupMenuItem.DropDownItems.Add("-");
                }

                var group = groups[index];
                var label = GroupFilterMenuText(group, index);
                var item = new ToolStripMenuItem(label, null, (s, e) =>
                {
                    var selected = Convert.ToString(((ToolStripMenuItem)s).Tag);
                    SetGroupFilter(selected);
                })
                {
                    Tag = group,
                    Checked = string.Equals(CurrentGroupFilter(), group, StringComparison.CurrentCultureIgnoreCase)
                };
                groupMenuItem.DropDownItems.Add(item);
            }
        }

        private static string GroupFilterMenuText(string group, int index)
        {
            if (index < 0 || index > 9)
            {
                return group ?? string.Empty;
            }

            var shortcutNumber = index == 9 ? "0" : (index + 1).ToString(CultureInfo.InvariantCulture);
            return "&" + shortcutNumber + " " + (group ?? string.Empty) + "\tAlt+" + shortcutNumber;
        }

        private IEnumerable<QuickPasteTarget> QuickPasteTargets()
        {
            if (settings.QuickCopyHotkeys == null || settings.QuickCopyHotkeys.Count == 0)
            {
                return Enumerable.Empty<QuickPasteTarget>();
            }

            var allEntries = store.GetEntries("Manual", "All", false)
                .ToDictionary(e => e.Id ?? string.Empty, StringComparer.OrdinalIgnoreCase);

            return settings.QuickCopyHotkeys
                .Where(b => b != null && !string.IsNullOrWhiteSpace(b.EntryId) && !string.IsNullOrWhiteSpace(b.Hotkey))
                .Select(b =>
                {
                    ClipEntry entry;
                    return allEntries.TryGetValue(b.EntryId.Trim(), out entry)
                        && entry != null
                        && !string.IsNullOrEmpty(entry.Text)
                        ? new QuickPasteTarget(entry, b.Hotkey.Trim(), QuickPasteModes.Normalize(b.Mode))
                        : null;
                })
                .Where(t => t != null)
                .OrderBy(t => t.Hotkey, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(t => DisplayText(t.Entry), StringComparer.CurrentCultureIgnoreCase);
        }

        private void FocusEntry(ClipEntry entry)
        {
            if (entry == null || string.IsNullOrWhiteSpace(entry.Id)) return;
            if (settings.LinksHistoryEnabled && LinkClassifier.IsLinkOnlyText(entry.Text))
            {
                SelectLinksTab();
            }
            else
            {
                SelectMainTab();
            }
            if (FindListIndexByEntryId(entry.Id) < 0 && !string.Equals(CurrentGroupFilter(), "All", StringComparison.CurrentCultureIgnoreCase))
            {
                settings.GroupFilter = "All";
                saveSettings();
                RefreshGroupFilterItems();
            }
            Reload(entry.Id, -1);
            FocusHistoryList();
            statusText.Text = "Selected Quick Paste target. Press F2 to edit or remove the Quick Paste hotkey.";
        }

        private string QuickPasteDisplayText(string entryId)
        {
            var binding = QuickCopyBindingForEntry(entryId);
            if (binding == null || string.IsNullOrWhiteSpace(binding.Hotkey)) return string.Empty;
            return "Quick Paste " + binding.Hotkey.Trim() + ", " + QuickPasteModeDisplayText(binding.Mode);
        }

        private string EntryDisplayText(ClipEntry entry, ref int pinnedEntryPosition)
        {
            var text = entry.Pinned ? NumberedPinnedDisplayText(DisplayText(entry), pinnedEntryPosition++) : DisplayText(entry);
            var quickPaste = QuickPasteDisplayText(entry.Id);
            if (entry.IsTemplate)
            {
                text = "Template; " + text;
            }
            return string.IsNullOrWhiteSpace(quickPaste) ? text : quickPaste + "; " + text;
        }

        private static string QuickPasteTargetMenuText(ClipEntry entry, string hotkey, string mode)
        {
            var text = DisplayText(entry);
            if (text.Length > 60)
            {
                text = text.Substring(0, 57) + "...";
            }
            return (hotkey ?? string.Empty).Trim() + ", " + QuickPasteModeDisplayText(mode) + ": " + text;
        }

        private sealed class QuickPasteTarget
        {
            public QuickPasteTarget(ClipEntry entry, string hotkey, string mode)
            {
                Entry = entry;
                Hotkey = hotkey ?? string.Empty;
                Mode = QuickPasteModes.Normalize(mode);
            }

            public ClipEntry Entry { get; private set; }
            public string Hotkey { get; private set; }
            public string Mode { get; private set; }
        }

        private ContextMenuStrip BuildContextMenu()
        {
            var menu = new ContextMenuStrip();
            menu.Opening += (s, e) =>
            {
                PopulateContextMenu(menu);
            };
            PopulateContextMenu(menu);
            return menu;
        }

        private void PopulateEditMenu(ToolStripMenuItem edit)
        {
            edit.DropDownItems.Clear();
            if (IsFileClipboardTabActive())
            {
                var items = SelectedFileClipboardEvents();
                var item = items.Count == 1 ? items[0] : null;
                var hasFiles = items.Any(HasRestorableFilePaths);
                var restore = edit.DropDownItems.Add("&Restore files to clipboard\tEnter", null, (s, e) => RestoreSelectedFileClipboardEvents());
                restore.Enabled = hasFiles;
                var copyPaths = edit.DropDownItems.Add("&Copy file paths\tCtrl+C", null, (s, e) => CopySelectedFileClipboardPaths());
                copyPaths.Enabled = hasFiles;
                var pin = edit.DropDownItems.Add(FilePinMenuText(), null, (s, e) => ToggleSelectedFileClipboardEventPinned());
                pin.Enabled = items.Count > 0;
                var goToFile = edit.DropDownItems.Add("&Go to file\tCtrl+Enter", null, (s, e) => GoToSelectedFileClipboardEvent());
                goToFile.Enabled = item != null && item.Files != null && item.Files.Count == 1;
                var details = edit.DropDownItems.Add("&View event details\tF4", null, (s, e) => ViewSelectedFileClipboardEvent());
                details.Enabled = item != null;
                var delete = edit.DropDownItems.Add("&Delete selected\tDel", null, (s, e) => DeleteSelectedFileClipboardEvent());
                delete.Enabled = item != null;
                edit.DropDownItems.Add("-");
                edit.DropDownItems.Add("Remove &unavailable events\tAlt+Del", null, (s, e) => RemoveUnavailableFileClipboardEvents());
                edit.DropDownItems.Add("C&lear file history...\tCtrl+Del", null, (s, e) => ClearFileClipboardHistory());
                return;
            }

            edit.DropDownItems.Add("Copy and c&lose\tEnter", null, (s, e) => CopySelected());
            edit.DropDownItems.Add("&Copy\tCtrl+C", null, (s, e) => CopySelected(false));
            edit.DropDownItems.Add("Cu&t\tCtrl+X", null, (s, e) => CutSelected());
            edit.DropDownItems.Add("Paste &after selected\tCtrl+V", null, (s, e) => PasteAfterSelected());
            groupEntryMenuItem = new ToolStripMenuItem("&Group entry...\tCtrl+G", null, (s, e) => GroupSelectedEntries());
            edit.DropDownItems.Add(groupEntryMenuItem);
            edit.DropDownItems.Add("Entry &properties...\tF2", null, (s, e) => ShowEntryProperties());
            edit.DropDownItems.Add("Set as &quick-paste target...", null, (s, e) => ShowEntryProperties(true));
            edit.DropDownItems.Add("Push to other &machines\tCtrl+P", null, (s, e) => PushSelectedToOtherMachines());
            edit.DropDownItems.Add("&View full text\tF4", null, (s, e) => ViewSelectedText());
            edit.DropDownItems.Add("Pin or unp&in\tShift+Enter", null, (s, e) => TogglePinned());
            edit.DropDownItems.Add("&Delete selected\tDel", null, (s, e) => DeleteSelected());
            edit.DropDownItems.Add("&Find...\tCtrl+F", null, (s, e) => ShowSearchDialog(false));
            edit.DropDownItems.Add("Find &next\tF3", null, (s, e) => RepeatSearch(false));
            edit.DropDownItems.Add("Find previou&s\tShift+F3", null, (s, e) => RepeatSearch(true));
        }

        private static void SetMenuItemsEnabled(ToolStripMenuItem menu, bool enabled)
        {
            foreach (ToolStripItem item in menu.DropDownItems)
            {
                if (item is ToolStripSeparator) continue;
                item.Enabled = enabled;
            }
        }

        private ContextMenuStrip BuildFileEventsContextMenu()
        {
            var menu = new ContextMenuStrip();
            menu.Opening += (s, e) => PopulateFileEventsContextMenu(menu);
            PopulateFileEventsContextMenu(menu);
            return menu;
        }

        private void PopulateContextMenu(ContextMenuStrip menu)
        {
            menu.Items.Clear();
            menu.Items.Add("Copy and c&lose\tEnter", null, (sender, args) => CopySelected());
            menu.Items.Add("&Copy\tCtrl+C", null, (sender, args) => CopySelected(false));
            menu.Items.Add("Cu&t\tCtrl+X", null, (sender, args) => CutSelected());
            menu.Items.Add("Paste &after selected\tCtrl+V", null, (sender, args) => PasteAfterSelected());
            menu.Items.Add("&Group entry...\tCtrl+G", null, (sender, args) => GroupSelectedEntries());
            menu.Items.Add("Entry &properties...\tF2", null, (sender, args) => ShowEntryProperties());
            menu.Items.Add("Set as &quick-paste target...", null, (sender, args) => ShowEntryProperties(true));
            menu.Items.Add("Push to other &machines\tCtrl+P", null, (sender, args) => PushSelectedToOtherMachines());
            menu.Items.Add("&View full text\tF4", null, (sender, args) => ViewSelectedText());
            menu.Items.Add(PinMenuText(), null, (sender, args) => TogglePinned());
            var pinnedShortcutPosition = SelectedPinnedEntryShortcutPosition();
            if (pinnedShortcutPosition >= 0)
            {
                menu.Items.Add(
                    "Copy pinned entry " + ShortcutDisplayNumber(pinnedShortcutPosition) + "\t" + PinnedShortcutText(pinnedShortcutPosition, false),
                    null,
                    (sender, args) => CopyPinnedByPosition(pinnedShortcutPosition));
            }
            menu.Items.Add("&Delete selected\tDel", null, (sender, args) => DeleteSelected());
            menu.Items.Add("&Find...\tCtrl+F", null, (sender, args) => ShowSearchDialog(false));
            menu.Items.Add("Find &next\tF3", null, (sender, args) => RepeatSearch(false));
            menu.Items.Add("Find previou&s\tShift+F3", null, (sender, args) => RepeatSearch(true));
        }

        private void PopulateFileEventsContextMenu(ContextMenuStrip menu)
        {
            var items = SelectedFileClipboardEvents();
            var item = items.Count == 1 ? items[0] : null;
            var hasFiles = items.Any(HasRestorableFilePaths);

            menu.Items.Clear();
            var restore = menu.Items.Add("&Restore files to clipboard\tEnter", null, (sender, args) => RestoreSelectedFileClipboardEvents());
            restore.Enabled = hasFiles;
            var copyPaths = menu.Items.Add("&Copy file paths\tCtrl+C", null, (sender, args) => CopySelectedFileClipboardPaths());
            copyPaths.Enabled = hasFiles;
            var pin = menu.Items.Add(FilePinMenuText(), null, (sender, args) => ToggleSelectedFileClipboardEventPinned());
            pin.Enabled = items.Count > 0;
            var pinnedShortcutPosition = SelectedPinnedFileEventShortcutPosition();
            if (pinnedShortcutPosition >= 0)
            {
                var restorePinned = menu.Items.Add(
                    "Restore pinned file event " + ShortcutDisplayNumber(pinnedShortcutPosition) + "\t" + PinnedShortcutText(pinnedShortcutPosition, false),
                    null,
                    (sender, args) => RestorePinnedFileClipboardEventByPosition(pinnedShortcutPosition));
                restorePinned.Enabled = hasFiles;
                var copyPinnedPaths = menu.Items.Add(
                    "Copy pinned file paths " + ShortcutDisplayNumber(pinnedShortcutPosition) + "\t" + PinnedShortcutText(pinnedShortcutPosition, true),
                    null,
                    (sender, args) => CopyPinnedFileClipboardEventPathsByPosition(pinnedShortcutPosition));
                copyPinnedPaths.Enabled = hasFiles;
            }
            var goToFile = menu.Items.Add("&Go to file\tCtrl+Enter", null, (sender, args) => GoToSelectedFileClipboardEvent());
            goToFile.Enabled = item != null && item.Files != null && item.Files.Count == 1;
            var details = menu.Items.Add("&View event details\tF4", null, (sender, args) => ViewSelectedFileClipboardEvent());
            details.Enabled = item != null;
            var delete = menu.Items.Add("&Delete selected\tDel", null, (sender, args) => DeleteSelectedFileClipboardEvent());
            delete.Enabled = item != null;
            menu.Items.Add("-");
            menu.Items.Add("Remove &unavailable events\tAlt+Del", null, (sender, args) => RemoveUnavailableFileClipboardEvents());
            menu.Items.Add("C&lear file history...\tCtrl+Del", null, (sender, args) => ClearFileClipboardHistory());
        }

        private int SelectedPinnedEntryShortcutPosition()
        {
            var selected = SelectedEntries();
            if (selected.Count != 1 || !selected[0].Pinned) return -1;

            var pinnedEntries = store.GetEntries(settings.SortMode, "Pinned", settings.SortDescending);
            for (var i = 0; i < pinnedEntries.Count && i < 10; i++)
            {
                if (string.Equals(pinnedEntries[i].Id, selected[0].Id, StringComparison.Ordinal))
                {
                    return i;
                }
            }

            return -1;
        }

        private int SelectedPinnedFileEventShortcutPosition()
        {
            var selected = SelectedFileClipboardEvents();
            if (selected.Count != 1 || !selected[0].Pinned) return -1;

            var pinnedEvents = recentClipboardEvents == null
                ? new List<ClipboardEventSummary>()
                : (recentClipboardEvents() ?? new List<ClipboardEventSummary>()).Where(e => e.Pinned).ToList();
            for (var i = 0; i < pinnedEvents.Count && i < 10; i++)
            {
                if (string.Equals(pinnedEvents[i].Id, selected[0].Id, StringComparison.Ordinal))
                {
                    return i;
                }
            }

            return -1;
        }

        private static string ShortcutDisplayNumber(int zeroBasedPosition)
        {
            return zeroBasedPosition == 9 ? "10" : (zeroBasedPosition + 1).ToString(CultureInfo.InvariantCulture);
        }

        private static string PinnedShortcutText(int zeroBasedPosition, bool shift)
        {
            var key = zeroBasedPosition == 9 ? "0" : (zeroBasedPosition + 1).ToString(CultureInfo.InvariantCulture);
            return shift ? "Ctrl+Shift+" + key : "Ctrl+" + key;
        }

        private void ListKeyDown(object sender, KeyEventArgs e)
        {
            if (e.Alt && e.KeyCode == Keys.Enter)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                statusText.Text = "Use F2 for Entry Properties.";
            }
            else if (e.KeyCode == Keys.Enter)
            {
                e.Handled = true;
                if (e.Shift)
                {
                    TogglePinned();
                }
                else
                {
                    CopySelected(!e.Control);
                }
            }
            else if (e.KeyCode == Keys.Delete)
            {
                e.Handled = true;
                DeleteSelected();
            }
            else if (e.Control && e.Shift && e.KeyCode == Keys.C)
            {
                e.Handled = true;
                CopySelectedPlainText(false);
            }
            else if (e.Control && e.Shift && e.KeyCode == Keys.T)
            {
                e.Handled = true;
                TransformSelected(TrimText, "Trimmed selected entry or entries.");
            }
            else if (e.Control && e.Shift && e.KeyCode == Keys.L)
            {
                e.Handled = true;
                TransformSelected(SingleLineText, "Converted selected entry or entries to single line.");
            }
            else if (e.Control && e.Shift && e.KeyCode == Keys.B)
            {
                e.Handled = true;
                TransformSelected(RemoveBlankLines, "Removed blank lines from selected entry or entries.");
            }
            else if (e.Control && e.Shift && e.KeyCode == Keys.R)
            {
                e.Handled = true;
                TransformSelected(UrlTrackingCleaner.CleanText, "Removed URL tracking from selected entry or entries.");
            }
            else if (e.Control && e.Shift && e.KeyCode == Keys.S)
            {
                e.Handled = true;
                TransformSelected(UrlTrackingCleaner.CleanForSharing, "Cleaned selected link or links for sharing.");
            }
            else if (e.Control && e.Shift && e.KeyCode == Keys.H)
            {
                e.Handled = true;
                TransformSelected(HtmlToText, "Converted selected HTML entry or entries to readable text.");
            }
            else if (e.Control && e.Shift && e.KeyCode == Keys.U)
            {
                e.Handled = true;
                TransformSelected(UrlEncode, "URL-encoded selected entry or entries.");
            }
            else if (e.Control && e.KeyCode == Keys.C)
            {
                e.Handled = true;
                CopySelected(false);
            }
            else if (e.Control && e.KeyCode == Keys.X)
            {
                e.Handled = true;
                CutSelected();
            }
            else if (e.Control && e.KeyCode == Keys.V)
            {
                e.Handled = true;
                PasteAfterSelected();
            }
            else if (e.Control && e.KeyCode == Keys.P)
            {
                e.Handled = true;
                PushSelectedToOtherMachines();
            }
            else if (e.KeyCode == Keys.Back)
            {
                e.Handled = true;
                JumpToNormalEntries();
            }
            else if (e.Alt && e.KeyCode == Keys.Up)
            {
                e.Handled = true;
                MoveSelected(-1);
            }
            else if (e.Alt && e.KeyCode == Keys.Down)
            {
                e.Handled = true;
                MoveSelected(1);
            }
            else if (e.KeyCode == Keys.F3)
            {
                e.Handled = true;
                RepeatSearch(e.Shift);
            }
            else if (e.Control && e.KeyCode == Keys.F)
            {
                e.Handled = true;
                ShowSearchDialog(false);
            }
            else if (e.KeyCode == Keys.F2)
            {
                e.Handled = true;
                ShowEntryProperties();
            }
            else if (e.Modifiers == Keys.None && e.KeyCode == Keys.F4)
            {
                e.Handled = true;
                ViewSelectedText();
            }
            else if (e.Control && e.KeyCode == Keys.G)
            {
                e.Handled = true;
                GroupSelectedEntries();
            }
            else if (e.Control && e.KeyCode >= Keys.D1 && e.KeyCode <= Keys.D9)
            {
                e.Handled = true;
                CopyPinnedByPosition(e.KeyCode - Keys.D1);
            }
            else if (e.Control && e.KeyCode == Keys.D0)
            {
                e.Handled = true;
                CopyPinnedByPosition(9);
            }
            else if (e.Alt && e.KeyCode >= Keys.D1 && e.KeyCode <= Keys.D9)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                JumpToGroupByPosition(e.KeyCode - Keys.D1);
            }
            else if (e.Alt && e.KeyCode == Keys.D0)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                JumpToGroupByPosition(9);
            }
            else if (e.Shift && e.KeyCode == Keys.F1)
            {
                e.Handled = true;
                UpdateService.CheckForUpdates(this, AppVersion(), exitApp);
            }
            else if (e.Control && e.KeyCode == Keys.F1)
            {
                e.Handled = true;
                UpdateService.OpenProjectPage();
            }
            else if (e.Alt && e.KeyCode == Keys.F1)
            {
                e.Handled = true;
                ShowDiagnostics();
            }
            else if (e.KeyCode == Keys.F1)
            {
                e.Handled = true;
                OpenManual();
            }
            else if (e.Control && e.KeyCode == Keys.Oemcomma)
            {
                e.Handled = true;
                showPreferences();
            }
            else if (e.KeyCode == Keys.Apps || (e.Shift && e.KeyCode == Keys.F10))
            {
                e.Handled = true;
                ShowHistoryContextMenu();
            }
        }

        private void ListKeyPress(object sender, KeyPressEventArgs e)
        {
            if (!char.IsControl(e.KeyChar))
            {
                e.Handled = true;
                TypeSearchClipboardText(e.KeyChar);
            }
        }

        private void FileEventsListKeyPress(object sender, KeyPressEventArgs e)
        {
            if (!char.IsControl(e.KeyChar))
            {
                e.Handled = true;
                TypeSearchFileHistory(e.KeyChar);
            }
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Apps || (e.Shift && e.KeyCode == Keys.F10))
            {
                if (IsFileClipboardTabActive())
                {
                    ShowFileEventsContextMenu();
                }
                else
                {
                    ShowHistoryContextMenu();
                }
                e.Handled = true;
                return;
            }
            if (e.KeyCode == Keys.Escape)
            {
                CloseHistoryWindow();
                e.Handled = true;
                return;
            }
            if (e.KeyCode == Keys.F3)
            {
                RepeatSearch(e.Shift);
                e.Handled = true;
                return;
            }
            if (e.Control && e.KeyCode == Keys.F)
            {
                ShowSearchDialog(false);
                e.Handled = true;
                return;
            }
            if (e.Control && e.KeyCode >= Keys.D1 && e.KeyCode <= Keys.D9)
            {
                if (IsFileClipboardTabActive())
                {
                    if (e.Shift)
                    {
                        CopyPinnedFileClipboardEventPathsByPosition(e.KeyCode - Keys.D1);
                    }
                    else
                    {
                        RestorePinnedFileClipboardEventByPosition(e.KeyCode - Keys.D1);
                    }
                }
                else
                {
                    CopyPinnedByPosition(e.KeyCode - Keys.D1);
                }
                e.Handled = true;
                return;
            }
            if (e.Control && e.KeyCode == Keys.D0)
            {
                if (IsFileClipboardTabActive())
                {
                    if (e.Shift)
                    {
                        CopyPinnedFileClipboardEventPathsByPosition(9);
                    }
                    else
                    {
                        RestorePinnedFileClipboardEventByPosition(9);
                    }
                }
                else
                {
                    CopyPinnedByPosition(9);
                }
                e.Handled = true;
                return;
            }
            if (e.Control && e.KeyCode == Keys.I)
            {
                Import(false);
                e.Handled = true;
                return;
            }
            if (e.Control && e.Shift && e.KeyCode == Keys.E)
            {
                showSecrets();
                e.Handled = true;
                return;
            }
            if (e.Control && e.KeyCode == Keys.E)
            {
                Export();
                e.Handled = true;
                return;
            }
            if (e.Shift && e.KeyCode == Keys.F1)
            {
                UpdateService.CheckForUpdates(this, AppVersion(), exitApp);
                e.Handled = true;
                return;
            }
            if (e.Control && e.KeyCode == Keys.F1)
            {
                UpdateService.OpenProjectPage();
                e.Handled = true;
                return;
            }
            if (e.Alt && e.KeyCode == Keys.F1)
            {
                ShowDiagnostics();
                e.Handled = true;
                return;
            }
            if (e.KeyCode == Keys.F1)
            {
                OpenManual();
                e.Handled = true;
                return;
            }
            if (e.Control && e.KeyCode == Keys.Oemcomma)
            {
                showPreferences();
                e.Handled = true;
                return;
            }
            base.OnKeyDown(e);
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            if ((keyData & Keys.Modifiers) == Keys.Alt && (keyData & Keys.KeyCode) == Keys.F4)
            {
                CloseHistoryWindow();
                return true;
            }

            if ((keyData & Keys.Control) == Keys.Control)
            {
                var key = keyData & Keys.KeyCode;
                if (IsFileClipboardTabActive() && key == Keys.Delete)
                {
                    ClearFileClipboardHistory();
                    return true;
                }
                if (IsFileClipboardTabActive() && key == Keys.Enter)
                {
                    GoToSelectedFileClipboardEvent();
                    return true;
                }
                if (key == Keys.Tab)
                {
                    SelectNextTab((keyData & Keys.Shift) != Keys.Shift);
                    return true;
                }
            }

            if ((keyData & Keys.Alt) == Keys.Alt)
            {
                var key = keyData & Keys.KeyCode;
                if (key >= Keys.D1 && key <= Keys.D9)
                {
                    JumpToGroupByPosition(key - Keys.D1);
                    return true;
                }
                if (key == Keys.D0)
                {
                    JumpToGroupByPosition(9);
                    return true;
                }
                if (IsFileClipboardTabActive() && key == Keys.Delete)
                {
                    RemoveUnavailableFileClipboardEvents();
                    return true;
                }
                if (key == Keys.Up)
                {
                    MoveSelectedActiveTab(-1);
                    return true;
                }
                if (key == Keys.Down)
                {
                    MoveSelectedActiveTab(1);
                    return true;
                }
                if (key == Keys.T)
                {
                    SelectMainTab();
                    return true;
                }
                if (key == Keys.L)
                {
                    SelectLinksTab();
                    return true;
                }
                if (key == Keys.I)
                {
                    SelectFileClipboardTab();
                    return true;
                }
                if (key == Keys.G)
                {
                    if (!IsFileClipboardTabActive())
                    {
                        FocusGroupFilter();
                    }
                    else
                    {
                        statusText.Text = "Group filter is available on the Text history tab.";
                    }
                    return true;
                }
            }

            return base.ProcessCmdKey(ref msg, keyData);
        }

        private void CloseHistoryWindow()
        {
            SaveCurrentListPositionIfEnabled();
            Hide();
        }

        protected override void OnVisibleChanged(EventArgs e)
        {
            if (!Visible)
            {
                SaveCurrentListPositionIfEnabled();
            }

            base.OnVisibleChanged(e);
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            FocusHistoryList();
        }

        protected override void OnActivated(EventArgs e)
        {
            base.OnActivated(e);
            if (list.Focused || list.ContainsFocus || fileEventsList.Focused || fileEventsList.ContainsFocus) return;
            FocusHistoryList();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            SaveCurrentListPositionIfEnabled();
            if (e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                Hide();
                return;
            }
            base.OnFormClosing(e);
        }

        private ClipEntry SelectedEntry()
        {
            if (list.SelectedItems.Count == 0) return null;
            return list.SelectedItems[0].Tag as ClipEntry;
        }

        private bool IsNormalEntriesSeparatorSelected()
        {
            if (list.SelectedItems.Count == 0) return false;
            return list.SelectedItems[0].Tag == null &&
                string.Equals(list.SelectedItems[0].Text, "----- Normal entries -----", StringComparison.Ordinal);
        }

        private List<ClipEntry> SelectedEntries()
        {
            return list.SelectedItems.Cast<ListViewItem>()
                .OrderBy(i => i.Index)
                .Select(i => i.Tag as ClipEntry)
                .Where(e => e != null)
                .ToList();
        }

        private int FindListIndexByEntryId(string id)
        {
            if (string.IsNullOrEmpty(id)) return -1;
            for (var i = 0; i < list.Items.Count; i++)
            {
                var entry = list.Items[i].Tag as ClipEntry;
                if (entry != null && entry.Id == id)
                {
                    return i;
                }
            }
            return -1;
        }

        private int NormalizeSelectableIndex(int index)
        {
            if (list.Items.Count == 0) return -1;
            if (index < 0) index = 0;
            if (index >= list.Items.Count) index = list.Items.Count - 1;
            if (list.Items[index].Tag is ClipEntry) return index;

            for (var i = index + 1; i < list.Items.Count; i++)
            {
                if (list.Items[i].Tag is ClipEntry) return i;
            }
            for (var i = index - 1; i >= 0; i--)
            {
                if (list.Items[i].Tag is ClipEntry) return i;
            }
            return -1;
        }

        private int NormalizeFileSelectableIndex(int index)
        {
            if (fileEventsList.Items.Count == 0) return -1;
            if (index < 0) index = 0;
            if (index >= fileEventsList.Items.Count) index = fileEventsList.Items.Count - 1;
            if (fileEventsList.Items[index].Tag is ClipboardEventSummary) return index;

            for (var i = index + 1; i < fileEventsList.Items.Count; i++)
            {
                if (fileEventsList.Items[i].Tag is ClipboardEventSummary) return i;
            }
            for (var i = index - 1; i >= 0; i--)
            {
                if (fileEventsList.Items[i].Tag is ClipboardEventSummary) return i;
            }
            return -1;
        }

        private void RestoreFileEventSelection(List<string> ids)
        {
            if (ids == null || ids.Count == 0 || fileEventsList == null) return;
            fileEventsList.SelectedItems.Clear();
            var first = -1;
            for (var i = 0; i < fileEventsList.Items.Count; i++)
            {
                var item = fileEventsList.Items[i].Tag as ClipboardEventSummary;
                if (item == null || !ids.Contains(item.Id)) continue;
                fileEventsList.Items[i].Selected = true;
                fileEventsList.Items[i].Focused = true;
                if (first < 0) first = i;
            }
            if (first >= 0)
            {
                fileEventsList.Items[first].EnsureVisible();
                fileEventsList.Focus();
            }
        }

        private void SelectFileIndex(int index)
        {
            index = NormalizeFileSelectableIndex(index);
            if (index < 0 || index >= fileEventsList.Items.Count) return;
            fileEventsList.SelectedItems.Clear();
            foreach (ListViewItem item in fileEventsList.Items)
            {
                item.Focused = false;
            }
            fileEventsList.Items[index].Selected = true;
            fileEventsList.Items[index].Focused = true;
            fileEventsList.Items[index].EnsureVisible();
            fileEventsList.Focus();
        }

        private void RestoreSelection(List<string> ids)
        {
            if (ids == null || ids.Count == 0) return;
            list.SelectedItems.Clear();
            var first = -1;
            for (var i = 0; i < list.Items.Count; i++)
            {
                var entry = list.Items[i].Tag as ClipEntry;
                if (entry == null || !ids.Contains(entry.Id)) continue;
                list.Items[i].Selected = true;
                list.Items[i].Focused = true;
                if (first < 0) first = i;
            }
            if (first >= 0)
            {
                list.Items[first].EnsureVisible();
                list.Focus();
            }
        }

        private void JumpToNormalEntries()
        {
            for (var i = 0; i < list.Items.Count; i++)
            {
                var entry = list.Items[i].Tag as ClipEntry;
                if (entry == null || entry.Pinned) continue;
                SelectIndex(i);
                statusText.Text = "Normal entries.";
                list.Focus();
                return;
            }

            statusText.Text = "No normal entries.";
        }

        private void JumpToNormalFileClipboardEvents()
        {
            for (var i = 0; i < fileEventsList.Items.Count; i++)
            {
                var item = fileEventsList.Items[i].Tag as ClipboardEventSummary;
                if (item == null || item.Pinned) continue;
                SelectFileIndex(i);
                statusText.Text = "Normal file-history events.";
                fileEventsList.Focus();
                return;
            }

            statusText.Text = "No normal file-history events.";
        }

        private void SetSortMode(string sortMode)
        {
            if (IsFileClipboardTabActive())
            {
                var selectedIds = SelectedFileClipboardEvents().Select(e => e.Id).ToList();
                settings.FileHistorySortMode = FileSortModeForMenuSort(sortMode);
                saveSettings();
                RefreshFileClipboardEvents();
                RestoreFileEventSelection(selectedIds);
                statusText.Text = "Sorted file history.";
            }
            else
            {
                settings.SortMode = sortMode;
                saveSettings();
                Reload();
                statusText.Text = "Sorted clipboard history.";
            }
        }

        private void ToggleSortDirection()
        {
            if (IsFileClipboardTabActive())
            {
                var selectedIds = SelectedFileClipboardEvents().Select(e => e.Id).ToList();
                settings.FileHistorySortDescending = !settings.FileHistorySortDescending;
                saveSettings();
                RefreshFileClipboardEvents();
                RestoreFileEventSelection(selectedIds);
                statusText.Text = FileSortDirectionStatusText();
                return;
            }

            settings.SortDescending = !settings.SortDescending;
            saveSettings();
            Reload();
            statusText.Text = SortDirectionStatusText(false);
        }

        private void RefreshGroupFilterItems()
        {
            if (groupFilter == null) return;
            var current = CurrentGroupFilter();
            var groups = GroupFilterItems();

            var existing = groupFilter.Items.Cast<object>().Select(Convert.ToString).ToList();
            if (existing.SequenceEqual(groups))
            {
                return;
            }

            updatingGroupFilter = true;
            groupFilter.BeginUpdate();
            try
            {
                groupFilter.Items.Clear();
                foreach (var group in groups)
                {
                    groupFilter.Items.Add(group);
                }
                var index = groups.FindIndex(g => string.Equals(g, current, StringComparison.CurrentCultureIgnoreCase));
                if (index < 0) index = 0;
                groupFilter.SelectedIndex = index;
            }
            finally
            {
                groupFilter.EndUpdate();
                updatingGroupFilter = false;
            }
        }

        private List<string> GroupFilterItems()
        {
            var groups = new List<string> { "All", "Pinned", "Named", "Ungrouped" };
            groups.AddRange(store.GetGroups().Where(g => !groups.Contains(g, StringComparer.CurrentCultureIgnoreCase)));
            return groups;
        }

        private string CurrentGroupFilter()
        {
            return string.IsNullOrWhiteSpace(settings.GroupFilter) ? "All" : settings.GroupFilter;
        }

        private void FileEventsListKeyDown(object sender, KeyEventArgs e)
        {
            if (e.Control && e.KeyCode == Keys.Enter)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                GoToSelectedFileClipboardEvent();
            }
            else if (e.Shift && e.KeyCode == Keys.Enter)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                ToggleSelectedFileClipboardEventPinned();
            }
            else if (e.KeyCode == Keys.Enter)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                RestoreSelectedFileClipboardEvent(true);
            }
            else if (e.Control && e.KeyCode == Keys.Delete)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                ClearFileClipboardHistory();
            }
            else if (e.Alt && e.KeyCode == Keys.Delete)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                RemoveUnavailableFileClipboardEvents();
            }
            else if (e.Control && e.KeyCode == Keys.C)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                CopySelectedFileClipboardPaths();
            }
            else if (e.Alt && e.KeyCode == Keys.Up)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                MoveSelectedFileClipboardEvents(-1);
            }
            else if (e.Alt && e.KeyCode == Keys.Down)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                MoveSelectedFileClipboardEvents(1);
            }
            else if (e.Control && e.KeyCode >= Keys.D1 && e.KeyCode <= Keys.D9)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                if (e.Shift)
                {
                    CopyPinnedFileClipboardEventPathsByPosition(e.KeyCode - Keys.D1);
                }
                else
                {
                    RestorePinnedFileClipboardEventByPosition(e.KeyCode - Keys.D1);
                }
            }
            else if (e.Control && e.KeyCode == Keys.D0)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                if (e.Shift)
                {
                    CopyPinnedFileClipboardEventPathsByPosition(9);
                }
                else
                {
                    RestorePinnedFileClipboardEventByPosition(9);
                }
            }
            else if (e.KeyCode == Keys.Delete)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                DeleteSelectedFileClipboardEvent();
            }
            else if (e.KeyCode == Keys.Back)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                JumpToNormalFileClipboardEvents();
            }
            else if (e.Modifiers == Keys.None && e.KeyCode == Keys.F4)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                ViewSelectedFileClipboardEvent();
            }
            else if (e.KeyCode == Keys.Apps || (e.Shift && e.KeyCode == Keys.F10))
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                ShowFileEventsContextMenu();
            }
        }

        private void RestoreSelectedFileClipboardEvent()
        {
            RestoreSelectedFileClipboardEvents(false);
        }

        private void RestoreSelectedFileClipboardEvent(bool closeAfterRestore)
        {
            RestoreSelectedFileClipboardEvents(closeAfterRestore);
        }

        private void RestoreSelectedFileClipboardEvents()
        {
            RestoreSelectedFileClipboardEvents(false);
        }

        private void RestoreSelectedFileClipboardEvents(bool closeAfterRestore)
        {
            var selected = SelectedFileClipboardEvents();
            RestoreFileClipboardEvents(selected, closeAfterRestore);
        }

        private void RestorePinnedFileClipboardEventByPosition(int position)
        {
            var pinnedEvents = recentClipboardEvents == null
                ? new List<ClipboardEventSummary>()
                : (recentClipboardEvents() ?? new List<ClipboardEventSummary>()).Where(e => e.Pinned).ToList();
            if (position < 0 || position >= pinnedEvents.Count)
            {
                statusText.Text = "No pinned file-history event at position " + (position + 1) + ".";
                return;
            }

            RestoreFileClipboardEvents(new List<ClipboardEventSummary> { pinnedEvents[position] }, true);
        }

        private void CopyPinnedFileClipboardEventPathsByPosition(int position)
        {
            var pinnedEvents = recentClipboardEvents == null
                ? new List<ClipboardEventSummary>()
                : (recentClipboardEvents() ?? new List<ClipboardEventSummary>()).Where(e => e.Pinned).ToList();
            if (position < 0 || position >= pinnedEvents.Count)
            {
                statusText.Text = "No pinned file-history event at position " + (position + 1) + ".";
                return;
            }

            CopyFileClipboardEventPaths(new List<ClipboardEventSummary> { pinnedEvents[position] }, true);
        }

        private void RestoreFileClipboardEvents(List<ClipboardEventSummary> selected, bool closeAfterRestore)
        {
            var existing = ExistingFileClipboardPaths(selected);
            if (selected == null || selected.Count == 0)
            {
                statusText.Text = "No file clipboard event is selected.";
                return;
            }

            if (existing.Length == 0)
            {
                statusText.Text = "No existing files or folders remain for the selected file-history event or events.";
                return;
            }

            try
            {
                var paths = new StringCollection();
                paths.AddRange(existing);
                var data = new DataObject();
                data.SetFileDropList(paths);
                data.SetText(string.Join(Environment.NewLine, existing), TextDataFormat.UnicodeText);
                Clipboard.SetDataObject(data, true);
                statusText.Text = existing.Length == 1
                    ? "Restored one file or folder to the clipboard."
                    : "Restored " + existing.Length + " files or folders to the clipboard.";
                if (closeAfterRestore)
                {
                    CloseHistoryWindow();
                }
            }
            catch (Exception ex)
            {
                statusText.Text = "Could not restore file clipboard event: " + ex.Message;
            }
        }

        private void GoToSelectedFileClipboardEvent()
        {
            var item = SelectedFileClipboardEvent();
            if (item == null || item.Files == null || item.Files.Count != 1)
            {
                statusText.Text = "Go to file needs one selected file-history event containing exactly one file or folder.";
                return;
            }

            var path = item.Files[0];
            if (string.IsNullOrWhiteSpace(path))
            {
                statusText.Text = "Selected file-history event does not contain a usable path.";
                return;
            }

            try
            {
                if (File.Exists(path))
                {
                    Process.Start("explorer.exe", "/select,\"" + path + "\"");
                    statusText.Text = "Opened file location.";
                }
                else if (Directory.Exists(path))
                {
                    Process.Start("explorer.exe", "\"" + path + "\"");
                    statusText.Text = "Opened folder.";
                }
                else
                {
                    statusText.Text = "That file or folder no longer exists.";
                }
            }
            catch (Exception ex)
            {
                statusText.Text = "Could not open file location: " + ex.Message;
            }
        }

        private void CopySelectedFileClipboardPaths()
        {
            CopyFileClipboardEventPaths(SelectedFileClipboardEvents(), false);
        }

        private void CopyFileClipboardEventPaths(List<ClipboardEventSummary> selected, bool closeAfterCopy)
        {
            var paths = AllFileClipboardPaths(selected);
            if (selected.Count == 0)
            {
                statusText.Text = "No file clipboard event is selected.";
                return;
            }

            if (paths.Length == 0)
            {
                statusText.Text = "Selected file-history event or events do not contain file paths.";
                return;
            }

            Clipboard.SetText(string.Join(Environment.NewLine, paths));
            statusText.Text = paths.Length == 1
                ? "Copied one file path to the clipboard."
                : "Copied " + paths.Length + " file paths to the clipboard.";
            if (closeAfterCopy)
            {
                CloseHistoryWindow();
            }
        }

        private void ViewSelectedFileClipboardEvent()
        {
            var item = SelectedFileClipboardEvent();
            if (item == null)
            {
                statusText.Text = "No file clipboard event is selected.";
                return;
            }

            using (var viewer = new TextViewerForm(
                "File Clipboard Event",
                FileClipboardEventDetails(item),
                "File clipboard event details",
                "Read-only details for the selected file clipboard event.",
                true))
            {
                viewer.ShowDialog(this);
            }
        }

        private void DeleteSelectedFileClipboardEvent()
        {
            if (fileEventsList == null || fileEventsList.SelectedItems.Count == 0) return;
            var preferredIndex = fileEventsList.SelectedItems[0].Index;
            var requested = SelectedFileClipboardEvents();
            var ids = fileEventsList.SelectedItems.Cast<ListViewItem>()
                .Select(i => i.Tag as ClipboardEventSummary)
                .Where(e => e != null && !e.Pinned && !string.IsNullOrWhiteSpace(e.Id))
                .Select(e => e.Id)
                .ToList();
            if (ids.Count == 0 && requested.Count > 0)
            {
                statusText.Text = "Pinned file-history events are protected. Unpin before deleting.";
                return;
            }
            var removed = deleteRecentClipboardEvents == null ? 0 : deleteRecentClipboardEvents(ids);
            RefreshFileClipboardEvents(preferredIndex);
            if (removed == 0 && requested.Count > 0)
            {
                statusText.Text = "Pinned file-history events are protected. Unpin before deleting.";
            }
            else
            {
                statusText.Text = removed == 1 ? "Deleted one file history event." : "Deleted " + removed + " file history events.";
            }
        }

        private void ToggleSelectedFileClipboardEventPinned()
        {
            var selected = SelectedFileClipboardEvents();
            if (selected.Count == 0) return;
            var selectedIds = selected.Select(e => e.Id).ToList();
            var pinned = false;
            foreach (var item in selected)
            {
                if (toggleRecentClipboardEventPinned != null)
                {
                    pinned = toggleRecentClipboardEventPinned(item.Id);
                }
            }
            RefreshFileClipboardEvents();
            RestoreFileEventSelection(selectedIds);
            statusText.Text = selected.Count == 1
                ? (pinned ? "Pinned selected file-history event." : "Unpinned selected file-history event.")
                : "Toggled pinned state for " + selected.Count + " file-history events.";
        }

        private void MoveSelectedActiveTab(int direction)
        {
            if (IsFileClipboardTabActive())
            {
                MoveSelectedFileClipboardEvents(direction);
            }
            else
            {
                MoveSelected(direction);
            }
        }

        private void MoveSelectedFileClipboardEvents(int direction)
        {
            var selected = SelectedFileClipboardEvents();
            if (selected.Count == 0) return;
            if (selected.Any(e => e.Pinned != selected[0].Pinned))
            {
                statusText.Text = "Move pinned and normal file-history events separately.";
                return;
            }

            var selectedIds = selected.Select(e => e.Id).ToList();
            if (moveRecentClipboardEvents != null)
            {
                moveRecentClipboardEvents(selectedIds, direction);
            }
            settings.FileHistorySortMode = "Manual";
            settings.FileHistorySortDescending = false;
            saveSettings();
            RefreshFileClipboardEvents();
            RestoreFileEventSelection(selectedIds);
            statusText.Text = direction < 0 ? "Moved selected file-history event or events up." : "Moved selected file-history event or events down.";
        }

        private void ClearFileClipboardHistory()
        {
            if (MessageBox.Show(
                this,
                "Clear file history?\r\n\r\nThis removes remembered file and non-text clipboard events from this computer. It does not delete any files from disk.",
                "Clear file history",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning,
                MessageBoxDefaultButton.Button2) != DialogResult.Yes)
            {
                return;
            }

            var removed = clearRecentClipboardEvents == null ? 0 : clearRecentClipboardEvents();
            RefreshFileClipboardEvents(0);
            statusText.Text = removed == 1 ? "Cleared one normal file history event. Pinned events were kept." : "Cleared " + removed + " normal file history events. Pinned events were kept.";
        }

        private void RemoveUnavailableFileClipboardEvents()
        {
            var removed = removeUnavailableRecentClipboardEvents == null ? 0 : removeUnavailableRecentClipboardEvents();
            RefreshFileClipboardEvents();
            statusText.Text = removed == 1 ? "Removed one unavailable unpinned file-history event." : "Removed " + removed + " unavailable unpinned file-history events.";
        }

        private void ClearTextClipboardHistory()
        {
            if (clearTextHistory == null) return;
            if (!clearTextHistory()) return;
            Reload(null, 0);
            statusText.Text = "Cleared text clipboard history.";
        }

        private ClipboardEventSummary SelectedFileClipboardEvent()
        {
            if (fileEventsList == null || fileEventsList.SelectedItems.Count == 0) return null;
            return fileEventsList.SelectedItems[0].Tag as ClipboardEventSummary;
        }

        private List<ClipboardEventSummary> SelectedFileClipboardEvents()
        {
            if (fileEventsList == null || fileEventsList.SelectedItems.Count == 0) return new List<ClipboardEventSummary>();
            return fileEventsList.SelectedItems.Cast<ListViewItem>()
                .OrderBy(i => i.Index)
                .Select(i => i.Tag as ClipboardEventSummary)
                .Where(e => e != null)
                .ToList();
        }

        private static bool HasRestorableFilePaths(ClipboardEventSummary item)
        {
            return ExistingFileClipboardPaths(new[] { item }).Length > 0;
        }

        private static string[] AllFileClipboardPaths(IEnumerable<ClipboardEventSummary> items)
        {
            return (items ?? Enumerable.Empty<ClipboardEventSummary>())
                .Where(item => item != null && item.Files != null)
                .SelectMany(item => item.Files)
                .Where(path => !string.IsNullOrWhiteSpace(path))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray();
        }

        private static string[] ExistingFileClipboardPaths(IEnumerable<ClipboardEventSummary> items)
        {
            return AllFileClipboardPaths(items)
                .Where(path => File.Exists(path) || Directory.Exists(path))
                .ToArray();
        }

        private string FileClipboardEventDetails(ClipboardEventSummary item)
        {
            NormalizeFileClipboardEvent(item);
            var lines = new List<string>();
            lines.Add("Captured: " + item.CapturedAt.ToString("yyyy-MM-dd HH:mm:ss"));
            lines.Add("Source: " + (item.Source ?? string.Empty));
            lines.Add("Operation: " + NormalizeDropEffectText(item.Operation));
            lines.Add("File count: " + item.FileCount);
            if (item.Formats != null && item.Formats.Count > 0)
            {
                lines.Add("Formats: " + string.Join(", ", item.Formats));
            }
            if (item.Files != null && item.Files.Count > 0)
            {
                lines.Add(string.Empty);
                lines.Add("Files:");
                lines.AddRange(item.Files);
            }
            return string.Join(Environment.NewLine, lines);
        }

        private static string FileEventDisplayText(ClipboardEventSummary item)
        {
            if (item == null) return string.Empty;
            NormalizeFileClipboardEvent(item);
            if (item.Files != null && item.Files.Count > 0)
            {
                var first = FileEventPrimaryName(item);
                return string.IsNullOrWhiteSpace(first) ? "File clipboard event" : first;
            }

            if (item.Formats != null && item.Formats.Count > 0)
            {
                return "Non-text clipboard event, " + string.Join(", ", item.Formats.Take(3));
            }

            return "Non-text clipboard event";
        }

        private static string FileEventPrimaryName(ClipboardEventSummary item)
        {
            if (item == null || item.Files == null || item.Files.Count == 0) return string.Empty;
            var firstPath = item.Files.FirstOrDefault(path => !string.IsNullOrWhiteSpace(path)) ?? string.Empty;
            string name;
            try
            {
                name = Path.GetFileName(firstPath);
            }
            catch
            {
                name = string.Empty;
            }
            return string.IsNullOrWhiteSpace(name) ? firstPath : name;
        }

        private static void NormalizeFileClipboardEvent(ClipboardEventSummary item)
        {
            if (item == null) return;
            item.Operation = NormalizeDropEffectText(item.Operation);
            if (item.Formats == null || item.Formats.Count == 0) return;
            for (var i = 0; i < item.Formats.Count; i++)
            {
                item.Formats[i] = NormalizeDropEffectText(item.Formats[i]);
            }
        }

        private static string NormalizeDropEffectText(string text)
        {
            if (string.IsNullOrWhiteSpace(text)) return string.Empty;
            return Regex.Replace(
                text,
                @"\b(?:Preferred\s+)?DropEffect\s*[:=]?\s*(\d+)\b",
                match =>
                {
                    int value;
                    if (!int.TryParse(match.Groups[1].Value, out value)) return match.Value;
                    var description = ClipmanApplicationContext.DescribeDropEffect(value);
                    return string.IsNullOrWhiteSpace(description) ? "No file operation" : description;
                },
                RegexOptions.IgnoreCase);
        }

        private void ApplyGroupFilter()
        {
            if (updatingGroupFilter || groupFilter == null || groupFilter.SelectedItem == null) return;
            var selected = Convert.ToString(groupFilter.SelectedItem);
            SetGroupFilter(selected);
        }

        private void SetGroupFilter(string selected)
        {
            selected = string.IsNullOrWhiteSpace(selected) ? "All" : selected;
            if (string.Equals(CurrentGroupFilter(), selected, StringComparison.CurrentCultureIgnoreCase)) return;
            settings.GroupFilter = selected;
            saveSettings();
            RefreshGroupFilterItems();
            Reload(null, 0);
            statusText.Text = "Showing group filter " + selected + ".";
        }

        private bool IsSortMode(string sortMode)
        {
            return string.Equals(settings.SortMode ?? "LastUsed", sortMode, StringComparison.OrdinalIgnoreCase);
        }

        private bool IsFileSortMode(string sortMode)
        {
            return string.Equals(settings.FileHistorySortMode ?? "Manual", sortMode, StringComparison.OrdinalIgnoreCase);
        }

        private static string FileSortModeForMenuSort(string menuSortMode)
        {
            switch ((menuSortMode ?? string.Empty).Trim().ToUpperInvariant())
            {
                case "LASTUSED":
                    return "Time";
                case "ADDED":
                    return "Files";
                case "TEXT":
                    return "Name";
                case "GROUP":
                    return "Operation";
                case "MACHINE":
                    return "Source";
                case "MANUAL":
                    return "Manual";
                default:
                    return "Manual";
            }
        }

        private void CopySelected()
        {
            CopySelected(true);
        }

        private void CopySelected(bool closeAfterCopy)
        {
            var selected = SelectedEntries();
            if (selected.Count == 0) return;
            SaveCurrentListPositionIfEnabled();
            if (selected.Count == 1)
            {
                copyEntry(selected[0]);
            }
            else
            {
                copyEntries(selected);
            }
            statusText.Text = selected.Count == 1 ? "Copied selected entry to the clipboard." : "Copied " + selected.Count + " entries to the clipboard.";
            if (closeAfterCopy)
            {
                Hide();
            }
        }

        private void SaveCurrentListPositionIfEnabled()
        {
            if (!settings.SaveListPosition) return;
            var selectedIndex = list.SelectedIndices.Count > 0 ? list.SelectedIndices[0] : -1;
            SaveListPositionIndex(selectedIndex);
        }

        private void SaveListPositionIndex(int selectedIndex)
        {
            if (!settings.SaveListPosition) return;
            settings.LastSelectedIndex = selectedIndex;
            saveSettings();
        }

        private void CopySelectedPlainText(bool closeAfterCopy)
        {
            var selected = SelectedEntries();
            if (selected.Count == 0) return;
            var text = selected.Count == 1
                ? selected[0].Text ?? string.Empty
                : string.Join("\r\n\r\n", selected.Select(e => e.Text ?? string.Empty));
            Clipboard.SetText(text, TextDataFormat.UnicodeText);
            foreach (var entry in selected)
            {
                store.MarkUsed(entry.Id);
            }
            statusText.Text = "Copied selected entry or entries as plain text.";
            if (closeAfterCopy)
            {
                Hide();
            }
        }

        private void PushSelectedToOtherMachines()
        {
            var selected = SelectedEntries();
            if (selected.Count == 0)
            {
                statusText.Text = "No clipboard entry selected to push.";
                return;
            }

            var firstSelectedId = selected[0].Id;
            var keepDuplicateEntries = string.Equals(settings.DuplicateMode, "KeepBoth", StringComparison.OrdinalIgnoreCase);
            var pushed = store.PushEntriesToOtherMachines(selected.Select(e => e.Id), keepDuplicateEntries);
            if (pushed == 0)
            {
                statusText.Text = "No text entries were pushed.";
                return;
            }

            if (selected.Count == 1)
            {
                copyEntry(selected[0]);
            }
            else
            {
                copyEntries(selected);
            }

            Reload(firstSelectedId, -1);
            FocusHistoryList();
            statusText.Text = pushed == 1
                ? "Pushed selected entry to other machines and copied it to this clipboard."
                : "Pushed " + pushed + " selected entries to other machines and copied them to this clipboard.";
        }

        private void CopyPinnedByPosition(int position)
        {
            var pinnedEntries = TextEntriesForActiveTab(store.GetEntries(settings.SortMode, "Pinned", settings.SortDescending));
            if (position < 0 || position >= pinnedEntries.Count)
            {
                statusText.Text = "No pinned clipboard entry at position " + (position + 1) + ".";
                return;
            }
            copyEntry(pinnedEntries[position]);
            statusText.Text = "Copied pinned entry " + (position + 1) + " to the clipboard.";
            Hide();
        }

        private void JumpToGroupByPosition(int position)
        {
            var groups = GroupFilterItems();
            if (position < 0 || position >= groups.Count)
            {
                statusText.Text = "No group filter at position " + (position + 1) + ".";
                return;
            }

            SetGroupFilter(groups[position]);
        }

        private void DeleteSelected()
        {
            if (list.SelectedItems.Count == 0) return;
            var selectedEntries = SelectedEntries();
            var preferredIndex = list.SelectedItems.Cast<ListViewItem>()
                .Where(i => i.Tag is ClipEntry)
                .Select(i => i.Index)
                .DefaultIfEmpty(-1)
                .Min();
            var ids = list.SelectedItems.Cast<ListViewItem>()
                .Select(i => {
                    var entry = i.Tag as ClipEntry;
                    return entry == null || entry.Pinned ? null : entry.Id;
                })
                .Where(id => !string.IsNullOrEmpty(id))
                .ToList();
            if (ids.Count == 0 && selectedEntries.Count > 0)
            {
                statusText.Text = "Pinned entries are protected. Unpin before deleting.";
                return;
            }
            SaveListPositionIndex(preferredIndex);
            store.DeleteMany(ids);
            Reload(null, preferredIndex);
            statusText.Text = "Deleted " + ids.Count + " clipboard entry or entries.";
        }

        private void CutSelected()
        {
            var selected = SelectedEntries();
            if (selected.Count == 0) return;
            var preferredIndex = list.SelectedItems.Cast<ListViewItem>()
                .Where(i => i.Tag is ClipEntry)
                .Select(i => i.Index)
                .DefaultIfEmpty(-1)
                .Min();
            CopySelected(false);
            var ids = selected
                .Where(e => !e.Pinned)
                .Select(e => e.Id)
                .ToList();
            SaveListPositionIndex(preferredIndex);
            store.DeleteMany(ids);
            Reload(null, preferredIndex);
            statusText.Text = "Cut " + ids.Count + " unpinned clipboard entry or entries.";
        }

        private void PasteAfterSelected()
        {
            var clipmanEntries = GetClipmanEntriesFromClipboard();
            if (clipmanEntries.Count == 0 && !Clipboard.ContainsText(TextDataFormat.UnicodeText))
            {
                statusText.Text = "Clipboard does not contain text to paste.";
                return;
            }

            if (clipmanEntries.Count == 0)
            {
                string text;
                try
                {
                    text = Clipboard.GetText(TextDataFormat.UnicodeText);
                }
                catch
                {
                    statusText.Text = "Could not read text from the clipboard.";
                    return;
                }

                if (string.IsNullOrEmpty(text))
                {
                    statusText.Text = "Clipboard text is empty.";
                    return;
                }

                clipmanEntries.Add(new ClipEntry { Text = text });
            }

            var selected = SelectedEntry();
            var afterId = selected == null ? null : selected.Id;
            var insertAtNormalStart = IsNormalEntriesSeparatorSelected();
            var visibleOrder = entries.Select(e => e.Id).ToList();
            store.SetManualOrder(visibleOrder);
            settings.SortMode = "Manual";
            saveSettings();
            var inserted = insertAtNormalStart
                ? store.InsertEntriesAtNormalStart(clipmanEntries, settings.RemoveDuplicates)
                : store.InsertEntriesAfter(clipmanEntries, afterId, settings.RemoveDuplicates);
            Reload();
            if (inserted.Count > 0)
            {
                RestoreSelection(inserted.Select(e => e.Id).ToList());
            }
            statusText.Text = inserted.Count == 1 ? "Pasted clipboard text into history." : "Pasted " + inserted.Count + " clipboard entries into history.";
        }

        private List<ClipEntry> GetClipmanEntriesFromClipboard()
        {
            try
            {
                var data = Clipboard.GetDataObject();
                if (data == null || !data.GetDataPresent(ClipmanClipboardData.EntriesFormat))
                {
                    return new List<ClipEntry>();
                }

                return ClipmanClipboardData.DeserializeEntries(data.GetData(ClipmanClipboardData.EntriesFormat))
                    .Where(e => e != null && !string.IsNullOrEmpty(e.Text))
                    .ToList();
            }
            catch
            {
                return new List<ClipEntry>();
            }
        }

        private void TogglePinned()
        {
            var selected = SelectedEntries();
            if (selected.Count == 0) return;
            var pinned = false;
            foreach (var entry in selected)
            {
                pinned = store.TogglePinned(entry.Id);
            }
            Reload();
            statusText.Text = selected.Count == 1
                ? (pinned ? "Pinned selected entry." : "Unpinned selected entry.")
                : "Toggled pinned state for " + selected.Count + " entries.";
        }

        private void GroupSelectedEntries()
        {
            var selected = SelectedEntries();
            if (selected.Count == 0) return;
            var initial = selected.Select(e => e.Group ?? string.Empty).Distinct(StringComparer.CurrentCultureIgnoreCase).Count() == 1
                ? selected[0].Group
                : string.Empty;
            using (var dialog = new GroupPromptForm(initial, store.GetGroups()))
            {
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                var selectedIds = selected.Select(e => e.Id).ToList();
                store.SetGroup(selectedIds, dialog.Value);
                RefreshGroupFilterItems();
                Reload();
                RestoreSelection(selectedIds);
                statusText.Text = string.IsNullOrWhiteSpace(dialog.Value)
                    ? "Removed selected entry or entries from their group."
                    : "Grouped selected entry or entries.";
            }
        }

        private void ShowEntryProperties()
        {
            ShowEntryProperties(false);
        }

        private void ShowEntryProperties(bool forceQuickCopyTarget)
        {
            var selected = SelectedEntries();
            if (selected.Count == 0) return;
            if (selected.Count > 1)
            {
                statusText.Text = "Select one entry to show properties.";
                return;
            }

            var entry = selected[0];
            var preferredIndex = list.SelectedIndices.Count > 0 ? list.SelectedIndices[0] : -1;
            var existingQuickCopyHotkey = QuickCopyHotkeyForEntry(entry.Id);
            var existingQuickPasteMode = QuickPasteModeForEntry(entry.Id);
            var wasQuickCopyTarget = existingQuickCopyHotkey.Length > 0;
            using (var dialog = new EntryPropertiesForm(
                entry,
                forceQuickCopyTarget || existingQuickCopyHotkey.Length > 0,
                existingQuickCopyHotkey,
                existingQuickPasteMode,
                forceQuickCopyTarget))
            {
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                if (dialog.DeleteRequested)
                {
                    if (!entry.Pinned)
                    {
                        store.Delete(entry.Id);
                        Reload(null, preferredIndex);
                        statusText.Text = "Deleted selected clipboard entry.";
                    }
                    else
                    {
                        statusText.Text = "Pinned entries are protected. Unpin before deleting.";
                    }
                    return;
                }

                if (!ValidateQuickCopySettings(dialog.EntryIsQuickCopyTarget, dialog.EntryQuickCopyHotkey))
                {
                    return;
                }

                store.SetNameAndText(entry.Id, dialog.EntryName, dialog.EntryText);
                store.SetGroup(new[] { entry.Id }, dialog.EntryGroup);
                store.SetPinned(entry.Id, dialog.EntryPinned);
                store.SetTemplate(entry.Id, dialog.EntryIsTemplate);
                if (dialog.EntryIsQuickCopyTarget)
                {
                    SetQuickCopyHotkeyForEntry(entry.Id, dialog.EntryQuickCopyHotkey, dialog.EntryQuickPasteMode);
                }
                else
                {
                    RemoveQuickCopyHotkeyForEntry(entry.Id);
                }
                if (saveSettings != null) saveSettings();
                if (QuickCopyAssignmentChanged(wasQuickCopyTarget, existingQuickCopyHotkey, existingQuickPasteMode, dialog.EntryIsQuickCopyTarget, dialog.EntryQuickCopyHotkey, dialog.EntryQuickPasteMode) &&
                    refreshHotkeys != null)
                {
                    refreshHotkeys();
                }
                RefreshGroupFilterItems();
                Reload(entry.Id, -1);
                statusText.Text = "Updated clipboard entry properties.";
            }
        }

        private static bool QuickCopyAssignmentChanged(bool wasQuickCopyTarget, string oldHotkey, string oldMode, bool isQuickCopyTarget, string newHotkey, string newMode)
        {
            if (wasQuickCopyTarget != isQuickCopyTarget) return true;
            return !string.Equals((oldHotkey ?? string.Empty).Trim(), (newHotkey ?? string.Empty).Trim(), StringComparison.OrdinalIgnoreCase) ||
                   !string.Equals(QuickPasteModes.Normalize(oldMode), QuickPasteModes.Normalize(newMode), StringComparison.OrdinalIgnoreCase);
        }

        private bool ValidateQuickCopySettings(bool isQuickCopyTarget, string quickCopyHotkey)
        {
            if (!isQuickCopyTarget)
            {
                return true;
            }

            HotkeyDefinition parsed;
            if (!HotkeyDefinition.TryParse(quickCopyHotkey, out parsed))
            {
                MessageBox.Show(this, "Choose a valid Quick Paste hotkey before saving this Quick Paste assignment.", "Clipman Quick Paste", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }

            if (string.Equals((quickCopyHotkey ?? string.Empty).Trim(), (settings.ShowHistoryHotkey ?? string.Empty).Trim(), StringComparison.OrdinalIgnoreCase) ||
                string.Equals((quickCopyHotkey ?? string.Empty).Trim(), (settings.ToggleActiveHotkey ?? string.Empty).Trim(), StringComparison.OrdinalIgnoreCase))
            {
                MessageBox.Show(this, "The Quick Paste hotkey must be different from the Show History and Toggle Monitoring hotkeys.", "Clipman Quick Paste", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }

            if (HotkeyDefinition.IsSingleModifierHotkey(quickCopyHotkey))
            {
                var result = MessageBox.Show(
                    this,
                    "This Quick Paste hotkey uses only one modifier. Clipman allows this for compatibility, but it is more likely to conflict with other apps or keyboard layouts. Keep this hotkey anyway?",
                    "Clipman Quick Paste",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning);
                if (result != DialogResult.Yes)
                {
                    return false;
                }
            }

            var currentEntry = SelectedEntries().FirstOrDefault();
            var currentEntryId = currentEntry == null ? string.Empty : currentEntry.Id;
            if ((settings.QuickCopyHotkeys ?? new List<QuickCopyBinding>()).Any(b =>
                b != null &&
                !string.Equals(b.EntryId, currentEntryId, StringComparison.OrdinalIgnoreCase) &&
                string.Equals((b.Hotkey ?? string.Empty).Trim(), (quickCopyHotkey ?? string.Empty).Trim(), StringComparison.OrdinalIgnoreCase)))
            {
                MessageBox.Show(this, "Another Quick Paste entry already uses this hotkey.", "Clipman Quick Paste", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }

            return true;
        }

        private string QuickCopyHotkeyForEntry(string entryId)
        {
            var binding = QuickCopyBindingForEntry(entryId);
            return binding == null ? string.Empty : (binding.Hotkey ?? string.Empty).Trim();
        }

        private string QuickPasteModeForEntry(string entryId)
        {
            var binding = QuickCopyBindingForEntry(entryId);
            return binding == null ? QuickPasteModes.PasteRestore : QuickPasteModes.Normalize(binding.Mode);
        }

        private QuickCopyBinding QuickCopyBindingForEntry(string entryId)
        {
            if (string.IsNullOrWhiteSpace(entryId) || settings.QuickCopyHotkeys == null) return null;
            return settings.QuickCopyHotkeys.FirstOrDefault(b =>
                b != null && string.Equals(b.EntryId, entryId, StringComparison.OrdinalIgnoreCase));
        }

        private static string QuickPasteModeDisplayText(string mode)
        {
            mode = QuickPasteModes.Normalize(mode);
            if (mode == QuickPasteModes.PasteKeep) return "paste and keep target on clipboard";
            if (mode == QuickPasteModes.CopyOnly) return "copy to clipboard only";
            return "paste and restore clipboard";
        }

        private void SetQuickCopyHotkeyForEntry(string entryId, string hotkey, string mode)
        {
            if (string.IsNullOrWhiteSpace(entryId)) return;
            if (settings.QuickCopyHotkeys == null) settings.QuickCopyHotkeys = new List<QuickCopyBinding>();
            settings.QuickCopyHotkeys.RemoveAll(b => b == null || string.Equals(b.EntryId, entryId, StringComparison.OrdinalIgnoreCase));
            settings.QuickCopyHotkeys.Add(new QuickCopyBinding { EntryId = entryId, Hotkey = (hotkey ?? string.Empty).Trim(), Mode = QuickPasteModes.Normalize(mode) });
        }

        private void RemoveQuickCopyHotkeyForEntry(string entryId)
        {
            if (settings.QuickCopyHotkeys == null) settings.QuickCopyHotkeys = new List<QuickCopyBinding>();
            settings.QuickCopyHotkeys.RemoveAll(b => b == null || string.Equals(b.EntryId, entryId, StringComparison.OrdinalIgnoreCase));
        }

        private void TransformSelected(Func<string, string> transform, string statusMessage)
        {
            var selected = SelectedEntries();
            if (selected.Count == 0 || transform == null) return;
            var selectedIds = selected.Select(e => e.Id).ToList();
            var transformed = new List<string>();
            foreach (var entry in selected)
            {
                try
                {
                    var text = transform(entry.Text ?? string.Empty) ?? string.Empty;
                    store.ReplaceText(entry.Id, text);
                    store.MarkUsed(entry.Id);
                    transformed.Add(text);
                }
                catch
                {
                }
            }
            Reload();
            RestoreSelection(selectedIds);
            if (transformed.Count > 0)
            {
                Clipboard.SetText(string.Join("\r\n\r\n", transformed), TextDataFormat.UnicodeText);
                statusText.Text = statusMessage + " Copied transformed text to the clipboard.";
            }
            else
            {
                statusText.Text = statusMessage;
            }
        }

        private void MoveSelected(int direction)
        {
            var selectedEntries = SelectedEntries();
            var selectedIds = selectedEntries.Select(e => e.Id).ToList();
            if (selectedIds.Count == 0) return;
            if (selectedEntries.Any(e => e.Pinned != selectedEntries[0].Pinned))
            {
                statusText.Text = "Move pinned and normal entries separately.";
                return;
            }

            if (!selectedEntries[0].Pinned)
            {
                var visibleOrder = entries.Where(e => !e.Pinned).Select(e => e.Id).ToList();
                store.SetManualOrder(visibleOrder);
                settings.SortMode = "Manual";
                saveSettings();
            }

            store.MoveEntries(selectedIds, direction);
            Reload();
            RestoreSelection(selectedIds);
            statusText.Text = direction < 0 ? "Moved selected entry or entries up." : "Moved selected entry or entries down.";
        }

        private string PinMenuText()
        {
            var selected = SelectedEntries();
            if (selected.Count == 0) return "Pin or unp&in\tShift+Enter";
            if (selected.All(e => e.Pinned)) return "Unp&in selected\tShift+Enter";
            if (selected.All(e => !e.Pinned)) return "P&in selected\tShift+Enter";
            return "Toggle p&inned state\tShift+Enter";
        }

        private string FilePinMenuText()
        {
            var selected = SelectedFileClipboardEvents();
            if (selected.Count == 0) return "Pin or unp&in\tShift+Enter";
            if (selected.All(e => e.Pinned)) return "Unp&in selected\tShift+Enter";
            if (selected.All(e => !e.Pinned)) return "P&in selected\tShift+Enter";
            return "Toggle p&inned state\tShift+Enter";
        }

        private void ViewSelectedText()
        {
            var selected = SelectedEntries();
            if (selected.Count == 0) return;
            var text = selected.Count == 1
                ? selected[0].Text
                : string.Join("\r\n\r\n----- Next clipboard entry -----\r\n\r\n", selected.Select(e => e.Text));
            var details = selected.Count == 1
                ? ClipboardEntryDetails(selected[0])
                : new List<KeyValuePair<string, string>>
                {
                    new KeyValuePair<string, string>("Selected entries", selected.Count.ToString(CultureInfo.InvariantCulture)),
                    new KeyValuePair<string, string>("Combined text length", text.Length.ToString(CultureInfo.InvariantCulture)),
                    new KeyValuePair<string, string>("Combined links", CountLinks(text).ToString(CultureInfo.InvariantCulture))
                };
            using (var viewer = new TextViewerForm(
                "Clipman Entry Text",
                text,
                "Clipboard entry text",
                "Read-only clipboard entry text.",
                false,
                details))
            {
                viewer.ShowDialog(this);
            }
        }

        private static List<KeyValuePair<string, string>> ClipboardEntryDetails(ClipEntry entry)
        {
            var details = new List<KeyValuePair<string, string>>();
            AddDetail(details, "Name", entry.Name);
            AddDetail(details, "Group", entry.Group);
            AddDetail(details, "Machine", entry.SourceMachine);
            details.Add(new KeyValuePair<string, string>("Pinned", entry.Pinned ? "Yes" : "No"));
            details.Add(new KeyValuePair<string, string>("Template", entry.IsTemplate ? "Yes" : "No"));
            if (entry.CreatedUnixMs > 0)
            {
                details.Add(new KeyValuePair<string, string>("Added", TimeUtil.FromUnixMs(entry.CreatedUnixMs).ToString("yyyy-MM-dd HH:mm:ss")));
            }
            if (entry.LastUsedUnixMs > 0)
            {
                details.Add(new KeyValuePair<string, string>("Last used", TimeUtil.FromUnixMs(entry.LastUsedUnixMs).ToString("yyyy-MM-dd HH:mm:ss")));
            }
            if (entry.ManualOrder > 0)
            {
                details.Add(new KeyValuePair<string, string>("Manual order", entry.ManualOrder.ToString(CultureInfo.InvariantCulture)));
            }
            details.Add(new KeyValuePair<string, string>("Text length", (entry.Text ?? string.Empty).Length.ToString(CultureInfo.InvariantCulture)));
            details.Add(new KeyValuePair<string, string>("Links", CountLinks(entry.Text).ToString(CultureInfo.InvariantCulture)));
            AddDetail(details, "Entry ID", entry.Id);
            return details;
        }

        private static void AddDetail(List<KeyValuePair<string, string>> details, string name, string value)
        {
            if (!string.IsNullOrWhiteSpace(value))
            {
                details.Add(new KeyValuePair<string, string>(name, value.Trim()));
            }
        }

        private static int CountLinks(string text)
        {
            if (string.IsNullOrWhiteSpace(text)) return 0;
            return Regex.Matches(text, @"https?://[^\s<>'""]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant).Count;
        }

        private void ShowSearchDialog(bool backwards)
        {
            using (var dialog = new SearchDialog(lastSearch))
            {
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                lastSearch = dialog.SearchText;
            }

            if (string.IsNullOrWhiteSpace(lastSearch)) return;
            FindSearchMatch(backwards);
        }

        private void RepeatSearch(bool backwards)
        {
            if (string.IsNullOrWhiteSpace(lastSearch))
            {
                ShowSearchDialog(backwards);
                return;
            }

            FindSearchMatch(backwards);
        }

        private void FindSearchMatch(bool backwards)
        {
            if (string.IsNullOrWhiteSpace(lastSearch)) return;
            if (IsFileClipboardTabActive())
            {
                SelectMainTab();
            }
            SaveSelectedTab();
            var current = list.SelectedIndices.Count > 0 ? list.SelectedIndices[0] : -1;
            var start = backwards ? current - 1 : current + 1;
            if (start < 0) start = list.Items.Count - 1;
            if (start >= list.Items.Count) start = 0;

            for (var step = 0; step < list.Items.Count; step++)
            {
                var index = backwards
                    ? (start - step + list.Items.Count) % list.Items.Count
                    : (start + step) % list.Items.Count;
                var entry = list.Items[index].Tag as ClipEntry;
                if (entry != null && EntryMatchesSearch(entry, lastSearch))
                {
                    SelectIndex(index);
                    statusText.Text = "Found " + (index + 1) + " of " + list.Items.Count + ". Search matches names and clipboard text.";
                    return;
                }
            }

            statusText.Text = "No clipboard entry name or text matches " + lastSearch + ".";
        }

        private void Import(bool replace)
        {
            using (var dialog = new OpenFileDialog())
            {
                dialog.Title = replace ? "Import and replace clipboard database" : "Import clipboard entries";
                dialog.Filter = "Supported clipboard databases and text files|*.clipdb;*.json;*.txt;*.db;*.sqlite;*.sqlite3|All files|*.*";
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                if (!ImportSelectedFile(dialog.FileName, replace)) return;
            }
        }

        private bool ImportSelectedFile(string fileName, bool replace)
        {
            try
            {
                store.ImportFromFile(fileName, replace);
                Reload();
                statusText.Text = replace ? "Imported replacement clipboard database." : "Imported clipboard entries.";
                return true;
            }
            catch (DatabasePasswordRequiredException)
            {
                var password = PasswordPromptForm.Ask(
                    "Clipman import password",
                    "The selected Clipman import file is encrypted. Enter its history password.");
                if (string.IsNullOrEmpty(password))
                {
                    statusText.Text = "Import cancelled. The selected file needs a history password.";
                    return false;
                }

                try
                {
                    store.ImportFromFile(fileName, replace, password);
                    Reload();
                    statusText.Text = replace ? "Imported replacement clipboard database." : "Imported clipboard entries.";
                    return true;
                }
                catch (DatabasePasswordRequiredException ex)
                {
                    MessageBox.Show(this, ex.Message, "Clipman import", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    statusText.Text = "Import failed. The history password did not unlock the selected file.";
                    return false;
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Clipman could not import the selected file.\r\n\r\n" + ex.Message, "Clipman import", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                statusText.Text = "Import failed.";
                return false;
            }
        }

        private void Export()
        {
            using (var dialog = new SaveFileDialog())
            {
                dialog.Title = "Export clipboard database";
                dialog.Filter = "Clipman compressed database|*.clipdb|Clipman JSON database|*.json|Text file|*.txt";
                dialog.FileName = "clipman-export.clipdb";
                if (dialog.ShowDialog(this) != DialogResult.OK) return;

                if (Path.GetExtension(dialog.FileName).Equals(".txt", StringComparison.OrdinalIgnoreCase))
                {
                    File.WriteAllText(dialog.FileName, string.Join("\r\n---\r\n", entries.Select(e => e.Text)), System.Text.Encoding.UTF8);
                }
                else if (Path.GetExtension(dialog.FileName).Equals(".clipdb", StringComparison.OrdinalIgnoreCase))
                {
                    bool useCurrentPassword;
                    string exportPassword;
                    if (!ExportPasswordForm.Ask(this, store.HasCurrentPassword(), store.CurrentPasswordMatches, out useCurrentPassword, out exportPassword))
                    {
                        statusText.Text = "Export cancelled.";
                        return;
                    }
                    store.ExportToFile(dialog.FileName, useCurrentPassword ? null : exportPassword);
                }
                else
                {
                    store.ExportToFile(dialog.FileName, string.Empty);
                }

                statusText.Text = "Exported clipboard entries.";
            }
        }

        private void UpdateMenuHotkeys()
        {
            var fileTabActive = IsFileClipboardTabActive();
            if (preferencesMenuItem != null)
            {
                preferencesMenuItem.Text = "&Preferences...\tCtrl+,";
            }
            if (toggleMenuItem != null)
            {
                toggleMenuItem.Text = "&Toggle on/off\t" + settings.ToggleActiveHotkey;
            }
            if (sortLastUsedMenuItem != null)
            {
                sortLastUsedMenuItem.Text = fileTabActive ? "&Time captured" : "&Last used";
                sortLastUsedMenuItem.Checked = fileTabActive ? IsFileSortMode("Time") : IsSortMode("LastUsed");
            }
            if (sortAddedMenuItem != null)
            {
                sortAddedMenuItem.Text = fileTabActive ? "&File count" : "&Added";
                sortAddedMenuItem.Checked = fileTabActive ? IsFileSortMode("Files") : IsSortMode("Added");
            }
            if (sortTextMenuItem != null)
            {
                sortTextMenuItem.Text = fileTabActive ? "&Name" : "&Text";
                sortTextMenuItem.Checked = fileTabActive ? IsFileSortMode("Name") : IsSortMode("Text");
            }
            if (sortGroupMenuItem != null)
            {
                sortGroupMenuItem.Text = fileTabActive ? "&Operation" : "&Group";
                sortGroupMenuItem.Checked = fileTabActive ? IsFileSortMode("Operation") : IsSortMode("Group");
            }
            if (sortMachineMenuItem != null)
            {
                sortMachineMenuItem.Text = fileTabActive ? "&Source application" : "Mac&hine";
                sortMachineMenuItem.Checked = fileTabActive ? IsFileSortMode("Source") : IsSortMode("Machine");
            }
            if (sortManualMenuItem != null) sortManualMenuItem.Checked = fileTabActive ? IsFileSortMode("Manual") : IsSortMode("Manual");
            if (sortDirectionMenuItem != null)
            {
                var descending = fileTabActive ? settings.FileHistorySortDescending : settings.SortDescending;
                sortDirectionMenuItem.Text = SortDirectionMenuText(fileTabActive, descending);
                sortDirectionMenuItem.Checked = descending;
            }
            if (sortMenuItem != null)
            {
                sortMenuItem.Text = fileTabActive ? "S&ort file history by" : "S&ort text history by";
            }
        }

        private string FileSortDirectionStatusText()
        {
            return SortDirectionStatusText(true);
        }

        private string SortDirectionStatusText(bool fileTabActive)
        {
            if (fileTabActive)
            {
                switch ((settings.FileHistorySortMode ?? "Manual").Trim().ToUpperInvariant())
                {
                    case "TIME":
                        return settings.FileHistorySortDescending ? "Sorted file history newest first." : "Sorted file history oldest first.";
                    case "FILES":
                        return settings.FileHistorySortDescending ? "Sorted file history most files first." : "Sorted file history fewest files first.";
                    case "NAME":
                    case "OPERATION":
                    case "SOURCE":
                        return settings.FileHistorySortDescending ? "Sorted file history Z first." : "Sorted file history A first.";
                    case "MANUAL":
                    default:
                        return settings.FileHistorySortDescending ? "Sorted file history bottom manual item first." : "Sorted file history top manual item first.";
                }
            }

            switch ((settings.SortMode ?? "LastUsed").Trim().ToUpperInvariant())
            {
                case "ADDED":
                case "LASTUSED":
                    return settings.SortDescending ? "Sorted text history newest first." : "Sorted text history oldest first.";
                case "TEXT":
                case "GROUP":
                case "MACHINE":
                    return settings.SortDescending ? "Sorted text history Z first." : "Sorted text history A first.";
                case "MANUAL":
                default:
                    return settings.SortDescending ? "Sorted text history bottom manual item first." : "Sorted text history top manual item first.";
            }
        }

        private string SortDirectionMenuText(bool fileTabActive, bool currentlyDescending)
        {
            if (fileTabActive)
            {
                switch ((settings.FileHistorySortMode ?? "Manual").Trim().ToUpperInvariant())
                {
                    case "TIME":
                        return currentlyDescending ? "Sort file history oldest &first" : "Sort file history newest &first";
                    case "FILES":
                        return currentlyDescending ? "Sort file history fewest files &first" : "Sort file history most files &first";
                    case "NAME":
                    case "OPERATION":
                    case "SOURCE":
                        return currentlyDescending ? "Sort file history A &first" : "Sort file history Z &first";
                    case "MANUAL":
                    default:
                        return currentlyDescending ? "Sort file history top manual item &first" : "Sort file history bottom manual item &first";
                }
            }

            switch ((settings.SortMode ?? "LastUsed").Trim().ToUpperInvariant())
            {
                case "ADDED":
                case "LASTUSED":
                    return currentlyDescending ? "Sort text history oldest &first" : "Sort text history newest &first";
                case "TEXT":
                case "GROUP":
                case "MACHINE":
                    return currentlyDescending ? "Sort text history A &first" : "Sort text history Z &first";
                case "MANUAL":
                default:
                    return currentlyDescending ? "Sort text history top manual item &first" : "Sort text history bottom manual item &first";
            }
        }

        private void OpenManual()
        {
            var manualPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Manual.html");
            if (!File.Exists(manualPath))
            {
                MessageBox.Show(this, "Manual.html was not found in the Clipman folder.", "Clipman Manual", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            try
            {
                Process.Start(manualPath);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Could not open the manual.\r\n\r\n" + ex.Message, "Clipman Manual", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private static string AppVersion()
        {
            var version = typeof(HistoryForm).Assembly.GetName().Version;
            return version == null ? "1.1.1" : version.Major + "." + version.Minor + "." + version.Build;
        }

        private void ShowDiagnostics()
        {
            var text = diagnosticsText == null ? "Diagnostics are not available." : diagnosticsText();
            using (var viewer = new TextViewerForm(
                "Clipman Diagnostics",
                text,
                "Clipman diagnostics",
                "Read-only Clipman diagnostics.",
                true))
            {
                viewer.ShowDialog(this);
            }
        }

        private void ShowAbout()
        {
            MessageBox.Show(
                this,
                "Clipman " + AppVersion() + "\r\n" +
                "Accessible clipboard management tool for Windows.\r\n\r\n" +
                "Build: " + BuildTimestampText() + "\r\n" +
                "Build stamp: " + BuildInfo.BuildStampUtcMs + "\r\n\r\n" +
                "Built for fast keyboard and screen-reader use.\r\n\r\n" +
                "Created by Andre Louis with Codex.\r\n" +
                "Based on earlier Clipman work by Tyler Spivey.\r\n" +
                "SQLite support uses the public-domain SQLite runtime.",
                "About Clipman",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
        }

        private static string BuildTimestampText()
        {
            try
            {
                var epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
                return epoch.AddMilliseconds(BuildInfo.BuildStampUtcMs).ToString("yyyy-MM-dd HH:mm:ss 'UTC'");
            }
            catch
            {
                return "unknown";
            }
        }

        private void ShowHistoryContextMenu()
        {
            if (historyContextMenu == null) return;
            PopulateContextMenu(historyContextMenu);
            var item = list.SelectedItems.Count > 0 ? list.SelectedItems[0] : null;
            var location = item == null
                ? new Point(10, 10)
                : new Point(Math.Max(0, item.Bounds.Left + 8), item.Bounds.Bottom);
            historyContextMenu.Show(list, location);
        }

        private void OpenSettingsFolder()
        {
            try
            {
                var folder = SettingsFolderFromDatabasePath(settings.DatabasePath);
                Directory.CreateDirectory(folder);
                Process.Start(new ProcessStartInfo
                {
                    FileName = folder,
                    UseShellExecute = true
                });
            }
            catch (Exception ex)
            {
                MessageBox.Show("Clipman could not open the settings folder.\r\n\r\n" + ex.Message, "Clipman", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        private static string SettingsFolderFromDatabasePath(string databasePath)
        {
            if (!string.IsNullOrWhiteSpace(databasePath))
            {
                var folder = Path.GetDirectoryName(databasePath);
                if (!string.IsNullOrWhiteSpace(folder)) return folder;
            }

            return Path.Combine(AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar), "Settings");
        }

        private void ShowFileEventsContextMenu()
        {
            if (fileEventsContextMenu == null) return;
            PopulateFileEventsContextMenu(fileEventsContextMenu);
            var item = fileEventsList.SelectedItems.Count > 0 ? fileEventsList.SelectedItems[0] : null;
            var location = item == null
                ? new Point(10, 10)
                : new Point(Math.Max(0, item.Bounds.Left + 8), item.Bounds.Bottom);
            fileEventsContextMenu.Show(fileEventsList, location);
        }

        private bool IsFileClipboardTabActive()
        {
            return tabs != null && tabs.SelectedTab == fileTab;
        }

        private bool IsLinksHistoryTabActive()
        {
            return tabs != null && tabs.SelectedTab == linksTab;
        }

        private string CurrentHistoryTab()
        {
            if (tabs == null) return HistoryTabs.Text;
            if (tabs.SelectedTab == fileTab) return HistoryTabs.Files;
            if (tabs.SelectedTab == linksTab) return HistoryTabs.Links;
            return HistoryTabs.Text;
        }

        private void RebuildHistoryTabs()
        {
            if (tabs == null) return;
            var selected = HistoryTabs.Normalize(settings.LastSelectedHistoryTab, settings.LinksHistoryEnabled);
            tabs.TabPages.Clear();
            tabs.TabPages.Add(textTab);
            if (settings.LinksHistoryEnabled)
            {
                tabs.TabPages.Add(linksTab);
            }
            tabs.TabPages.Add(fileTab);
            SelectHistoryTab(selected, false);
            AttachTextControlsToActiveTextTab();
            tabs.AccessibleDescription = string.Empty;
        }

        private void AttachTextControlsToActiveTextTab()
        {
            if (list == null || filterPanel == null) return;
            var target = IsLinksHistoryTabActive() ? linksTab : textTab;
            if (list.Parent != target)
            {
                target.Controls.Add(list);
            }
            if (filterPanel.Parent != target)
            {
                target.Controls.Add(filterPanel);
            }
            filterPanel.BringToFront();
            list.BringToFront();
            UpdateTextListAccessibility();
        }

        private void UpdateTextListAccessibility()
        {
            if (list == null) return;
            if (IsLinksHistoryTabActive())
            {
                list.AccessibleName = "Links history";
                list.AccessibleDescription = "HTTP and HTTPS link clipboard entries. Press Enter to copy the selected link entry to the clipboard.";
            }
            else
            {
                list.AccessibleName = "Text history";
                list.AccessibleDescription = "Text clipboard entries. Press Enter to copy the selected entry to the clipboard.";
            }
        }

        private void SelectHistoryTab(string tabId, bool focus)
        {
            if (tabs == null || tabs.TabPages.Count == 0) return;
            var normalized = HistoryTabs.Normalize(tabId, settings.LinksHistoryEnabled);
            var target = normalized == HistoryTabs.Files
                ? fileTab
                : normalized == HistoryTabs.Links && settings.LinksHistoryEnabled ? linksTab : textTab;
            if (!tabs.TabPages.Contains(target))
            {
                target = textTab;
            }
            tabs.SelectedTab = target;
            AttachTextControlsToActiveTextTab();
            if (focus)
            {
                if (target == fileTab)
                {
                    FocusFileClipboardListNow();
                }
                else
                {
                    FocusHistoryListNow();
                }
            }
        }

        private void SelectMainTab()
        {
            if (tabs == null || tabs.TabPages.Count == 0) return;
            SelectHistoryTab(HistoryTabs.Text, false);
            FocusHistoryListNow();
            statusText.Text = "Text history tab.";
        }

        private void SelectLinksTab()
        {
            if (!settings.LinksHistoryEnabled)
            {
                statusText.Text = "Links history tab is disabled in Preferences.";
                return;
            }
            SelectHistoryTab(HistoryTabs.Links, false);
            FocusHistoryListNow();
            statusText.Text = "Links history tab.";
        }

        private void SelectFileClipboardTab()
        {
            if (tabs == null || tabs.TabPages.Count < 1) return;
            SelectHistoryTab(HistoryTabs.Files, false);
            FocusFileClipboardListNow();
            statusText.Text = "File history tab.";
        }

        private void FocusHistoryTabControlNow()
        {
            if (!Visible || tabs == null) return;
            ActiveControl = tabs;
            tabs.Select();
            tabs.Focus();
        }

        private void FocusFileClipboardListNow()
        {
            if (fileEventsList.Items.Count > 0 && fileEventsList.SelectedItems.Count == 0)
            {
                fileEventsList.Items[0].Selected = true;
                fileEventsList.Items[0].Focused = true;
                fileEventsList.Items[0].EnsureVisible();
            }
            ActiveControl = fileEventsList;
            fileEventsList.Select();
            fileEventsList.Focus();
        }

        private void SelectNextTab(bool forward)
        {
            if (tabs == null || tabs.TabPages.Count == 0) return;
            var next = tabs.SelectedIndex + (forward ? 1 : -1);
            if (next < 0) next = tabs.TabPages.Count - 1;
            if (next >= tabs.TabPages.Count) next = 0;
            var nextTab = tabs.TabPages[next];
            if (nextTab == fileTab)
            {
                SelectFileClipboardTab();
            }
            else if (nextTab == linksTab)
            {
                SelectLinksTab();
            }
            else
            {
                SelectMainTab();
            }
        }

        private void SaveSelectedTab()
        {
            if (tabs == null) return;
            var selected = CurrentHistoryTab();
            var legacySelected = selected == HistoryTabs.Files ? 1 : 0;
            if (string.Equals(settings.LastSelectedHistoryTab, selected, StringComparison.OrdinalIgnoreCase) &&
                settings.LastSelectedTab == legacySelected) return;
            settings.LastSelectedHistoryTab = selected;
            settings.LastSelectedTab = legacySelected;
            saveSettings();
        }

        private void FocusGroupFilter()
        {
            if (tabs == null || groupFilter == null) return;
            SelectHistoryTab(IsLinksHistoryTabActive() ? HistoryTabs.Links : HistoryTabs.Text, false);
            ActiveControl = groupFilter;
            groupFilter.Select();
            groupFilter.Focus();
            statusText.Text = "Group filter.";
        }

        private void SelectIndex(int index)
        {
            if (index < 0 || index >= list.Items.Count) return;
            list.SelectedItems.Clear();
            foreach (ListViewItem item in list.Items)
            {
                item.Focused = false;
            }
            list.Items[index].Selected = true;
            list.Items[index].Focused = true;
            list.Items[index].EnsureVisible();
            list.Focus();
        }

        private int DefaultHistoryIndex()
        {
            return NormalizeSelectableIndex(0);
        }

        private void SelectDefaultHistoryIndex()
        {
            SelectIndex(DefaultHistoryIndex());
        }

        private void FocusHistoryListNow()
        {
            if (!Visible) return;
            AttachTextControlsToActiveTextTab();
            if (list.Items.Count > 0 && list.SelectedItems.Count == 0)
            {
                SelectIndex(NormalizeSelectableIndex(0));
            }
            ActiveControl = list;
            list.Select();
            list.Focus();
            if (list.SelectedItems.Count > 0)
            {
                list.SelectedItems[0].Selected = true;
                list.SelectedItems[0].Focused = true;
                list.SelectedItems[0].EnsureVisible();
            }
        }

        private void FocusActiveTabNow()
        {
            if (!Visible) return;
            if (IsFileClipboardTabActive())
            {
                FocusFileClipboardListNow();
                return;
            }

            FocusHistoryListNow();
        }

        private void BeginDelayedFocus(int intervalMs)
        {
            var timer = new Timer();
            timer.Interval = intervalMs;
            timer.Tick += (s, e) =>
            {
                timer.Stop();
                timer.Dispose();
                FocusActiveTabNow();
            };
            timer.Start();
        }

        private void TypeSearchClipboardText(char character)
        {
            var now = DateTime.UtcNow;
            if ((now - lastTypeSearchUtc).TotalMilliseconds > 1200)
            {
                typeSearchBuffer = string.Empty;
            }
            lastTypeSearchUtc = now;

            typeSearchBuffer += character;
            if (typeSearchBuffer.StartsWith("/", StringComparison.Ordinal))
            {
                if (FindNamedEntry(typeSearchBuffer.Substring(1)))
                {
                    statusText.Text = "Jumped to named clipboard entry " + typeSearchBuffer + ".";
                    return;
                }
            }
            if (FindClipboardTextStartingWith(typeSearchBuffer, typeSearchBuffer.Length == 1))
            {
                statusText.Text = "Jumped to clipboard text starting with " + typeSearchBuffer + ".";
                return;
            }

            statusText.Text = "No clipboard text starts with " + typeSearchBuffer + ".";
        }

        private void TypeSearchFileHistory(char character)
        {
            var now = DateTime.UtcNow;
            if ((now - lastFileTypeSearchUtc).TotalMilliseconds > 1200)
            {
                fileTypeSearchBuffer = string.Empty;
            }
            lastFileTypeSearchUtc = now;

            fileTypeSearchBuffer += character;
            if (FindFileHistoryStartingWith(fileTypeSearchBuffer, fileTypeSearchBuffer.Length == 1))
            {
                statusText.Text = "Jumped to file-history item starting with " + fileTypeSearchBuffer + ".";
                return;
            }

            statusText.Text = "No file-history item starts with " + fileTypeSearchBuffer + ".";
        }

        private bool FindNamedEntry(string namePrefix)
        {
            if (string.IsNullOrWhiteSpace(namePrefix)) return false;
            for (var i = 0; i < list.Items.Count; i++)
            {
                var entry = list.Items[i].Tag as ClipEntry;
                if (entry == null || string.IsNullOrWhiteSpace(entry.Name)) continue;
                if (entry.Name.Trim().StartsWith(namePrefix, StringComparison.CurrentCultureIgnoreCase))
                {
                    SelectIndex(i);
                    return true;
                }
            }
            return false;
        }

        private bool FindClipboardTextStartingWith(string prefix, bool startAfterCurrent)
        {
            if (string.IsNullOrEmpty(prefix)) return false;
            var start = list.SelectedIndices.Count > 0
                ? list.SelectedIndices[0] + (startAfterCurrent ? 1 : 0)
                : 0;
            for (var pass = 0; pass < 2; pass++)
            {
                var from = pass == 0 ? start : 0;
                var to = pass == 0 ? list.Items.Count : Math.Min(start, list.Items.Count);
                for (var i = from; i < to; i++)
                {
                    var entry = list.Items[i].Tag as ClipEntry;
                    if (entry == null || string.IsNullOrEmpty(entry.Text)) continue;
                    var text = entry.Text.TrimStart();
                    if (text.Length == 0) continue;
                    if (text.StartsWith(prefix, StringComparison.CurrentCultureIgnoreCase))
                    {
                        SelectIndex(i);
                        return true;
                    }
                }
            }
            return false;
        }

        private bool FindFileHistoryStartingWith(string prefix, bool startAfterCurrent)
        {
            if (string.IsNullOrEmpty(prefix) || fileEventsList == null || fileEventsList.Items.Count == 0) return false;
            var start = fileEventsList.SelectedIndices.Count > 0
                ? fileEventsList.SelectedIndices[0] + (startAfterCurrent ? 1 : 0)
                : 0;
            for (var pass = 0; pass < 2; pass++)
            {
                var from = pass == 0 ? start : 0;
                var to = pass == 0 ? fileEventsList.Items.Count : Math.Min(start, fileEventsList.Items.Count);
                for (var i = from; i < to; i++)
                {
                    var item = fileEventsList.Items[i].Tag as ClipboardEventSummary;
                    if (item == null) continue;
                    var searchText = FileEventSearchText(item);
                    if (searchText.Length == 0) continue;
                    if (searchText.StartsWith(prefix, StringComparison.CurrentCultureIgnoreCase))
                    {
                        SelectFileIndex(i);
                        return true;
                    }
                }
            }
            return false;
        }

        private static string FileEventSearchText(ClipboardEventSummary item)
        {
            var name = FileEventPrimaryName(item);
            if (!string.IsNullOrWhiteSpace(name)) return name.TrimStart();
            return FileEventDisplayText(item).TrimStart();
        }

        private static bool EntryMatchesSearch(ClipEntry entry, string searchText)
        {
            if (entry == null || string.IsNullOrEmpty(searchText)) return false;
            if ((entry.Text ?? string.Empty).IndexOf(searchText, StringComparison.CurrentCultureIgnoreCase) >= 0) return true;
            return (entry.Name ?? string.Empty).IndexOf(searchText, StringComparison.CurrentCultureIgnoreCase) >= 0;
        }

        private static string DisplayText(ClipEntry entry)
        {
            if (entry == null) return string.Empty;
            var text = Summarize(entry.Text);
            var name = (entry.Name ?? string.Empty).Trim();
            return name.Length == 0 ? text : name + ": " + text;
        }

        private static string NumberedPinnedDisplayText(string text, int zeroBasedPosition)
        {
            if (zeroBasedPosition < 0 || zeroBasedPosition > 9) return text ?? string.Empty;
            return ShortcutDisplayNumber(zeroBasedPosition) + ". " + (text ?? string.Empty);
        }

        private static string Summarize(string text)
        {
            if (string.IsNullOrEmpty(text)) return string.Empty;
            var oneLine = text.Replace("\r", " ").Replace("\n", " ").Replace("\t", " ");
            while (oneLine.Contains("  ")) oneLine = oneLine.Replace("  ", " ");
            return oneLine.Length > 240 ? oneLine.Substring(0, 240) : oneLine;
        }

        private static string TrimText(string text)
        {
            return (text ?? string.Empty).Trim();
        }

        private static string SingleLineText(string text)
        {
            var oneLine = (text ?? string.Empty).Replace("\r", " ").Replace("\n", " ").Replace("\t", " ");
            while (oneLine.Contains("  ")) oneLine = oneLine.Replace("  ", " ");
            return oneLine.Trim();
        }

        private static string RemoveBlankLines(string text)
        {
            return string.Join("\r\n", (text ?? string.Empty)
                .Replace("\r\n", "\n")
                .Replace("\r", "\n")
                .Split('\n')
                .Where(line => line.Trim().Length > 0));
        }

        private static string HtmlToText(string text)
        {
            var value = text ?? string.Empty;
            value = Regex.Replace(value, @"(?is)<(script|style|head|noscript)\b[^>]*>.*?</\1>", " ");
            value = Regex.Replace(value, @"(?i)<\s*br\s*/?\s*>", "\r\n");
            value = Regex.Replace(value, @"(?i)</\s*(p|div|h[1-6]|li|tr|table|section|article|header|footer|blockquote)\s*>", "\r\n");
            value = Regex.Replace(value, @"<[^>]+>", " ");
            value = System.Net.WebUtility.HtmlDecode(value);
            value = Regex.Replace(value, @"[ \t\f\v]+", " ");
            value = Regex.Replace(value, @" *\r?\n *", "\r\n");
            value = Regex.Replace(value, @"(\r\n){3,}", "\r\n\r\n");
            return value.Trim();
        }

        private static string UrlEncode(string text)
        {
            return Uri.EscapeDataString(text ?? string.Empty);
        }
    }
}
