using System;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class PasswordPromptForm : Form
    {
        private readonly TextBox passwordBox;

        public string Password { get { return passwordBox.Text; } }

        public PasswordPromptForm(string title, string message)
        {
            Text = title;
            StartPosition = FormStartPosition.CenterScreen;
            Width = 480;
            Height = 180;
            MinimizeBox = false;
            MaximizeBox = false;
            ShowInTaskbar = false;
            FormBorderStyle = FormBorderStyle.FixedDialog;

            var label = new Label
            {
                Text = message,
                Left = 12,
                Top = 12,
                Width = 435,
                Height = 40
            };
            Controls.Add(label);

            passwordBox = new TextBox
            {
                Left = 12,
                Top = 58,
                Width = 435,
                UseSystemPasswordChar = true,
                AccessibleName = "History password"
            };
            passwordBox.KeyDown += TextBoxSelectAllKeyDown;
            Controls.Add(passwordBox);

            var ok = new Button { Text = "OK", Left = 270, Top = 98, Width = 80, DialogResult = DialogResult.OK };
            var cancel = new Button { Text = "Cancel", Left = 365, Top = 98, Width = 80, DialogResult = DialogResult.Cancel };
            Controls.Add(ok);
            Controls.Add(cancel);
            AcceptButton = ok;
            CancelButton = cancel;
        }

        public static string Ask(string title, string message)
        {
            using (var dialog = new PasswordPromptForm(title, message))
            {
                return dialog.ShowDialog() == DialogResult.OK ? dialog.Password : string.Empty;
            }
        }

        private static void TextBoxSelectAllKeyDown(object sender, KeyEventArgs e)
        {
            if (e.Control && e.KeyCode == Keys.A)
            {
                var textBox = sender as TextBox;
                if (textBox != null)
                {
                    textBox.SelectAll();
                    e.Handled = true;
                    e.SuppressKeyPress = true;
                }
            }
        }
    }
}
