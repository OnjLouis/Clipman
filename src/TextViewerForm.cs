using System;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class TextViewerForm : Form
    {
        private readonly TextBox textBox;

        public TextViewerForm(string text)
            : this("Clipman Entry Text", text, "Clipboard entry text", "Read-only clipboard entry text.", false)
        {
        }

        public TextViewerForm(string title, string text, string accessibleName, string accessibleDescription, bool showCopyButton)
        {
            Text = title;
            StartPosition = FormStartPosition.CenterParent;
            Width = 850;
            Height = 600;
            KeyPreview = true;

            textBox = new TextBox
            {
                Dock = DockStyle.Fill,
                Multiline = true,
                ReadOnly = true,
                ScrollBars = ScrollBars.Both,
                WordWrap = false,
                Text = text ?? string.Empty,
                AccessibleName = accessibleName,
                AccessibleDescription = accessibleDescription
            };
            TextBoundaryNavigator.Attach(textBox);
            Controls.Add(textBox);

            var buttons = new FlowLayoutPanel
            {
                Dock = DockStyle.Bottom,
                FlowDirection = FlowDirection.RightToLeft,
                Height = 42
            };
            var close = new Button
            {
                Text = "Close",
                Width = 90,
                DialogResult = DialogResult.OK
            };
            buttons.Controls.Add(close);
            if (showCopyButton)
            {
                var copy = new Button
                {
                    Text = "Copy",
                    Width = 90
                };
                copy.Click += (s, e) =>
                {
                    Clipboard.SetText(textBox.Text ?? string.Empty, TextDataFormat.UnicodeText);
                };
                buttons.Controls.Add(copy);
            }
            Controls.Add(buttons);

            AcceptButton = close;
            CancelButton = close;
            Shown += (s, e) =>
            {
                textBox.SelectionStart = 0;
                textBox.SelectionLength = 0;
                textBox.Focus();
            };
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.Control && e.KeyCode == Keys.A)
            {
                textBox.SelectAll();
                e.Handled = true;
                e.SuppressKeyPress = true;
                return;
            }
            if (e.KeyCode == Keys.Escape)
            {
                Close();
                e.Handled = true;
                return;
            }
            base.OnKeyDown(e);
        }
    }
}
