using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class SecretsForm : Form
    {
        private readonly SecretStore store;
        private readonly Action registerHotkeys;
        private readonly Action<SecretEntry> quickPaste;
        private readonly ListBox list;

        public SecretsForm(SecretStore store, Action registerHotkeys, Action<SecretEntry> quickPaste)
        {
            this.store = store;
            this.registerHotkeys = registerHotkeys;
            this.quickPaste = quickPaste;

            Text = "Clipman Secrets";
            StartPosition = FormStartPosition.CenterParent;
            Width = 680;
            Height = 520;
            KeyPreview = true;
            ShowInTaskbar = false;

            list = new ListBox
            {
                Dock = DockStyle.Fill,
                AccessibleName = "Secrets",
                AccessibleDescription = "Saved secret names. Values are hidden. Press Enter to quick paste, F2 or Alt Enter for properties, Insert to add, and Delete to remove."
            };
            list.DoubleClick += (s, e) => PasteSelected();
            list.KeyDown += ListKeyDown;
            Controls.Add(list);

            var buttons = new FlowLayoutPanel
            {
                Dock = DockStyle.Bottom,
                Height = 44,
                FlowDirection = FlowDirection.RightToLeft
            };
            var close = new ShortcutButton { Text = "Close", ShortcutText = "Esc", Width = 90 };
            close.Click += (s, e) => Close();
            buttons.Controls.Add(close);
            var delete = new ShortcutButton { Text = "Delete", ShortcutText = "Del", Width = 90 };
            delete.Click += (s, e) => DeleteSelected();
            buttons.Controls.Add(delete);
            var edit = new ShortcutButton { Text = "Properties", ShortcutText = "F2", Width = 100 };
            edit.Click += (s, e) => EditSelected();
            buttons.Controls.Add(edit);
            var add = new ShortcutButton { Text = "Add", ShortcutText = "Insert", Width = 90 };
            add.Click += (s, e) => AddSecret();
            buttons.Controls.Add(add);
            var paste = new ShortcutButton { Text = "Quick Paste", ShortcutText = "Enter", Width = 110 };
            paste.Click += (s, e) => PasteSelected();
            buttons.Controls.Add(paste);
            Controls.Add(buttons);

            Load += (s, e) => RefreshList(null);
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

        private void ListKeyDown(object sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Enter && !e.Alt)
            {
                PasteSelected();
                e.Handled = true;
            }
            else if (e.KeyCode == Keys.Insert)
            {
                AddSecret();
                e.Handled = true;
            }
            else if (e.KeyCode == Keys.F2 || (e.Alt && e.KeyCode == Keys.Enter))
            {
                EditSelected();
                e.Handled = true;
            }
            else if (e.KeyCode == Keys.Delete)
            {
                DeleteSelected();
                e.Handled = true;
            }
        }

        private void RefreshList(string selectId)
        {
            var entries = store.GetEntries();
            list.BeginUpdate();
            list.Items.Clear();
            foreach (var entry in entries)
            {
                list.Items.Add(new SecretListItem(entry));
            }
            list.EndUpdate();

            var index = -1;
            if (!string.IsNullOrWhiteSpace(selectId))
            {
                for (var i = 0; i < list.Items.Count; i++)
                {
                    var item = list.Items[i] as SecretListItem;
                    if (item != null && string.Equals(item.Entry.Id, selectId, StringComparison.Ordinal))
                    {
                        index = i;
                        break;
                    }
                }
            }
            if (index < 0 && list.Items.Count > 0) index = 0;
            if (index >= 0) list.SelectedIndex = index;
        }

        private SecretEntry SelectedEntry()
        {
            var item = list.SelectedItem as SecretListItem;
            return item == null ? null : item.Entry;
        }

        private void AddSecret()
        {
            using (var form = new SecretEditorForm(new SecretEntry(), true))
            {
                if (form.ShowDialog(this) == DialogResult.OK)
                {
                    if (!TrySaveEntry(form.Secret)) return;
                    registerHotkeys();
                    RefreshList(form.Secret.Id);
                }
            }
        }

        private void EditSelected()
        {
            var entry = SelectedEntry();
            if (entry == null) return;
            using (var form = new SecretEditorForm(entry))
            {
                if (form.ShowDialog(this) == DialogResult.OK)
                {
                    if (!TrySaveEntry(form.Secret)) return;
                    registerHotkeys();
                    RefreshList(form.Secret.Id);
                }
            }
        }

        private void DeleteSelected()
        {
            var entry = SelectedEntry();
            if (entry == null) return;
            var result = MessageBox.Show(this, "Delete the selected secret?", "Clipman Secrets", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (result != DialogResult.Yes) return;
            try
            {
                store.DeleteEntry(entry.Id);
            }
            catch (Exception ex)
            {
                ShowStoreError("Could not delete the selected secret.", ex);
                return;
            }
            registerHotkeys();
            RefreshList(null);
        }

        private bool TrySaveEntry(SecretEntry entry)
        {
            try
            {
                store.SaveEntry(entry);
                return true;
            }
            catch (Exception ex)
            {
                ShowStoreError("Could not save the secret.", ex);
                return false;
            }
        }

        private void ShowStoreError(string message, Exception ex)
        {
            MessageBox.Show(this, message + "\r\n\r\n" + ex.Message, "Clipman Secrets", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        private void PasteSelected()
        {
            var entry = SelectedEntry();
            if (entry == null) return;
            quickPaste(entry);
            Close();
        }

        private sealed class SecretListItem
        {
            public SecretEntry Entry { get; private set; }

            public SecretListItem(SecretEntry entry)
            {
                Entry = entry;
            }

            public override string ToString()
            {
                var hotkey = string.IsNullOrWhiteSpace(Entry.Hotkey) ? "" : "; Quick Paste: " + Entry.Hotkey;
                return (string.IsNullOrWhiteSpace(Entry.Name) ? "Unnamed secret" : Entry.Name) + hotkey;
            }
        }
    }
}
