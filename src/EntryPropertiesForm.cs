using System;
using System.Drawing;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class EntryPropertiesForm : Form
    {
        private readonly TextBox nameBox;
        private readonly TextBox groupBox;
        private readonly CheckBox pinnedBox;
        private readonly CheckBox templateBox;
        private readonly CheckBox quickCopyTargetBox;
        private readonly TextBox quickCopyHotkeyBox;
        private readonly RadioButton pasteRestoreMode;
        private readonly RadioButton pasteKeepMode;
        private readonly RadioButton copyOnlyMode;
        private readonly TextBox textBox;
        private bool deleteRequested;

        public string EntryName { get { return nameBox.Text; } }
        public string EntryGroup { get { return groupBox.Text; } }
        public string EntryText { get { return textBox.Text; } }
        public bool EntryPinned { get { return pinnedBox.Checked; } }
        public bool EntryIsTemplate { get { return templateBox.Checked; } }
        public bool EntryIsQuickCopyTarget { get { return quickCopyTargetBox.Checked; } }
        public string EntryQuickCopyHotkey { get { return quickCopyHotkeyBox.Text.Trim(); } }
        public string EntryQuickPasteMode
        {
            get
            {
                if (copyOnlyMode.Checked) return QuickPasteModes.CopyOnly;
                if (pasteKeepMode.Checked) return QuickPasteModes.PasteKeep;
                return QuickPasteModes.PasteRestore;
            }
        }
        public bool DeleteRequested { get { return deleteRequested; } }

        public EntryPropertiesForm(ClipEntry entry, bool isQuickCopyTarget, string quickCopyHotkey, string quickPasteMode, bool focusQuickCopy)
        {
            Text = "Clipboard Entry Properties";
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MinimizeBox = false;
            MaximizeBox = false;
            ShowInTaskbar = false;
            ClientSize = new Size(700, 620);
            KeyPreview = true;

            var nameLabel = new Label { Text = "&Name:", Location = new Point(12, 14), AutoSize = true };
            Controls.Add(nameLabel);
            nameBox = new TextBox
            {
                Location = new Point(90, 10),
                Width = 590,
                Text = entry == null ? string.Empty : entry.Name ?? string.Empty,
                AccessibleName = "Entry name",
                AccessibleDescription = "Optional name shown before the clipboard text. The name is not copied."
            };
            Controls.Add(nameBox);

            var groupLabel = new Label { Text = "&Group:", Location = new Point(12, 48), AutoSize = true };
            Controls.Add(groupLabel);
            groupBox = new TextBox
            {
                Location = new Point(90, 44),
                Width = 590,
                Text = entry == null ? string.Empty : entry.Group ?? string.Empty,
                AccessibleName = "Entry group",
                AccessibleDescription = "Optional group used by the group filter."
            };
            Controls.Add(groupBox);

            pinnedBox = new CheckBox
            {
                Text = "&Pinned",
                Location = new Point(90, 78),
                Width = 120,
                Checked = entry != null && entry.Pinned
            };
            Controls.Add(pinnedBox);

            templateBox = new CheckBox
            {
                Text = "&Template entry",
                Location = new Point(220, 78),
                Width = 160,
                Checked = entry != null && entry.IsTemplate,
                AccessibleName = "Template entry",
                AccessibleDescription = "When checked, variables such as year full in double braces are resolved when this entry is copied or pasted. Stored text is not changed."
            };
            Controls.Add(templateBox);

            quickCopyTargetBox = new CheckBox
            {
                Text = "&Use as quick-paste target",
                Location = new Point(390, 78),
                Width = 260,
                Checked = isQuickCopyTarget,
                AccessibleName = "Use as quick-paste target",
                AccessibleDescription = "When checked, this entry is pasted by the quick-paste global hotkey shown below."
            };
            Controls.Add(quickCopyTargetBox);

            var quickCopyHotkeyLabel = new Label { Text = "Quick Paste &hotkey:", Location = new Point(12, 116), AutoSize = true };
            Controls.Add(quickCopyHotkeyLabel);
            quickCopyHotkeyBox = new TextBox
            {
                Location = new Point(150, 112),
                Width = 180,
                ReadOnly = false,
                ShortcutsEnabled = false,
                Text = quickCopyHotkey ?? string.Empty,
                AccessibleName = "Quick Paste hotkey",
                AccessibleDescription = "Global hotkey that pastes this entry into the active app. Two modifiers are safest. One modifier is allowed only with function keys, Grave, or Backslash. Press Delete or Backspace to clear this hotkey."
            };
            quickCopyHotkeyBox.KeyDown += QuickCopyHotkeyBoxKeyDown;
            quickCopyHotkeyBox.KeyPress += SuppressHotkeyTextInput;
            Controls.Add(quickCopyHotkeyBox);

            var modeBox = new GroupBox
            {
                Text = "Quick Paste &mode",
                Location = new Point(15, 146),
                Size = new Size(665, 80),
                AccessibleName = "Quick Paste mode",
                AccessibleDescription = "Controls what the Quick Paste hotkey does with the clipboard."
            };
            pasteRestoreMode = new RadioButton
            {
                Text = "Paste and &restore previous clipboard",
                Location = new Point(12, 22),
                Width = 230,
                Checked = QuickPasteModes.Normalize(quickPasteMode) == QuickPasteModes.PasteRestore
            };
            pasteKeepMode = new RadioButton
            {
                Text = "Paste and &keep target on clipboard",
                Location = new Point(250, 22),
                Width = 235,
                Checked = QuickPasteModes.Normalize(quickPasteMode) == QuickPasteModes.PasteKeep
            };
            copyOnlyMode = new RadioButton
            {
                Text = "Copy to clipboard &only",
                Location = new Point(12, 48),
                Width = 180,
                Checked = QuickPasteModes.Normalize(quickPasteMode) == QuickPasteModes.CopyOnly
            };
            modeBox.Controls.Add(pasteRestoreMode);
            modeBox.Controls.Add(pasteKeepMode);
            modeBox.Controls.Add(copyOnlyMode);
            Controls.Add(modeBox);

            var textLabel = new Label { Text = "&Clipboard text:", Location = new Point(12, 238), AutoSize = true };
            Controls.Add(textLabel);
            textBox = new TextBox
            {
                Location = new Point(15, 262),
                Width = 665,
                Height = 190,
                Multiline = true,
                ScrollBars = ScrollBars.Both,
                WordWrap = false,
                Text = entry == null ? string.Empty : entry.Text ?? string.Empty,
                AccessibleName = "Clipboard text",
                AccessibleDescription = "Clipboard text stored for this entry. Editing this field changes what Clipman copies for this entry."
            };
            Controls.Add(textBox);

            var insertPreset = new Button
            {
                Text = "Insert &sample...",
                Location = new Point(15, 466),
                Width = 125,
                AccessibleName = "Insert sample template",
                AccessibleDescription = "Opens a menu of sample templates. The chosen sample is inserted at the cursor in the clipboard text field."
            };
            insertPreset.Click += (s, e) => ShowTemplateMenu(insertPreset, TemplateResolver.Presets);
            Controls.Add(insertPreset);

            var insertVariable = new Button
            {
                Text = "Insert &field...",
                Location = new Point(150, 466),
                Width = 115,
                AccessibleName = "Insert template field",
                AccessibleDescription = "Opens a menu of template fields. The chosen field is inserted at the cursor in the clipboard text field."
            };
            insertVariable.Click += (s, e) => ShowTemplateMenu(insertVariable, TemplateResolver.Variables);
            Controls.Add(insertVariable);

            var copy = new Button { Text = "Copy te&xt", Location = new Point(15, 546), Width = 95 };
            copy.Click += (s, e) => Clipboard.SetText(textBox.Text ?? string.Empty, TextDataFormat.UnicodeText);
            Controls.Add(copy);

            var preview = new Button
            {
                Text = "Preview t&emplate",
                Location = new Point(120, 546),
                Width = 125,
                AccessibleName = "Preview template",
                AccessibleDescription = "Shows the clipboard text after template variables are resolved."
            };
            preview.Click += (s, e) =>
            {
                using (var viewer = new TextViewerForm("Template Preview", TemplateResolver.Resolve(textBox.Text), "Template preview", "Resolved template preview.", true))
                {
                    viewer.ShowDialog(this);
                }
            };
            Controls.Add(preview);

            var variables = new Button
            {
                Text = "Template &variables",
                Location = new Point(255, 546),
                Width = 135,
                AccessibleName = "Template variables",
                AccessibleDescription = "Shows the variables that Clipman can resolve in template entries."
            };
            variables.Click += (s, e) =>
            {
                using (var viewer = new TextViewerForm("Template Variables", TemplateResolver.VariableReferenceText, "Template variables", "Available Clipman template variables.", true))
                {
                    viewer.ShowDialog(this);
                }
            };
            Controls.Add(variables);

            var delete = new Button { Text = "&Delete", Location = new Point(400, 546), Width = 85 };
            delete.Click += (s, e) =>
            {
                deleteRequested = true;
                DialogResult = DialogResult.OK;
                Close();
            };
            Controls.Add(delete);

            var ok = new Button { Text = "OK", DialogResult = DialogResult.OK, Location = new Point(500, 546), Width = 85 };
            Controls.Add(ok);

            var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Location = new Point(595, 546), Width = 85 };
            Controls.Add(cancel);

            AcceptButton = ok;
            CancelButton = cancel;
            if (focusQuickCopy)
            {
                Shown += (s, e) => quickCopyHotkeyBox.Focus();
            }
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            if (quickCopyHotkeyBox.Focused) return;
            nameBox.Focus();
            nameBox.SelectAll();
        }

        private void QuickCopyHotkeyBoxKeyDown(object sender, KeyEventArgs e)
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
                quickCopyTargetBox.Checked = false;
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

        private void ShowTemplateMenu(Control owner, TemplateResolver.TemplateItem[] items)
        {
            var menu = new ContextMenuStrip();
            foreach (var item in items)
            {
                var captured = item;
                var menuItem = new ToolStripMenuItem(captured.Name);
                menuItem.Click += (s, e) => InsertTemplateText(captured.Text);
                menu.Items.Add(menuItem);
            }
            menu.Show(owner, new Point(0, owner.Height));
        }

        private void InsertTemplateText(string text)
        {
            textBox.Focus();
            textBox.SelectedText = text ?? string.Empty;
            templateBox.Checked = true;
        }

    }
}
