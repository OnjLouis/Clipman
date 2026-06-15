using System;
using System.Drawing;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class SearchDialog : Form
    {
        private readonly TextBox searchBox;

        public string SearchText
        {
            get { return searchBox.Text; }
        }

        public SearchDialog(string initialText)
        {
            Text = "Search Clipboard History";
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MinimizeBox = false;
            MaximizeBox = false;
            Width = 520;
            Height = 150;

            var label = new Label
            {
                Text = "&Search for:",
                AutoSize = true,
                Left = 12,
                Top = 15
            };
            Controls.Add(label);

            searchBox = new TextBox
            {
                Left = 95,
                Top = 12,
                Width = 390,
                Text = initialText ?? string.Empty
            };
            label.SetBounds(label.Left, label.Top + 4, label.Width, label.Height);
            Controls.Add(searchBox);

            var ok = new Button
            {
                Text = "OK",
                DialogResult = DialogResult.OK,
                Left = 315,
                Top = 55,
                Width = 80
            };
            Controls.Add(ok);

            var cancel = new Button
            {
                Text = "Cancel",
                DialogResult = DialogResult.Cancel,
                Left = 405,
                Top = 55,
                Width = 80
            };
            Controls.Add(cancel);

            AcceptButton = ok;
            CancelButton = cancel;
            label.Focus();
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            searchBox.Focus();
            searchBox.SelectAll();
        }
    }
}
