using System;
using System.Drawing;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class EntryNameForm : Form
    {
        private readonly TextBox nameBox;
        private readonly TextBox textBox;

        public string EntryName
        {
            get { return nameBox.Text; }
        }

        public string EntryText
        {
            get { return textBox.Text; }
        }

        public EntryNameForm(string initialName, string entryText)
        {
            Text = "Edit Clipboard Entry";
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MinimizeBox = false;
            MaximizeBox = false;
            ShowInTaskbar = false;
            ClientSize = new Size(620, 350);
            KeyPreview = true;

            var prompt = new Label
            {
                Text = "Entry &name or hint:",
                AutoSize = true,
                Location = new Point(12, 14)
            };
            Controls.Add(prompt);

            nameBox = new TextBox
            {
                Location = new Point(15, 38),
                Width = 590,
                Text = initialName ?? string.Empty,
                AccessibleName = "Entry name or hint",
                AccessibleDescription = "Optional name shown before the clipboard text. The name is not copied to the clipboard."
            };
            Controls.Add(nameBox);
            prompt.UseMnemonic = true;

            var textPrompt = new Label
            {
                Text = "&Clipboard text:",
                AutoSize = true,
                Location = new Point(12, 72)
            };
            Controls.Add(textPrompt);

            textBox = new TextBox
            {
                Location = new Point(15, 96),
                Width = 590,
                Height = 190,
                Multiline = true,
                AcceptsReturn = true,
                AcceptsTab = false,
                ScrollBars = ScrollBars.Vertical,
                Text = entryText ?? string.Empty,
                AccessibleName = "Clipboard text",
                AccessibleDescription = "Editable stored clipboard text for this entry."
            };
            Controls.Add(textBox);
            textPrompt.UseMnemonic = true;

            var ok = new Button
            {
                Text = "OK",
                DialogResult = DialogResult.OK,
                Location = new Point(425, 305),
                Width = 85
            };
            Controls.Add(ok);

            var cancel = new Button
            {
                Text = "Cancel",
                DialogResult = DialogResult.Cancel,
                Location = new Point(520, 305),
                Width = 85
            };
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
