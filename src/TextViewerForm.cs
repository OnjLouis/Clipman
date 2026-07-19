using System;
using System.Collections.Generic;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class TextViewerForm : Form
    {
        private readonly TextBox textBox;

        public TextViewerForm(string text)
            : this("Clipman Entry Text", text, "Clipboard entry text", "Read-only clipboard entry text.", false, null)
        {
        }

        public TextViewerForm(string title, string text, string accessibleName, string accessibleDescription, bool showCopyButton)
            : this(title, text, accessibleName, accessibleDescription, showCopyButton, null)
        {
        }

        public TextViewerForm(string title, string text, string accessibleName, string accessibleDescription, bool showCopyButton, IReadOnlyList<KeyValuePair<string, string>> details)
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

            var content = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 1,
                RowCount = details != null && details.Count > 0 ? 2 : 1
            };
            content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            content.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            content.Controls.Add(textBox, 0, 0);

            if (details != null && details.Count > 0)
            {
                content.RowStyles.Add(new RowStyle(SizeType.Absolute, 145));
                var detailsList = new ListView
                {
                    Dock = DockStyle.Fill,
                    View = View.Details,
                    FullRowSelect = true,
                    HeaderStyle = ColumnHeaderStyle.None,
                    HideSelection = false,
                    AccessibleName = "Entry details",
                    AccessibleDescription = "Metadata for the selected clipboard entry."
                };
                detailsList.Columns.Add("Property", 180);
                detailsList.Columns.Add("Value", 590);
                foreach (var detail in details)
                {
                    var item = new ListViewItem(detail.Key);
                    item.SubItems.Add(detail.Value ?? string.Empty);
                    detailsList.Items.Add(item);
                }
                content.Controls.Add(detailsList, 0, 1);
            }

            Controls.Add(content);

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
