using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Diagnostics;
using System.Drawing;
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
        private readonly Action<ClipEntry> copyEntry;
        private readonly Action<List<ClipEntry>> copyEntries;
        private readonly Func<List<ClipboardEventSummary>> recentClipboardEvents;
        private readonly Action showPreferences;
        private readonly Action toggleActive;
        private readonly Action exitApp;
        private readonly Func<string> diagnosticsText;
        private readonly TabControl tabs;
        private readonly ListView list;
        private readonly ListView fileEventsList;
        private readonly ComboBox groupFilter;
        private MenuStrip menuStrip;
        private readonly StatusStrip status;
        private readonly ToolStripStatusLabel statusText;
        private readonly ContextMenuStrip historyContextMenu;
        private readonly ContextMenuStrip fileEventsContextMenu;
        private ToolStripMenuItem preferencesMenuItem;
        private ToolStripMenuItem optionsMenuItem;
        private ToolStripMenuItem toggleMenuItem;
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
        private bool updatingGroupFilter;

        public HistoryForm(ClipStore store, AppSettings settings, Action saveSettings, Action<ClipEntry> copyEntry, Action<List<ClipEntry>> copyEntries, Func<List<ClipboardEventSummary>> recentClipboardEvents, Action showPreferences, Action toggleActive, Action exitApp, Func<string> diagnosticsText)
        {
            this.store = store;
            this.settings = settings;
            this.saveSettings = saveSettings;
            this.copyEntry = copyEntry;
            this.copyEntries = copyEntries;
            this.recentClipboardEvents = recentClipboardEvents;
            this.showPreferences = showPreferences;
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
                AccessibleName = "Clipman sections",
                AccessibleDescription = "Text clipboard history and file clipboard history."
            };
            var mainTab = new TabPage("Text history");
            var fileTab = new TabPage("File history");

            var filterPanel = new FlowLayoutPanel
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

            list = new ListView
            {
                Dock = DockStyle.Fill,
                View = View.Details,
                FullRowSelect = true,
                HideSelection = false,
                MultiSelect = true,
                AccessibleName = "Clipboard history",
                AccessibleDescription = "Clipboard entries. Press Enter to copy the selected entry to the clipboard.",
                TabIndex = 0
            };
            list.Columns.Add("Item", 620);
            list.Columns.Add("Group", 130);
            list.Columns.Add("Machine", 120);
            list.Columns.Add("Last used", 170);
            list.Columns.Add("Added", 170);
            list.Columns.Add("Pinned", 70);
            list.KeyDown += ListKeyDown;
            list.KeyPress += ListKeyPress;
            list.DoubleClick += (s, e) => CopySelected();
            historyContextMenu = BuildContextMenu();
            list.ContextMenuStrip = historyContextMenu;
            mainTab.Controls.Add(list);
            mainTab.Controls.Add(filterPanel);

            fileEventsList = new ListView
            {
                Dock = DockStyle.Fill,
                View = View.Details,
                FullRowSelect = true,
                HideSelection = false,
                MultiSelect = false,
                AccessibleName = "File history",
                AccessibleDescription = "Recent file and non-text clipboard events. Press Enter on a file event to put its files back on the clipboard."
            };
            fileEventsList.Columns.Add("Event", 420);
            fileEventsList.Columns.Add("Source", 120);
            fileEventsList.Columns.Add("Operation", 90);
            fileEventsList.Columns.Add("Files", 70);
            fileEventsList.Columns.Add("Time", 150);
            fileEventsList.KeyDown += FileEventsListKeyDown;
            fileEventsList.DoubleClick += (s, e) => RestoreSelectedFileClipboardEvent();
            fileEventsContextMenu = BuildFileEventsContextMenu();
            fileEventsList.ContextMenuStrip = fileEventsContextMenu;
            fileTab.Controls.Add(fileEventsList);

            tabs.TabPages.Add(mainTab);
            tabs.TabPages.Add(fileTab);
            tabs.SelectedIndex = NormalizeTabIndex(settings.LastSelectedTab);
            tabs.SelectedIndexChanged += (s, e) => SaveSelectedTab();
            Controls.Add(tabs);

            statusText = new ToolStripStatusLabel("Ready");
            status = new StatusStrip();
            status.Items.Add(statusText);
            Controls.Add(status);

            RefreshGroupFilterItems();
            RefreshFileClipboardEvents();
            Reload();
        }

        public void Reload()
        {
            Reload(null, -1);
        }

        public void RefreshFileClipboardEvents()
        {
            if (fileEventsList == null) return;
            var events = recentClipboardEvents == null ? new List<ClipboardEventSummary>() : recentClipboardEvents() ?? new List<ClipboardEventSummary>();
            var selectedIndex = fileEventsList.SelectedIndices.Count > 0 ? fileEventsList.SelectedIndices[0] : -1;
            fileEventsList.BeginUpdate();
            fileEventsList.Items.Clear();
            foreach (var item in events)
            {
                NormalizeFileClipboardEvent(item);
                var text = FileEventDisplayText(item);
                var row = new ListViewItem(text);
                row.SubItems.Add(item.Source ?? string.Empty);
                row.SubItems.Add(NormalizeDropEffectText(item.Operation));
                row.SubItems.Add(item.FileCount > 0 ? item.FileCount.ToString() : string.Empty);
                row.SubItems.Add(item.CapturedAt.ToString("yyyy-MM-dd HH:mm:ss"));
                row.Tag = item;
                fileEventsList.Items.Add(row);
            }
            fileEventsList.EndUpdate();
            if (fileEventsList.Items.Count > 0)
            {
                if (selectedIndex < 0 || selectedIndex >= fileEventsList.Items.Count) selectedIndex = 0;
                fileEventsList.Items[selectedIndex].Selected = true;
                fileEventsList.Items[selectedIndex].Focused = true;
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
            entries = store.GetEntries(settings.SortMode, settings.GroupFilter, settings.SortDescending);
            list.BeginUpdate();
            list.Items.Clear();
            var insertedSeparator = false;
            foreach (var entry in entries)
            {
                if (!entry.Pinned && !insertedSeparator && entries.Any(e => e.Pinned))
                {
                    var separator = new ListViewItem("----- Normal entries -----");
                    separator.SubItems.Add(string.Empty);
                    separator.SubItems.Add(string.Empty);
                    separator.SubItems.Add(string.Empty);
                    separator.SubItems.Add(string.Empty);
                    separator.SubItems.Add(string.Empty);
                    separator.Tag = null;
                    separator.ForeColor = SystemColors.GrayText;
                    list.Items.Add(separator);
                    insertedSeparator = true;
                }

                var item = new ListViewItem(DisplayText(entry));
                item.SubItems.Add(entry.Group ?? string.Empty);
                item.SubItems.Add(entry.SourceMachine ?? string.Empty);
                item.SubItems.Add(TimeUtil.FromUnixMs(entry.LastUsedUnixMs).ToString("yyyy-MM-dd HH:mm:ss"));
                item.SubItems.Add(TimeUtil.FromUnixMs(entry.CreatedUnixMs).ToString("yyyy-MM-dd HH:mm:ss"));
                item.SubItems.Add(entry.Pinned ? "Yes" : string.Empty);
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
            if (index < 0 || index >= list.Items.Count)
            {
                index = list.Items.Count - 1;
            }
            index = NormalizeSelectableIndex(index);
            SelectIndex(index);
            statusText.Text = entries.Count + " clipboard entries.";
        }

        public void FocusHistoryList()
        {
            FocusHistoryList(false);
        }

        public void FocusHistoryList(bool firstShow)
        {
            BeginInvoke(new Action(() =>
            {
                FocusActiveTabNow();
                BeginDelayedFocus(100);
                BeginDelayedFocus(300);
                BeginDelayedFocus(firstShow ? 900 : 500);
            }));
        }

        private MenuStrip BuildMenu()
        {
            var menu = new MenuStrip();
            menuStrip = menu;
            menu.MenuDeactivate += (s, e) => BeginDelayedFocus(80);

            var file = new ToolStripMenuItem("&File");
            file.DropDownItems.Add("&Import...", null, (s, e) => Import(false));
            file.DropDownItems.Add("Import and &replace...", null, (s, e) => Import(true));
            file.DropDownItems.Add("&Export...", null, (s, e) => Export());
            file.DropDownItems.Add("-");
            file.DropDownItems.Add("&Close\tEsc", null, (s, e) => CloseHistoryWindow());
            file.DropDownItems.Add("E&xit", null, (s, e) => exitApp());

            var edit = new ToolStripMenuItem("&Edit");
            edit.DropDownOpening += (s, e) => PopulateEditMenu(edit);
            PopulateEditMenu(edit);

            var actions = new ToolStripMenuItem("&Actions");
            actions.DropDownItems.Add("Copy as plain &text\tCtrl+Shift+C", null, (s, e) => CopySelectedPlainText(false));
            actions.DropDownItems.Add("&Trim leading and trailing whitespace\tCtrl+Shift+T", null, (s, e) => TransformSelected(TrimText, "Trimmed selected entry or entries."));
            actions.DropDownItems.Add("Convert to &single line\tCtrl+Shift+L", null, (s, e) => TransformSelected(SingleLineText, "Converted selected entry or entries to single line."));
            actions.DropDownItems.Add("Remove &blank lines\tCtrl+Shift+B", null, (s, e) => TransformSelected(RemoveBlankLines, "Removed blank lines from selected entry or entries."));
            actions.DropDownItems.Add("Remove URL t&racking\tCtrl+Shift+R", null, (s, e) => TransformSelected(UrlTrackingCleaner.CleanText, "Removed URL tracking from selected entry or entries."));
            actions.DropDownItems.Add("&Uppercase", null, (s, e) => TransformSelected(t => (t ?? string.Empty).ToUpperInvariant(), "Uppercased selected entry or entries."));
            actions.DropDownItems.Add("&Lowercase", null, (s, e) => TransformSelected(t => (t ?? string.Empty).ToLowerInvariant(), "Lowercased selected entry or entries."));
            actions.DropDownItems.Add("HTML &encode", null, (s, e) => TransformSelected(System.Net.WebUtility.HtmlEncode, "HTML-encoded selected entry or entries."));
            actions.DropDownItems.Add("&HTML decode", null, (s, e) => TransformSelected(System.Net.WebUtility.HtmlDecode, "HTML-decoded selected entry or entries."));
            actions.DropDownItems.Add("HTML to readable te&xt\tCtrl+Shift+H", null, (s, e) => TransformSelected(HtmlToText, "Converted selected HTML entry or entries to readable text."));
            actions.DropDownItems.Add("&URL encode\tCtrl+Shift+U", null, (s, e) => TransformSelected(UrlEncode, "URL-encoded selected entry or entries."));
            actions.DropDownItems.Add("U&RL decode", null, (s, e) => TransformSelected(Uri.UnescapeDataString, "URL-decoded selected entry or entries."));
            actions.DropDownOpening += (s, e) => SetMenuItemsEnabled(actions, !IsFileClipboardTabActive());

            var options = new ToolStripMenuItem("&Options");
            optionsMenuItem = options;
            preferencesMenuItem = new ToolStripMenuItem("&Preferences...\tCtrl+,", null, (s, e) => showPreferences());
            toggleMenuItem = new ToolStripMenuItem("&Toggle on/off", null, (s, e) => toggleActive());
            options.DropDownItems.Add(preferencesMenuItem);
            options.DropDownItems.Add(toggleMenuItem);

            var view = new ToolStripMenuItem("&View");
            sortLastUsedMenuItem = new ToolStripMenuItem("Sort by &last used", null, (s, e) => SetSortMode("LastUsed"));
            sortAddedMenuItem = new ToolStripMenuItem("Sort by &added", null, (s, e) => SetSortMode("Added"));
            sortTextMenuItem = new ToolStripMenuItem("Sort by &text", null, (s, e) => SetSortMode("Text"));
            sortGroupMenuItem = new ToolStripMenuItem("Sort by &group", null, (s, e) => SetSortMode("Group"));
            sortMachineMenuItem = new ToolStripMenuItem("Sort by &machine", null, (s, e) => SetSortMode("Machine"));
            sortManualMenuItem = new ToolStripMenuItem("&Manual order", null, (s, e) => SetSortMode("Manual"));
            sortDirectionMenuItem = new ToolStripMenuItem("", null, (s, e) => ToggleSortDirection());
            view.DropDownItems.Add(sortLastUsedMenuItem);
            view.DropDownItems.Add(sortAddedMenuItem);
            view.DropDownItems.Add(sortTextMenuItem);
            view.DropDownItems.Add(sortGroupMenuItem);
            view.DropDownItems.Add(sortMachineMenuItem);
            view.DropDownItems.Add(sortManualMenuItem);
            view.DropDownItems.Add("-");
            view.DropDownItems.Add(sortDirectionMenuItem);
            view.DropDownItems.Add("-");
            view.DropDownItems.Add("Move &up\tAlt+Up", null, (s, e) => MoveSelected(-1));
            view.DropDownItems.Add("Move &down\tAlt+Down", null, (s, e) => MoveSelected(1));
            view.DropDownOpening += (s, e) => SetMenuItemsEnabled(view, !IsFileClipboardTabActive());

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
            menu.Items.Add(actions);
            menu.Items.Add(view);
            menu.Items.Add(options);
            menu.Items.Add(help);
            UpdateMenuHotkeys();
            return menu;
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
                var item = SelectedFileClipboardEvent();
                var hasFiles = item != null && item.Files != null && item.Files.Count > 0;
                var restore = edit.DropDownItems.Add("&Restore files to clipboard\tEnter", null, (s, e) => RestoreSelectedFileClipboardEvent());
                restore.Enabled = hasFiles;
                var copyPaths = edit.DropDownItems.Add("&Copy file paths\tCtrl+C", null, (s, e) => CopySelectedFileClipboardPaths());
                copyPaths.Enabled = hasFiles;
                var details = edit.DropDownItems.Add("&View event details\tF4", null, (s, e) => ViewSelectedFileClipboardEvent());
                details.Enabled = item != null;
                return;
            }

            edit.DropDownItems.Add("&Copy and close\tEnter", null, (s, e) => CopySelected());
            edit.DropDownItems.Add("&Copy\tCtrl+C", null, (s, e) => CopySelected(false));
            edit.DropDownItems.Add("Cu&t\tCtrl+X", null, (s, e) => CutSelected());
            edit.DropDownItems.Add("&Paste after selected\tCtrl+V", null, (s, e) => PasteAfterSelected());
            edit.DropDownItems.Add("&Edit entry...\tF2", null, (s, e) => NameSelectedEntry());
            groupEntryMenuItem = new ToolStripMenuItem("&Group entry...\tCtrl+G", null, (s, e) => GroupSelectedEntries());
            edit.DropDownItems.Add(groupEntryMenuItem);
            edit.DropDownItems.Add("Entry &properties...\tAlt+Enter", null, (s, e) => ShowEntryProperties());
            edit.DropDownItems.Add("&View full text\tF4", null, (s, e) => ViewSelectedText());
            edit.DropDownItems.Add("Pin or &unpin\tShift+Enter", null, (s, e) => TogglePinned());
            edit.DropDownItems.Add("&Delete selected\tDel", null, (s, e) => DeleteSelected());
            edit.DropDownItems.Add("&Find...\tCtrl+F", null, (s, e) => ShowSearchDialog(false));
            edit.DropDownItems.Add("Find &next\tF3", null, (s, e) => RepeatSearch(false));
            edit.DropDownItems.Add("Find &previous\tShift+F3", null, (s, e) => RepeatSearch(true));
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
            menu.Items.Add("&Copy and close\tEnter", null, (sender, args) => CopySelected());
            menu.Items.Add("&Copy\tCtrl+C", null, (sender, args) => CopySelected(false));
            menu.Items.Add("Cu&t\tCtrl+X", null, (sender, args) => CutSelected());
            menu.Items.Add("&Paste after selected\tCtrl+V", null, (sender, args) => PasteAfterSelected());
            menu.Items.Add("&Edit entry...\tF2", null, (sender, args) => NameSelectedEntry());
            menu.Items.Add("&Group entry...\tCtrl+G", null, (sender, args) => GroupSelectedEntries());
            menu.Items.Add("Entry &properties...\tAlt+Enter", null, (sender, args) => ShowEntryProperties());
            menu.Items.Add("&View full text\tF4", null, (sender, args) => ViewSelectedText());
            menu.Items.Add(PinMenuText(), null, (sender, args) => TogglePinned());
            menu.Items.Add("&Delete selected\tDel", null, (sender, args) => DeleteSelected());
            menu.Items.Add("&Find...\tCtrl+F", null, (sender, args) => ShowSearchDialog(false));
            menu.Items.Add("Find &next\tF3", null, (sender, args) => RepeatSearch(false));
            menu.Items.Add("Find &previous\tShift+F3", null, (sender, args) => RepeatSearch(true));
        }

        private void PopulateFileEventsContextMenu(ContextMenuStrip menu)
        {
            var item = SelectedFileClipboardEvent();
            var hasFiles = item != null && item.Files != null && item.Files.Count > 0;

            menu.Items.Clear();
            var restore = menu.Items.Add("&Restore files to clipboard\tEnter", null, (sender, args) => RestoreSelectedFileClipboardEvent());
            restore.Enabled = hasFiles;
            var copyPaths = menu.Items.Add("&Copy file paths\tCtrl+C", null, (sender, args) => CopySelectedFileClipboardPaths());
            copyPaths.Enabled = hasFiles;
            var details = menu.Items.Add("&View event details\tF4", null, (sender, args) => ViewSelectedFileClipboardEvent());
            details.Enabled = item != null;
        }

        private void ListKeyDown(object sender, KeyEventArgs e)
        {
            if (e.Alt && e.KeyCode == Keys.O)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                OpenOptionsMenu();
            }
            else if (e.Alt && e.KeyCode == Keys.Enter)
            {
                e.Handled = true;
                ShowEntryProperties();
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
                NameSelectedEntry();
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
                JumpToGroupByPosition(e.KeyCode - Keys.D1);
            }
            else if (e.Alt && e.KeyCode == Keys.D0)
            {
                e.Handled = true;
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

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.Alt && e.KeyCode == Keys.O)
            {
                OpenOptionsMenu();
                e.Handled = true;
                e.SuppressKeyPress = true;
                return;
            }
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
                if (key == Keys.Tab)
                {
                    SelectNextTab((keyData & Keys.Shift) != Keys.Shift);
                    return true;
                }
            }

            if ((keyData & Keys.Alt) == Keys.Alt)
            {
                var key = keyData & Keys.KeyCode;
                if (key == Keys.O)
                {
                    OpenOptionsMenu();
                    return true;
                }
                if (key == Keys.T)
                {
                    SelectMainTab();
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
            Hide();
        }

        private void OpenOptionsMenu()
        {
            if (optionsMenuItem == null) return;
            menuStrip.Focus();
            menuStrip.Select();
            optionsMenuItem.Select();
            optionsMenuItem.ShowDropDown();
            statusText.Text = "Options menu.";
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

        private void SetSortMode(string sortMode)
        {
            settings.SortMode = sortMode;
            saveSettings();
            Reload();
            statusText.Text = "Sorted clipboard history.";
        }

        private void ToggleSortDirection()
        {
            settings.SortDescending = !settings.SortDescending;
            saveSettings();
            Reload();
            statusText.Text = settings.SortDescending ? "Sorted descending." : "Sorted ascending.";
        }

        private void RefreshGroupFilterItems()
        {
            if (groupFilter == null) return;
            var current = string.IsNullOrWhiteSpace(settings.GroupFilter) ? "All" : settings.GroupFilter;
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

        private void FileEventsListKeyDown(object sender, KeyEventArgs e)
        {
            if (e.Alt && e.KeyCode == Keys.O)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                OpenOptionsMenu();
            }
            else if (e.KeyCode == Keys.Enter)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                RestoreSelectedFileClipboardEvent(true);
            }
            else if (e.Control && e.KeyCode == Keys.C)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                CopySelectedFileClipboardPaths();
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
            RestoreSelectedFileClipboardEvent(false);
        }

        private void RestoreSelectedFileClipboardEvent(bool closeAfterRestore)
        {
            var item = SelectedFileClipboardEvent();
            if (item == null || item.Files == null || item.Files.Count == 0)
            {
                statusText.Text = "Selected clipboard event does not contain files.";
                return;
            }

            var existing = item.Files
                .Where(path => !string.IsNullOrWhiteSpace(path) && (File.Exists(path) || Directory.Exists(path)))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray();
            if (existing.Length == 0)
            {
                statusText.Text = "No existing files or folders remain for the selected clipboard event.";
                return;
            }

            try
            {
                var paths = new StringCollection();
                paths.AddRange(existing);
                Clipboard.SetFileDropList(paths);
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

        private void CopySelectedFileClipboardPaths()
        {
            var item = SelectedFileClipboardEvent();
            if (item == null || item.Files == null || item.Files.Count == 0)
            {
                statusText.Text = "Selected clipboard event does not contain files.";
                return;
            }

            Clipboard.SetText(string.Join(Environment.NewLine, item.Files));
            statusText.Text = item.Files.Count == 1
                ? "Copied one file path to the clipboard."
                : "Copied " + item.Files.Count + " file paths to the clipboard.";
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

        private ClipboardEventSummary SelectedFileClipboardEvent()
        {
            if (fileEventsList == null || fileEventsList.SelectedItems.Count == 0) return null;
            return fileEventsList.SelectedItems[0].Tag as ClipboardEventSummary;
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
                var first = Path.GetFileName(item.Files[0]);
                if (string.IsNullOrWhiteSpace(first)) first = item.Files[0];
                var operation = NormalizeDropEffectText(item.Operation);
                if (string.IsNullOrWhiteSpace(operation)) operation = "Files";
                var count = item.FileCount > 0 ? item.FileCount : item.Files.Count;
                return operation + ", " + count + " file" + (count == 1 ? string.Empty : "s") + ", " + first;
            }

            if (item.Formats != null && item.Formats.Count > 0)
            {
                return "Non-text clipboard event, " + string.Join(", ", item.Formats.Take(3));
            }

            return "Non-text clipboard event";
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
            if (string.Equals(settings.GroupFilter, selected, StringComparison.CurrentCultureIgnoreCase)) return;
            settings.GroupFilter = selected;
            saveSettings();
            Reload(null, 0);
        }

        private bool IsSortMode(string sortMode)
        {
            return string.Equals(settings.SortMode ?? "LastUsed", sortMode, StringComparison.OrdinalIgnoreCase);
        }

        private void CopySelected()
        {
            CopySelected(true);
        }

        private void CopySelected(bool closeAfterCopy)
        {
            var selected = SelectedEntries();
            if (selected.Count == 0) return;
            settings.LastSelectedIndex = list.SelectedIndices.Count > 0 ? list.SelectedIndices[0] : -1;
            saveSettings();
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

        private void CopyPinnedByPosition(int position)
        {
            var pinnedEntries = store.GetEntries(settings.SortMode, "Pinned", settings.SortDescending);
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

            settings.GroupFilter = groups[position];
            saveSettings();
            RefreshGroupFilterItems();
            Reload(null, 0);
            statusText.Text = "Showing group filter " + groups[position] + ".";
        }

        private void DeleteSelected()
        {
            if (list.SelectedItems.Count == 0) return;
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

        private void NameSelectedEntry()
        {
            var selected = SelectedEntries();
            if (selected.Count == 0) return;
            if (selected.Count > 1)
            {
                statusText.Text = "Select one entry to name it.";
                return;
            }

            var entry = selected[0];
            using (var dialog = new EntryNameForm(entry.Name, entry.Text))
            {
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                store.SetNameAndText(entry.Id, dialog.EntryName, dialog.EntryText);
                Reload(entry.Id, -1);
                statusText.Text = "Updated selected clipboard entry.";
            }
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
            var selected = SelectedEntries();
            if (selected.Count == 0) return;
            if (selected.Count > 1)
            {
                statusText.Text = "Select one entry to show properties.";
                return;
            }

            var entry = selected[0];
            var preferredIndex = list.SelectedIndices.Count > 0 ? list.SelectedIndices[0] : -1;
            using (var dialog = new EntryPropertiesForm(entry))
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

                store.SetName(entry.Id, dialog.EntryName);
                store.SetGroup(new[] { entry.Id }, dialog.EntryGroup);
                store.SetPinned(entry.Id, dialog.EntryPinned);
                RefreshGroupFilterItems();
                Reload(entry.Id, -1);
                statusText.Text = "Updated clipboard entry properties.";
            }
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
            if (selected.Count == 0) return "Pin or &unpin\tShift+Enter";
            if (selected.All(e => e.Pinned)) return "&Unpin selected\tShift+Enter";
            if (selected.All(e => !e.Pinned)) return "&Pin selected\tShift+Enter";
            return "Toggle &pinned state\tShift+Enter";
        }

        private void ViewSelectedText()
        {
            var selected = SelectedEntries();
            if (selected.Count == 0) return;
            var text = selected.Count == 1
                ? selected[0].Text
                : string.Join("\r\n\r\n----- Next clipboard entry -----\r\n\r\n", selected.Select(e => e.Text));
            using (var viewer = new TextViewerForm(text))
            {
                viewer.ShowDialog(this);
            }
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
            if (tabs != null) tabs.SelectedIndex = 0;
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
                store.ImportFromFile(dialog.FileName, replace);
                Reload();
                statusText.Text = replace ? "Imported replacement clipboard database." : "Imported clipboard entries.";
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
                else
                {
                    store.ExportToFile(dialog.FileName);
                }

                statusText.Text = "Exported clipboard entries.";
            }
        }

        private void UpdateMenuHotkeys()
        {
            if (preferencesMenuItem != null)
            {
                preferencesMenuItem.Text = "&Preferences...\tCtrl+,";
            }
            if (toggleMenuItem != null)
            {
                toggleMenuItem.Text = "&Toggle on/off\t" + settings.ToggleActiveHotkey;
            }
            if (sortLastUsedMenuItem != null) sortLastUsedMenuItem.Checked = IsSortMode("LastUsed");
            if (sortAddedMenuItem != null) sortAddedMenuItem.Checked = IsSortMode("Added");
            if (sortTextMenuItem != null) sortTextMenuItem.Checked = IsSortMode("Text");
            if (sortGroupMenuItem != null) sortGroupMenuItem.Checked = IsSortMode("Group");
            if (sortMachineMenuItem != null) sortMachineMenuItem.Checked = IsSortMode("Machine");
            if (sortManualMenuItem != null) sortManualMenuItem.Checked = IsSortMode("Manual");
            if (sortDirectionMenuItem != null)
            {
                sortDirectionMenuItem.Text = settings.SortDescending ? "Sort &ascending" : "Sort &descending";
                sortDirectionMenuItem.Checked = settings.SortDescending;
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
            return tabs != null && tabs.SelectedIndex == 1;
        }

        private void SelectMainTab()
        {
            if (tabs == null || tabs.TabPages.Count == 0) return;
            tabs.SelectedIndex = 0;
            FocusHistoryListNow();
            statusText.Text = "Text history tab.";
        }

        private void SelectFileClipboardTab()
        {
            if (tabs == null || tabs.TabPages.Count < 2) return;
            tabs.SelectedIndex = 1;
            if (fileEventsList.Items.Count > 0 && fileEventsList.SelectedItems.Count == 0)
            {
                fileEventsList.Items[0].Selected = true;
                fileEventsList.Items[0].Focused = true;
                fileEventsList.Items[0].EnsureVisible();
            }
            ActiveControl = fileEventsList;
            fileEventsList.Select();
            fileEventsList.Focus();
            statusText.Text = "File history tab.";
        }

        private void SelectNextTab(bool forward)
        {
            if (tabs == null || tabs.TabPages.Count == 0) return;
            var next = tabs.SelectedIndex + (forward ? 1 : -1);
            if (next < 0) next = tabs.TabPages.Count - 1;
            if (next >= tabs.TabPages.Count) next = 0;
            if (next == 1)
            {
                SelectFileClipboardTab();
            }
            else
            {
                SelectMainTab();
            }
        }

        private int NormalizeTabIndex(int index)
        {
            if (tabs == null || tabs.TabPages.Count == 0) return 0;
            return index >= 0 && index < tabs.TabPages.Count ? index : 0;
        }

        private void SaveSelectedTab()
        {
            if (tabs == null) return;
            var selected = NormalizeTabIndex(tabs.SelectedIndex);
            if (settings.LastSelectedTab == selected) return;
            settings.LastSelectedTab = selected;
            saveSettings();
        }

        private void FocusGroupFilter()
        {
            if (tabs == null || groupFilter == null) return;
            tabs.SelectedIndex = 0;
            ActiveControl = groupFilter;
            groupFilter.Select();
            groupFilter.Focus();
            statusText.Text = "Group filter.";
        }

        private void SelectIndex(int index)
        {
            if (index < 0 || index >= list.Items.Count) return;
            list.SelectedItems.Clear();
            list.Items[index].Selected = true;
            list.Items[index].Focused = true;
            list.Items[index].EnsureVisible();
            list.Focus();
        }

        private void FocusHistoryListNow()
        {
            if (!Visible) return;
            if (tabs != null)
            {
                tabs.SelectedIndex = 0;
            }
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
                if (fileEventsList.Items.Count > 0 && fileEventsList.SelectedItems.Count == 0)
                {
                    fileEventsList.Items[0].Selected = true;
                    fileEventsList.Items[0].Focused = true;
                    fileEventsList.Items[0].EnsureVisible();
                }
                ActiveControl = fileEventsList;
                fileEventsList.Select();
                fileEventsList.Focus();
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
