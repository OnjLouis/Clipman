using System;
using System.Drawing;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class SecretEditorForm : Form
    {
        private readonly TextBox nameBox;
        private readonly TextBox valueBox;
        private readonly TextBox confirmBox;
        private readonly TextBox hotkeyBox;
        private readonly CheckBox showSecretBox;

        public SecretEntry Secret { get; private set; }

        public SecretEditorForm(SecretEntry secret, bool isNewSecret = false)
        {
            Secret = secret == null ? new SecretEntry() : secret;
            Text = isNewSecret ? "Add Secret" : "Secret Properties";
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MinimizeBox = false;
            MaximizeBox = false;
            ShowInTaskbar = false;
            ClientSize = new Size(620, 320);
            KeyPreview = true;

            var nameLabel = new Label { Text = "&Name:", AutoSize = true, Location = new Point(12, 18) };
            Controls.Add(nameLabel);
            nameBox = new TextBox
            {
                Location = new Point(130, 14),
                Width = 460,
                Text = Secret.Name ?? string.Empty,
                AccessibleName = "Secret name"
            };
            nameBox.KeyDown += TextBoxSelectAllKeyDown;
            Controls.Add(nameBox);

            var valueLabel = new Label { Text = "&Secret:", AutoSize = true, Location = new Point(12, 58) };
            Controls.Add(valueLabel);
            valueBox = new TextBox
            {
                Location = new Point(130, 54),
                Width = 460,
                UseSystemPasswordChar = true,
                Text = Secret.Value ?? string.Empty,
                AccessibleName = "Secret value"
            };
            valueBox.KeyDown += TextBoxSelectAllKeyDown;
            Controls.Add(valueBox);

            var confirmLabel = new Label { Text = "&Confirm:", AutoSize = true, Location = new Point(12, 98) };
            Controls.Add(confirmLabel);
            confirmBox = new TextBox
            {
                Location = new Point(130, 94),
                Width = 460,
                UseSystemPasswordChar = true,
                Text = Secret.Value ?? string.Empty,
                AccessibleName = "Confirm secret value"
            };
            confirmBox.KeyDown += TextBoxSelectAllKeyDown;
            Controls.Add(confirmBox);

            showSecretBox = new CheckBox
            {
                Text = "Sho&w secret",
                Location = new Point(130, 128),
                AutoSize = true,
                AccessibleDescription = "Show or hide the secret and confirmation fields."
            };
            showSecretBox.CheckedChanged += (s, e) =>
            {
                valueBox.UseSystemPasswordChar = !showSecretBox.Checked;
                confirmBox.UseSystemPasswordChar = !showSecretBox.Checked;
            };
            Controls.Add(showSecretBox);

            var hotkeyLabel = new Label { Text = "Quick &Paste hotkey:", AutoSize = true, Location = new Point(12, 168) };
            Controls.Add(hotkeyLabel);
            hotkeyBox = new TextBox
            {
                Location = new Point(130, 164),
                Width = 210,
                ReadOnly = true,
                Text = Secret.Hotkey ?? string.Empty,
                AccessibleName = "Quick Paste hotkey",
                AccessibleDescription = "Press a global hotkey for this secret, or press Delete or Backspace to clear it."
            };
            hotkeyBox.KeyDown += HotkeyBoxKeyDown;
            hotkeyBox.KeyPress += (s, e) => e.Handled = true;
            Controls.Add(hotkeyBox);

            var note = new Label
            {
                Text = "Secrets are stored separately from clipboard history. Quick Paste temporarily places the secret on the clipboard, pastes it, then restores the previous clipboard.",
                Location = new Point(15, 205),
                Size = new Size(575, 40)
            };
            Controls.Add(note);

            var ok = new Button { Text = "OK", DialogResult = DialogResult.OK, Location = new Point(410, 270), Width = 85 };
            var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Location = new Point(505, 270), Width = 85 };
            Controls.Add(ok);
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

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (DialogResult == DialogResult.OK)
            {
                if (string.IsNullOrWhiteSpace(nameBox.Text))
                {
                    MessageBox.Show(this, "Type a name for this secret.", "Clipman Secrets", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    nameBox.Focus();
                    e.Cancel = true;
                    return;
                }
                if (!string.Equals(valueBox.Text, confirmBox.Text, StringComparison.Ordinal))
                {
                    MessageBox.Show(this, "The secret and confirmation do not match.", "Clipman Secrets", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    confirmBox.Focus();
                    e.Cancel = true;
                    return;
                }
                Secret.Name = nameBox.Text.Trim();
                Secret.Value = valueBox.Text;
                Secret.Hotkey = hotkeyBox.Text.Trim();
            }
            base.OnFormClosing(e);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape)
            {
                DialogResult = DialogResult.Cancel;
                Close();
                e.Handled = true;
                return;
            }
            base.OnKeyDown(e);
        }

        private void HotkeyBoxKeyDown(object sender, KeyEventArgs e)
        {
            e.Handled = true;
            e.SuppressKeyPress = true;
            if (e.KeyCode == Keys.Delete || e.KeyCode == Keys.Back)
            {
                hotkeyBox.Text = string.Empty;
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
                hotkeyBox.Text = text;
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
