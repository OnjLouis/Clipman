using System.Drawing;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class SingleModifierHotkeyConfirmationForm : Form
    {
        private readonly CheckBox doNotShowAgain;

        private SingleModifierHotkeyConfirmationForm(string message)
        {
            Text = "Clipman hotkeys";
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MinimizeBox = false;
            MaximizeBox = false;
            ShowInTaskbar = false;
            Width = 570;
            Height = 225;

            var label = new Label
            {
                Text = message,
                Left = 14,
                Top = 14,
                Width = 525,
                Height = 74,
                AccessibleName = message
            };
            doNotShowAgain = new CheckBox
            {
                Text = "Do &not show this warning again",
                Left = 14,
                Top = 98,
                Width = 300,
                Height = 24,
                AccessibleDescription = "Turn this warning off. You can turn it back on in Hotkey Preferences."
            };
            var keep = new Button
            {
                Text = "&Keep Hotkey",
                DialogResult = DialogResult.OK,
                Left = 344,
                Top = 140,
                Width = 105
            };
            var goBack = new Button
            {
                Text = "&Go Back",
                DialogResult = DialogResult.Cancel,
                Left = 459,
                Top = 140,
                Width = 80,
                AccessibleDescription = message + " Press Alt+K to keep the hotkey, or press Enter to go back."
            };
            Controls.Add(label);
            Controls.Add(doNotShowAgain);
            Controls.Add(keep);
            Controls.Add(goBack);
            AcceptButton = goBack;
            CancelButton = goBack;
            ActiveControl = goBack;
        }

        public static bool Ask(IWin32Window owner, string message, out bool suppressFuturePrompts)
        {
            using (var dialog = new SingleModifierHotkeyConfirmationForm(message))
            {
                var accepted = dialog.ShowDialog(owner) == DialogResult.OK;
                suppressFuturePrompts = accepted && dialog.doNotShowAgain.Checked;
                return accepted;
            }
        }
    }
}
