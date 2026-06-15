using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class GroupPromptForm : Form
    {
        private readonly TextBox valueBox;
        private readonly ListBox groupList;

        public string Value
        {
            get { return valueBox.Text; }
        }

        public GroupPromptForm(string initialValue, IEnumerable<string> groups)
        {
            Text = "Group Clipboard Entry";
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MinimizeBox = false;
            MaximizeBox = false;
            ShowInTaskbar = false;
            ClientSize = new Size(580, 275);
            KeyPreview = true;

            var groupLabel = new Label
            {
                Text = "Entry &group:",
                AutoSize = true,
                Location = new Point(12, 14)
            };
            Controls.Add(groupLabel);

            valueBox = new TextBox
            {
                Location = new Point(15, 38),
                Width = 265,
                Text = initialValue ?? string.Empty,
                AccessibleName = "Entry group",
                AccessibleDescription = "Optional group name. Leave blank to remove the entry from a group."
            };
            Controls.Add(valueBox);
            groupLabel.UseMnemonic = true;

            var listLabel = new Label
            {
                Text = "Existing groups:",
                AutoSize = true,
                Location = new Point(300, 14)
            };
            Controls.Add(listLabel);

            groupList = new ListBox
            {
                Location = new Point(303, 38),
                Size = new Size(260, 175),
                AccessibleName = "Existing groups",
                AccessibleDescription = "Choose an existing group and press Enter or OK to use it."
            };
            groupList.Items.Add("(No group)");
            foreach (var group in (groups ?? Enumerable.Empty<string>())
                .Where(g => !string.IsNullOrWhiteSpace(g))
                .Distinct(StringComparer.CurrentCultureIgnoreCase)
                .OrderBy(g => g, StringComparer.CurrentCultureIgnoreCase))
            {
                groupList.Items.Add(group);
            }
            groupList.SelectedIndexChanged += (s, e) =>
            {
                if (groupList.SelectedItem == null) return;
                var selected = Convert.ToString(groupList.SelectedItem);
                valueBox.Text = selected == "(No group)" ? string.Empty : selected;
            };
            groupList.DoubleClick += (s, e) =>
            {
                DialogResult = DialogResult.OK;
                Close();
            };
            groupList.KeyDown += (s, e) =>
            {
                if (e.KeyCode == Keys.Enter)
                {
                    e.Handled = true;
                    DialogResult = DialogResult.OK;
                    Close();
                }
            };
            Controls.Add(groupList);

            var ok = new Button
            {
                Text = "OK",
                DialogResult = DialogResult.OK,
                Location = new Point(383, 230),
                Width = 85
            };
            Controls.Add(ok);

            var cancel = new Button
            {
                Text = "Cancel",
                DialogResult = DialogResult.Cancel,
                Location = new Point(478, 230),
                Width = 85
            };
            Controls.Add(cancel);

            AcceptButton = ok;
            CancelButton = cancel;
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            valueBox.Focus();
            valueBox.SelectAll();
        }
    }
}
