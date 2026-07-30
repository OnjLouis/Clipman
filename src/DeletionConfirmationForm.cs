using System;
using System.Drawing;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class DeletionConfirmationForm : Form
    {
        private readonly CheckBox doNotAskAgain;

        private DeletionConfirmationForm(string message)
        {
            Text = "Confirm deletion";
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MinimizeBox = false;
            MaximizeBox = false;
            ShowInTaskbar = false;
            Width = 470;
            Height = 190;

            var label = new Label
            {
                Text = message,
                Left = 14,
                Top = 14,
                Width = 425,
                Height = 48,
                AccessibleName = message
            };
            doNotAskAgain = new CheckBox
            {
                Text = "Do &not ask again",
                Left = 14,
                Top = 72,
                Width = 220,
                Height = 24
            };
            var delete = new Button
            {
                Text = "&Delete",
                DialogResult = DialogResult.OK,
                Left = 268,
                Top = 108,
                Width = 80
            };
            var cancel = new Button
            {
                Text = "Cancel",
                DialogResult = DialogResult.Cancel,
                Left = 358,
                Top = 108,
                Width = 80,
                AccessibleDescription = message + " Press Alt+D to delete, or press Enter to cancel."
            };
            Controls.Add(label);
            Controls.Add(doNotAskAgain);
            Controls.Add(delete);
            Controls.Add(cancel);
            AcceptButton = cancel;
            CancelButton = cancel;
            ActiveControl = cancel;
        }

        public static bool Ask(IWin32Window owner, string message, out bool doNotAskAgain)
        {
            using (var dialog = new DeletionConfirmationForm(message))
            {
                var accepted = dialog.ShowDialog(owner) == DialogResult.OK;
                doNotAskAgain = accepted && dialog.doNotAskAgain.Checked;
                return accepted;
            }
        }
    }
}
