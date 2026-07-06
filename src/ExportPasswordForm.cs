using System;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class ExportPasswordForm : Form
    {
        private readonly RadioButton currentPassword;
        private readonly RadioButton newPassword;
        private readonly RadioButton noPassword;
        private readonly TextBox passwordBox;
        private readonly TextBox confirmBox;
        private readonly bool hasCurrentPassword;
        private readonly Func<string, bool> currentPasswordMatches;

        public bool UseCurrentPassword { get { return currentPassword.Checked && hasCurrentPassword; } }
        public string ExportPassword { get { return newPassword.Checked ? passwordBox.Text : string.Empty; } }

        private ExportPasswordForm(bool hasCurrentPassword, Func<string, bool> currentPasswordMatches)
        {
            this.hasCurrentPassword = hasCurrentPassword;
            this.currentPasswordMatches = currentPasswordMatches ?? (password => false);

            Text = "Clipman export password";
            StartPosition = FormStartPosition.CenterParent;
            Width = 520;
            Height = 285;
            MinimizeBox = false;
            MaximizeBox = false;
            ShowInTaskbar = false;
            FormBorderStyle = FormBorderStyle.FixedDialog;

            var label = new Label
            {
                Text = "Choose how to protect this .clipdb export.",
                Left = 12,
                Top = 12,
                Width = 470,
                Height = 28
            };
            Controls.Add(label);

            currentPassword = new RadioButton
            {
                Text = "Use &current history password",
                Left = 16,
                Top = 46,
                Width = 250,
                Enabled = hasCurrentPassword,
                Checked = hasCurrentPassword
            };
            Controls.Add(currentPassword);

            newPassword = new RadioButton
            {
                Text = "Use a &new export password",
                Left = 16,
                Top = 76,
                Width = 250,
                Checked = !hasCurrentPassword
            };
            Controls.Add(newPassword);

            noPassword = new RadioButton
            {
                Text = "Use n&o password",
                Left = 16,
                Top = 106,
                Width = 250
            };
            Controls.Add(noPassword);

            var passwordLabel = new Label
            {
                Text = "&Password:",
                Left = 34,
                Top = 142,
                Width = 90,
                Height = 22
            };
            Controls.Add(passwordLabel);

            passwordBox = new TextBox
            {
                Left = 130,
                Top = 138,
                Width = 340,
                UseSystemPasswordChar = true,
                AccessibleName = "New export password"
            };
            Controls.Add(passwordBox);

            var confirmLabel = new Label
            {
                Text = "Con&firm:",
                Left = 34,
                Top = 174,
                Width = 90,
                Height = 22
            };
            Controls.Add(confirmLabel);

            confirmBox = new TextBox
            {
                Left = 130,
                Top = 170,
                Width = 340,
                UseSystemPasswordChar = true,
                AccessibleName = "Confirm new export password"
            };
            Controls.Add(confirmBox);

            var ok = new Button { Text = "OK", Left = 302, Top = 212, Width = 80, DialogResult = DialogResult.OK };
            var cancel = new Button { Text = "Cancel", Left = 392, Top = 212, Width = 80, DialogResult = DialogResult.Cancel };
            Controls.Add(ok);
            Controls.Add(cancel);
            AcceptButton = ok;
            CancelButton = cancel;

            currentPassword.CheckedChanged += (s, e) => UpdatePasswordFields();
            newPassword.CheckedChanged += (s, e) => UpdatePasswordFields();
            noPassword.CheckedChanged += (s, e) => UpdatePasswordFields();
            ok.Click += (s, e) =>
            {
                if (ValidateSelection()) return;
                DialogResult = DialogResult.None;
            };
            UpdatePasswordFields();
        }

        public static bool Ask(IWin32Window owner, bool hasCurrentPassword, Func<string, bool> currentPasswordMatches, out bool useCurrentPassword, out string exportPassword)
        {
            using (var dialog = new ExportPasswordForm(hasCurrentPassword, currentPasswordMatches))
            {
                if (dialog.ShowDialog(owner) != DialogResult.OK)
                {
                    useCurrentPassword = false;
                    exportPassword = string.Empty;
                    return false;
                }

                useCurrentPassword = dialog.UseCurrentPassword;
                exportPassword = dialog.ExportPassword;
                if (hasCurrentPassword && !useCurrentPassword && !ConfirmCurrentPassword(owner, currentPasswordMatches))
                {
                    useCurrentPassword = false;
                    exportPassword = string.Empty;
                    return false;
                }
                return true;
            }
        }

        private static bool ConfirmCurrentPassword(IWin32Window owner, Func<string, bool> currentPasswordMatches)
        {
            while (true)
            {
                using (var dialog = new Form())
                {
                    dialog.Text = "Confirm history password";
                    dialog.StartPosition = FormStartPosition.CenterParent;
                    dialog.Width = 470;
                    dialog.Height = 170;
                    dialog.MinimizeBox = false;
                    dialog.MaximizeBox = false;
                    dialog.ShowInTaskbar = false;
                    dialog.FormBorderStyle = FormBorderStyle.FixedDialog;

                    var label = new Label
                    {
                        Text = "Enter the current history password to create this export.",
                        Left = 12,
                        Top = 12,
                        Width = 420,
                        Height = 36
                    };
                    dialog.Controls.Add(label);

                    var passwordLabel = new Label
                    {
                        Text = "&Password:",
                        Left = 18,
                        Top = 58,
                        Width = 80,
                        Height = 22
                    };
                    dialog.Controls.Add(passwordLabel);

                    var passwordBox = new TextBox
                    {
                        Left = 104,
                        Top = 54,
                        Width = 330,
                        UseSystemPasswordChar = true,
                        AccessibleName = "Current history password"
                    };
                    dialog.Controls.Add(passwordBox);

                    var ok = new Button { Text = "OK", Left = 264, Top = 92, Width = 80, DialogResult = DialogResult.OK };
                    var cancel = new Button { Text = "Cancel", Left = 354, Top = 92, Width = 80, DialogResult = DialogResult.Cancel };
                    dialog.Controls.Add(ok);
                    dialog.Controls.Add(cancel);
                    dialog.AcceptButton = ok;
                    dialog.CancelButton = cancel;

                    if (dialog.ShowDialog(owner) != DialogResult.OK) return false;
                    if (currentPasswordMatches(passwordBox.Text)) return true;

                    MessageBox.Show(owner, "The current history password did not match. The export was not created.", "Clipman export password", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            }
        }

        private void UpdatePasswordFields()
        {
            passwordBox.Enabled = newPassword.Checked || currentPassword.Checked;
            confirmBox.Enabled = newPassword.Checked;
            passwordBox.AccessibleName = currentPassword.Checked ? "Current history password" : "New export password";
            confirmBox.AccessibleName = "Confirm new export password";
            if (currentPassword.Checked || noPassword.Checked)
            {
                confirmBox.Text = string.Empty;
            }
        }

        private bool ValidateSelection()
        {
            if (currentPassword.Checked)
            {
                if (passwordBox.Text.Length == 0)
                {
                    MessageBox.Show(this, "Enter the current history password to create this export.", "Clipman export password", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    passwordBox.Focus();
                    return false;
                }
                if (!currentPasswordMatches(passwordBox.Text))
                {
                    MessageBox.Show(this, "The current history password did not match. The export was not created.", "Clipman export password", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    passwordBox.Focus();
                    passwordBox.SelectAll();
                    return false;
                }
                return true;
            }
            if (!newPassword.Checked) return true;
            if (passwordBox.Text.Length == 0)
            {
                MessageBox.Show(this, "Enter an export password, or choose Use no password.", "Clipman export password", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                passwordBox.Focus();
                return false;
            }
            if (!string.Equals(passwordBox.Text, confirmBox.Text, StringComparison.Ordinal))
            {
                MessageBox.Show(this, "The export password and confirmation do not match.", "Clipman export password", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                confirmBox.Focus();
                return false;
            }
            return true;
        }
    }
}
