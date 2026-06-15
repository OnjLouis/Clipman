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
        private readonly TextBox textBox;
        private bool deleteRequested;

        public string EntryName { get { return nameBox.Text; } }
        public string EntryGroup { get { return groupBox.Text; } }
        public bool EntryPinned { get { return pinnedBox.Checked; } }
        public bool DeleteRequested { get { return deleteRequested; } }

        public EntryPropertiesForm(ClipEntry entry)
        {
            Text = "Clipboard Entry Properties";
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MinimizeBox = false;
            MaximizeBox = false;
            ShowInTaskbar = false;
            ClientSize = new Size(700, 430);
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
                Width = 200,
                Checked = entry != null && entry.Pinned
            };
            Controls.Add(pinnedBox);

            var textLabel = new Label { Text = "&Clipboard text:", Location = new Point(12, 110), AutoSize = true };
            Controls.Add(textLabel);
            textBox = new TextBox
            {
                Location = new Point(15, 134),
                Width = 665,
                Height = 210,
                Multiline = true,
                ReadOnly = true,
                ScrollBars = ScrollBars.Both,
                WordWrap = false,
                Text = entry == null ? string.Empty : entry.Text ?? string.Empty,
                AccessibleName = "Clipboard text",
                AccessibleDescription = "Read-only clipboard text."
            };
            Controls.Add(textBox);

            var copy = new Button { Text = "&Copy text", Location = new Point(15, 362), Width = 95 };
            copy.Click += (s, e) => Clipboard.SetText(textBox.Text ?? string.Empty, TextDataFormat.UnicodeText);
            Controls.Add(copy);

            var delete = new Button { Text = "&Delete", Location = new Point(120, 362), Width = 85 };
            delete.Click += (s, e) =>
            {
                deleteRequested = true;
                DialogResult = DialogResult.OK;
                Close();
            };
            Controls.Add(delete);

            var ok = new Button { Text = "OK", DialogResult = DialogResult.OK, Location = new Point(500, 362), Width = 85 };
            Controls.Add(ok);

            var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Location = new Point(595, 362), Width = 85 };
            Controls.Add(cancel);

            AcceptButton = ok;
            CancelButton = cancel;
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            nameBox.Focus();
            nameBox.SelectAll();
        }
    }
}
