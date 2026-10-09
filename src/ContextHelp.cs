using System;
using System.Collections.Generic;
using System.Drawing;
using System.Runtime.CompilerServices;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class ContextHelp : IMessageFilter, IDisposable
    {
        private const int KeyDownMessage = 0x0100;
        private sealed class HelpText { public string Text; }
        private static readonly ConditionalWeakTable<Control, HelpText> Descriptions = new ConditionalWeakTable<Control, HelpText>();
        private static readonly Dictionary<string, string> Instructions = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { "Clipman sections", "Choose Text, Links, Rich Text or Files. Only enabled sections are shown. Control+Tab moves between sections; Alt+Left or Alt+Right reorders the focused tab." },
            { "Text history", "Select text clips with the arrow keys. Enter copies and closes, optionally pasting according to Preferences. Control+Enter includes the name; F2 edits and F4 views." },
            { "Links history", "Select web links with the arrow keys. Enter copies the destination; Control+Enter includes its name. Alt+Enter opens the link in your browser and closes History." },
            { "Rich text history", "Formatted clips and embedded images. Copy preserves supported formatting. Alt+Enter opens a selected image in its default application." },
            { "File history", "Device-local file events, not uploaded files. Enter restores the selected files to the clipboard. Alt+Enter reveals one selected file or folder and closes History. Clearing history never deletes the original files." },
            { "Quick Paste mode", "Choose whether the shortcut pastes and restores the previous clipboard, pastes and keeps this clip, or only copies it without pasting." },
            { "Pinned", "Protect this entry from normal history limits and bulk clearing. Unpin it to let those rules apply again." },
            { "Delete", "Remove the selected entry or device-local secret. Removing a file-history record never deletes the original file." },
            { "Add", "Create a new device-local secret with a name, private value and optional shortcut." },
            { "Properties", "Edit the selected secret's name, private value and shortcut." },
            { "Quick Paste", "Paste the selected secret using its configured mode without adding the value to shared history." },
            { "Copy", "Copy the displayed content to the system clipboard. This does not edit the saved entry." },
            { "Copy text", "Copy the displayed clip text to the system clipboard without editing the saved entry." },
            { "Use current history password", "Create this export with the same encryption password as the live history. Re-enter that password before exporting." },
            { "Use a new export password", "Encrypt this export using a separate password. This does not change the live history password." },
            { "Current history password", "Unlock the live history before exporting it. Help never reads this field's contents." },
            { "New export password", "Password used only for this encrypted export. Keep it safely; it is required to import the file elsewhere." },
            { "Confirm new export password", "Retype the new export password to catch mistakes before writing the file." },
            { "Clipboard monitoring active", "Record new clipboard items automatically. Turning this off leaves existing history available; explicit capture commands remain separate." },
            { "Play sounds", "Play event sounds for accepted copies, sync and monitoring changes. This does not change clipboard capture." },
            { "Confirm before deleting entries", "Ask before removing history entries. Disable only if you prefer immediate deletion; removing history does not delete the original files." },
            { "ClipMerge window in milliseconds", "Time allowed for the deliberate second copy that starts an append. Allowed range: 200 to 2000 milliseconds. Shorter windows reduce accidental merging." },
            { "ClipMerge text separator", "Choose what goes between appended selections. This affects ClipMerge, not copying several selected history entries." },
            { "Multiple selected entries separator", "Choose what goes between entries copied together from history. This is independent of ClipMerge; No separator joins them directly." },
            { "Automatically group new clips by source application", "Use the application that supplied the clipboard as the group for newly captured entries. Existing groups are unchanged." },
            { "Automatically remove URL tracking from copied text", "Remove recognized tracking parameters from newly copied web links. This can change the saved destination; turn it off to retain the original URL." },
            { "Save list position", "Remember your place in each history section when closing and reopening history." },
            { "Remove duplicate entries", "Use the Duplicate handling choice when text already exists. Pinned entries remain protected." },
            { "Duplicate handling", "Move to top reuses the existing entry; Ignore leaves it in place; Keep both retains separate copies." },
            { "Maximum entries", "Limit retained normal text history. Zero means no count limit. Pinned entries are not removed by this limit." },
            { "Maximum entry age, days", "Remove old normal text history after this many days. Zero means no age limit. Pinned entries are retained." },
            { "Automatically remove unavailable file-history events", "Remove unpinned events whose referenced files are no longer available. This removes history records, never the files themselves." },
            { "Diagnostics event limit", "Limit the number of file events included in diagnostics, not the number stored in history." },
            { "History storage type", "Local or shared folder uses your chosen data folder. Clipman Server exchanges encrypted history with the configured server; file events and secrets remain device-local." },
            { "Data folder", "Folder containing this device's settings, sounds, logs and history. Use a dedicated folder. A cloud provider must actually synchronize shared files; Clipman does not configure that provider." },
            { "Browse", "Select the Clipman data folder. Review the destination before accepting a settings move." },
            { "Clipman Server host", "Enter the reachable server address and port. Use HTTPS for a remote connection. A wildcard listen address such as 0.0.0.0 is not a client destination." },
            { "Private certificate authority SHA-256 fingerprint", "Compare this public certificate fingerprint with the server owner's trusted copy before accepting a private authority." },
            { "Show history password", "Reveal or hide the password fields on screen. This does not change encryption or whether the password is remembered." },
            { "Generate password", "Generate a strong history password. Keep a safe copy and use the same password on devices that should share history." },
            { "Use no password", "Remove history encryption after confirmation. Do not use this for a shared or public server." },
            { "Ignored applications", "One process name per line, with or without .exe. Automatic copies from these apps are ignored; explicit imports are separate." },
            { "Add running app", "Choose a currently running application to add to the ignore list." },
            { "Run Clipman at Windows startup", "Start the background clipboard manager when you sign into Windows. This does not open history." },
            { "Update check frequency", "Choose when Clipman checks for a newer Windows client. Never disables automatic checks, but manual Check for updates remains available." },
            { "Install updates silently when possible", "Allow automatic update installation without asking. Settings and history are preserved; manual update commands remain available." },
            { "Add Clipman to the Windows Send To menu for text files", "Add selected text-file contents to history from Explorer's Send To menu without opening the file in an editor." },
            { "Show history window after Send To imports", "Open history after a Send To import. Otherwise the import completes in the background." },
            { "Sensitive data mode", "Exclude from history applies selected detection presets to automatic capture only. It does not erase the system clipboard, existing history or deliberate imports." },
            { "History password", "Unlock the encrypted history. Devices using different history passwords have separate server buckets; the server token alone does not select your history." },
            { "Secret name", "Label for this device-local secret. The name is visible in the secrets list; its value remains hidden." },
            { "Secret value", "Private value copied or pasted by this secret. It stays in the device-local encrypted secrets database, not shared history." },
            { "Confirm secret value", "Retype the secret to catch mistakes before saving. This field is never included in help or diagnostics." },
            { "Paste and restore previous clipboard", "Paste the target into the previous application, then restore the prior clipboard contents." },
            { "Paste and keep target on clipboard", "Paste the target into the previous application and leave it on the clipboard afterward." },
            { "Copy to clipboard only", "Put the target on the clipboard without sending a paste command to another application." },
            { "Channel name", "Name this sync channel using 1 to 32 letters, digits, spaces, dashes or underscores. Reserved names cannot be used." },
            { "Groups that route into this channel", "Match these source groups. Multiple choices are alternatives; leave empty to match every group." },
            { "Source devices this channel captures from", "Match these source devices. Leave empty to match every device. Device and group conditions must both match." },
            { "All channels", "Receive every channel, including channels added later. Main history is always received." },
            { "Channels received", "Select the channels this device receives. Unsubscribing hides that channel locally; it does not delete its clips." },
            { "Add channel", "Create a routing channel. Rules are evaluated in list order; the first matching channel receives an entry." },
            { "Edit channel", "Change the selected channel's name or conditions. Saving can relocate matching history entries." },
            { "Edit subscriptions", "Choose which channels the selected device receives without deleting history from the server." },
            { "Close", "Close this window and return to the previous control. In Preferences, changes are applied as you make them." },
            { "Cancel", "Dismiss this dialog without accepting its pending changes." },
            { "OK", "Accept this dialog's changes. Review any validation message if it remains open." },
            { "Save", "Save the entry. Enter inserts a new line in the text editor; Control+Enter also saves." }
        };
        private bool disposed;

        internal ContextHelp() { Application.AddMessageFilter(this); }

        internal static void Prepare(Control control, bool moveDescriptions)
        {
            if (!string.IsNullOrEmpty(control.AccessibleDescription))
            {
                Descriptions.GetValue(control, key => new HelpText()).Text = control.AccessibleDescription;
                if (moveDescriptions) control.AccessibleDescription = string.Empty;
            }
            foreach (Control child in control.Controls) Prepare(child, moveDescriptions);
        }

        internal static Control FocusedControl(Control parent)
        {
            foreach (Control child in parent.Controls)
                if (child.ContainsFocus) return FocusedControl(child);
            return parent;
        }

        internal static string ControlName(Control control)
        {
            for (var current = control; current != null && !(current is Form); current = current.Parent)
            {
                if (!string.IsNullOrWhiteSpace(current.AccessibleName)) return current.AccessibleName;
                if (current is ButtonBase || current is TabPage) return CleanLabel(current.Text);
                var index = current.Parent == null ? -1 : current.Parent.Controls.GetChildIndex(current);
                if (index > 0 && current.Parent.Controls[index - 1] is Label)
                    return CleanLabel(current.Parent.Controls[index - 1].Text);
            }
            return "Current window";
        }

        private static string CleanLabel(string text) { return (text ?? "").Replace("&", "").Trim().TrimEnd('.', ':'); }

        internal static string Description(Control control)
        {
            if (control is FocusableImagePreview) return "Read-only preview of the selected embedded image. Copy the history entry to retain its image data; editing its name does not change the image.";
            if (control.FindForm() is ExportPasswordForm && ControlName(control) == "Use no password")
                return "Create a readable, unencrypted export after confirmation. This does not remove encryption from the live history.";
            for (var current = control; current != null && !(current is Form); current = current.Parent)
            {
                if (current != control && current is TabPage) break;
                if (!string.IsNullOrEmpty(current.AccessibleDescription)) return current.AccessibleDescription;
                HelpText stored;
                if (Descriptions.TryGetValue(current, out stored)) return stored.Text;
                string instructions;
                if (Instructions.TryGetValue(ControlName(current), out instructions)) return instructions;
            }
            if (control is TextBoxBase) return "Enter or review text for this field. Tab moves to the next control; Shift+Tab returns to the previous one. Help never includes the field's contents.";
            if (control is NumericUpDown) return "Type a number or use the arrow keys within this control's allowed range.";
            if (control is ComboBox || control is TabControl) return "Choose an option with the arrow keys. Tab moves into the selected section or to the next control.";
            if (control is ListView || control is TreeView || control is ListBox) return "Navigate items with the arrow keys. Selection alone does not copy or delete an entry; use the window's commands for the selected item.";
            if (control is CheckBox || control is RadioButton) return "Space changes this option. Its name and current state remain available to your screen reader.";
            if (control is ButtonBase) return "Activate this command with Space or Enter. If another dialog opens, review it before accepting.";
            return "Help for this window is available in the complete manual. No clipboard contents or private field values are included here.";
        }

        public bool PreFilterMessage(ref Message message)
        {
            if (disposed || message.Msg != KeyDownMessage || (Keys)message.WParam.ToInt32() != Keys.F1 || Control.ModifierKeys != Keys.None) return false;
            var control = Control.FromChildHandle(message.HWnd);
            var owner = control == null ? null : control.FindForm();
            if (owner is ContextHelpDialog) return true;
            for (var form = owner; form != null; form = form.Owner)
                if (form.GetType().Namespace == "Clipman") { Show(owner); return true; }
            return false;
        }

        internal static void OpenManual(Form owner)
        {
            try
            {
                var path = System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Manual.html");
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(System.IO.File.Exists(path) ? path : "https://onjlouis.github.io/clipman/manual.html") { UseShellExecute = true });
            }
            catch
            {
                MessageBox.Show(owner, "Could not open the manual. You can also use Help, Manual from history.", "Clipman Help", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        internal static void Show(Form owner)
        {
            if (owner == null || owner is ContextHelpDialog) return;
            var focused = FocusedControl(owner);
            using (var dialog = new ContextHelpDialog(ControlName(focused), Description(focused))) dialog.ShowDialog(owner);
            if (!focused.IsDisposed && focused.CanFocus) focused.Focus();
        }

        public void Dispose() { if (disposed) return; disposed = true; Application.RemoveMessageFilter(this); }
    }

    internal sealed class ContextHelpDialog : Form
    {
        internal ContextHelpDialog(string name, string instructions)
        {
            Text = "Help: " + name;
            StartPosition = FormStartPosition.CenterParent;
            Size = new Size(620, 360);
            MinimizeBox = false; MaximizeBox = false; ShowInTaskbar = false;
            var text = new TextBox { Multiline = true, ReadOnly = true, AcceptsTab = false, ScrollBars = ScrollBars.Vertical,
                Dock = DockStyle.Fill, Text = instructions, AccessibleName = name + " help", TabIndex = 0 };
            var manual = new Button { Text = "Open &Manual", AutoSize = true, TabIndex = 1 };
            manual.Click += (s, e) => ContextHelp.OpenManual(this);
            var close = new Button { Text = "&Close", AutoSize = true, DialogResult = DialogResult.Cancel, TabIndex = 2 };
            var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true, Padding = new Padding(8) };
            buttons.Controls.Add(manual); buttons.Controls.Add(close);
            Controls.Add(text); Controls.Add(buttons);
            CancelButton = close;
            Shown += (s, e) => { text.Focus(); text.Select(0, 0); };
        }
    }
}
