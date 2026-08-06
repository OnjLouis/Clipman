using System.Drawing;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class WebsiteTitleConfirmationForm : Form
    {
        private readonly CheckBox doNotShowAgain;

        private WebsiteTitleConfirmationForm(string message)
        {
            Text = "Use website title as name";
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MinimizeBox = false;
            MaximizeBox = false;
            ShowInTaskbar = false;
            Width = 570;
            Height = 245;

            var label = new Label
            {
                Text = message,
                Left = 14,
                Top = 14,
                Width = 525,
                Height = 94,
                AccessibleName = message
            };
            doNotShowAgain = new CheckBox
            {
                Text = "Do &not show this again",
                Left = 14,
                Top = 116,
                Width = 260,
                Height = 24,
                AccessibleDescription = "Turn this confirmation off. You can turn it back on in Preferences."
            };
            var useTitle = new Button
            {
                Text = "&Use Website Title",
                DialogResult = DialogResult.OK,
                Left = 324,
                Top = 158,
                Width = 125
            };
            var cancel = new Button
            {
                Text = "Cancel",
                DialogResult = DialogResult.Cancel,
                Left = 459,
                Top = 158,
                Width = 80,
                AccessibleDescription = message + " Press Alt+U to continue, or press Enter to cancel."
            };
            Controls.Add(label);
            Controls.Add(doNotShowAgain);
            Controls.Add(useTitle);
            Controls.Add(cancel);
            AcceptButton = cancel;
            CancelButton = cancel;
            ActiveControl = cancel;
        }

        public static bool Ask(IWin32Window owner, string message, out bool suppressFuturePrompts)
        {
            using (var dialog = new WebsiteTitleConfirmationForm(message))
            {
                var accepted = dialog.ShowDialog(owner) == DialogResult.OK;
                suppressFuturePrompts = accepted && dialog.doNotShowAgain.Checked;
                return accepted;
            }
        }
    }
}
