using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace Clipman
{
    /// <summary>
    /// Windows editor for the sync rules document (sync-rules-spec.md sections 3-5). Mutates a
    /// working copy of the document and calls <see cref="ClipStore.SetSyncRules"/> only on OK.
    /// </summary>
    internal sealed class SyncRulesForm : Form
    {
        private readonly ClipStore store;
        private readonly string deviceName;
        private readonly bool readOnly;
        private readonly SyncRulesDocument document;

        private readonly CheckBox enabledBox;
        private readonly ListView channelsList;
        private readonly Button addChannelButton;
        private readonly Button editChannelButton;
        private readonly Button removeChannelButton;
        private readonly Label channelStatusLabel;
        private readonly ListView devicesList;
        private readonly Button editSubscriptionsButton;
        private readonly Button okButton;
        private readonly Button cancelButton;

        public bool Applied { get; private set; }

        public SyncRulesForm(ClipStore store, string deviceName)
        {
            this.store = store;
            this.deviceName = (deviceName ?? string.Empty).Trim();
            readOnly = store.SyncRulesReadOnly();
            document = store.GetSyncRules() ?? new SyncRulesDocument();

            Text = "Sync Rules";
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MinimizeBox = false;
            MaximizeBox = false;
            ShowInTaskbar = false;
            ClientSize = new Size(616, 570);
            KeyPreview = true;

            enabledBox = new CheckBox
            {
                Text = "&Enable sync rules",
                Location = new Point(12, 12),
                AutoSize = true,
                Checked = document.Enabled,
                AccessibleName = "Enable sync rules",
                AccessibleDescription = "When checked, clipboard history can be split into named channels so only the devices you choose receive each channel."
            };
            Controls.Add(enabledBox);

            var warningLabel = new Label
            {
                Text = "Enable sync rules only after every device runs a Clipman version that supports them. Older devices will continue to sync the main history only.",
                Location = new Point(12, 38),
                Size = new Size(592, 36),
                AccessibleName = "Compatibility warning"
            };
            Controls.Add(warningLabel);

            var readOnlyLabel = new Label
            {
                Text = "These rules were created by a newer Clipman version and can be viewed but not changed here.",
                Location = new Point(12, 78),
                Size = new Size(592, 32),
                Visible = readOnly,
                AccessibleName = "Read-only notice"
            };
            Controls.Add(readOnlyLabel);

            var channelsGroup = new GroupBox
            {
                Text = "C&hannels",
                Location = new Point(12, 114),
                Size = new Size(592, 230)
            };
            channelsList = new ListView
            {
                Location = new Point(12, 22),
                Size = new Size(462, 172),
                View = View.Details,
                FullRowSelect = true,
                HideSelection = false,
                MultiSelect = false,
                AccessibleName = "Sync channels",
                AccessibleDescription = "Named channels and their routing rule. Press Enter or double-click a channel to edit it."
            };
            channelsList.Columns.Add("Name", 190);
            channelsList.Columns.Add("Rule", 258);
            channelsList.SelectedIndexChanged += (s, e) => UpdateChannelButtonStates();
            channelsList.DoubleClick += (s, e) => EditSelectedChannel();
            channelsList.KeyDown += ChannelsListKeyDown;
            channelsGroup.Controls.Add(channelsList);

            addChannelButton = new Button
            {
                Text = "&Add...",
                Location = new Point(486, 22),
                Size = new Size(94, 28),
                AccessibleName = "Add channel",
                AccessibleDescription = "Opens the channel editor to create a new sync channel."
            };
            addChannelButton.Click += (s, e) => AddChannel();
            channelsGroup.Controls.Add(addChannelButton);

            editChannelButton = new Button
            {
                Text = "Ed&it...",
                Location = new Point(486, 58),
                Size = new Size(94, 28),
                AccessibleName = "Edit channel",
                AccessibleDescription = "Opens the channel editor for the selected channel."
            };
            editChannelButton.Click += (s, e) => EditSelectedChannel();
            channelsGroup.Controls.Add(editChannelButton);

            removeChannelButton = new Button
            {
                Text = "&Remove",
                Location = new Point(486, 94),
                Size = new Size(94, 28),
                AccessibleName = "Remove channel"
            };
            removeChannelButton.Click += (s, e) => RemoveSelectedChannel();
            channelsGroup.Controls.Add(removeChannelButton);

            channelStatusLabel = new Label
            {
                Location = new Point(12, 198),
                Size = new Size(462, 28),
                AccessibleName = "Remove channel status"
            };
            channelsGroup.Controls.Add(channelStatusLabel);

            Controls.Add(channelsGroup);

            var devicesGroup = new GroupBox
            {
                Text = "&Devices",
                Location = new Point(12, 352),
                Size = new Size(592, 168)
            };
            devicesList = new ListView
            {
                Location = new Point(12, 22),
                Size = new Size(462, 132),
                View = View.Details,
                FullRowSelect = true,
                HideSelection = false,
                MultiSelect = false,
                AccessibleName = "Devices",
                AccessibleDescription = "Devices and the channels each one receives. Press Enter or double-click a device to edit its subscriptions."
            };
            devicesList.Columns.Add("Device", 220);
            devicesList.Columns.Add("Receives", 220);
            devicesList.SelectedIndexChanged += (s, e) => UpdateDeviceButtonStates();
            devicesList.DoubleClick += (s, e) => EditSelectedDeviceSubscriptions();
            devicesList.KeyDown += DevicesListKeyDown;
            devicesGroup.Controls.Add(devicesList);

            editSubscriptionsButton = new Button
            {
                Text = "Edit s&ubscriptions...",
                Location = new Point(486, 22),
                Size = new Size(94, 46),
                AccessibleName = "Edit subscriptions",
                AccessibleDescription = "Opens the subscription editor for the selected device."
            };
            editSubscriptionsButton.Click += (s, e) => EditSelectedDeviceSubscriptions();
            devicesGroup.Controls.Add(editSubscriptionsButton);

            Controls.Add(devicesGroup);

            okButton = new Button
            {
                Text = "OK",
                Location = new Point(426, 528),
                Size = new Size(85, 28),
                DialogResult = DialogResult.None,
                AccessibleName = "OK"
            };
            okButton.Click += (s, e) => AcceptChanges();
            Controls.Add(okButton);

            cancelButton = new Button
            {
                Text = "Cancel",
                Location = new Point(519, 528),
                Size = new Size(85, 28),
                DialogResult = DialogResult.Cancel,
                AccessibleName = "Cancel"
            };
            Controls.Add(cancelButton);

            AcceptButton = okButton;
            CancelButton = cancelButton;

            if (readOnly)
            {
                enabledBox.Enabled = false;
                addChannelButton.Enabled = false;
            }

            RefreshChannelsList();
            RefreshDevicesList();
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            if (!readOnly)
            {
                enabledBox.Focus();
            }
            else
            {
                cancelButton.Focus();
            }
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

        private void ChannelsListKeyDown(object sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Enter)
            {
                EditSelectedChannel();
                e.Handled = true;
            }
        }

        private void DevicesListKeyDown(object sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Enter)
            {
                EditSelectedDeviceSubscriptions();
                e.Handled = true;
            }
        }

        private void AcceptChanges()
        {
            if (readOnly)
            {
                DialogResult = DialogResult.Cancel;
                Close();
                return;
            }

            document.Enabled = enabledBox.Checked;
            var error = store.SetSyncRules(document);
            if (error != null)
            {
                MessageBox.Show(this, error, "Clipman Sync Rules", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            Applied = true;
            DialogResult = DialogResult.OK;
            Close();
        }

        // -----------------------------------------------------------------------------------
        // Channels
        // -----------------------------------------------------------------------------------

        private void RefreshChannelsList()
        {
            var previousKey = SelectedChannelKey();
            channelsList.BeginUpdate();
            try
            {
                channelsList.Items.Clear();
                foreach (var channel in document.Channels)
                {
                    if (channel == null) continue;
                    var item = new ListViewItem(channel.Name ?? string.Empty);
                    item.SubItems.Add(SyncRuleEngine.RouteSummary(channel.Route));
                    item.Tag = channel;
                    channelsList.Items.Add(item);
                }
            }
            finally
            {
                channelsList.EndUpdate();
            }

            var index = FindChannelIndex(previousKey);
            if (index < 0 && channelsList.Items.Count > 0) index = 0;
            if (index >= 0)
            {
                channelsList.Items[index].Selected = true;
                channelsList.Items[index].Focused = true;
            }
            UpdateChannelButtonStates();
        }

        private string SelectedChannelKey()
        {
            if (channelsList.SelectedItems.Count == 0) return string.Empty;
            var channel = channelsList.SelectedItems[0].Tag as SyncChannel;
            return channel == null ? string.Empty : SyncRuleEngine.ChannelKey(channel.Name);
        }

        private int FindChannelIndex(string key)
        {
            if (string.IsNullOrEmpty(key)) return -1;
            for (var i = 0; i < channelsList.Items.Count; i++)
            {
                var channel = channelsList.Items[i].Tag as SyncChannel;
                if (channel != null && SyncRuleEngine.ChannelKey(channel.Name) == key) return i;
            }
            return -1;
        }

        private void UpdateChannelButtonStates()
        {
            var hasSelection = channelsList.SelectedItems.Count > 0;
            editChannelButton.Enabled = !readOnly && hasSelection;

            if (readOnly || !hasSelection)
            {
                removeChannelButton.Enabled = false;
                removeChannelButton.AccessibleDescription = "Select a channel to remove.";
                channelStatusLabel.Text = string.Empty;
                return;
            }

            var channel = (SyncChannel)channelsList.SelectedItems[0].Tag;
            var key = SyncRuleEngine.ChannelKey(channel.Name);
            var subscribed = SyncRuleEngine.SubscribedChannels(document, deviceName);
            var canSee = subscribed == null || subscribed.Contains(key);
            removeChannelButton.Enabled = canSee;
            if (canSee)
            {
                removeChannelButton.AccessibleDescription =
                    "Removes the selected channel. Its entries move to the next matching channel or to the main history.";
                channelStatusLabel.Text = string.Empty;
            }
            else
            {
                var notice = "Remove is unavailable: this device is not subscribed to " + (channel.Name ?? key) +
                    " and cannot see its entries. Subscribe this device to the channel first.";
                removeChannelButton.AccessibleDescription = notice;
                channelStatusLabel.Text = notice;
            }
        }

        private void AddChannel()
        {
            using (var dialog = new SyncChannelEditorForm(null, store.GetGroups(), store.GetDevices(), document, -1))
            {
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    document.Channels.Add(dialog.Result);
                    RefreshChannelsList();
                    RefreshDevicesList();
                }
            }
        }

        private void EditSelectedChannel()
        {
            if (readOnly || channelsList.SelectedItems.Count == 0) return;
            var channel = (SyncChannel)channelsList.SelectedItems[0].Tag;
            var index = document.Channels.IndexOf(channel);
            if (index < 0) return;

            using (var dialog = new SyncChannelEditorForm(channel, store.GetGroups(), store.GetDevices(), document, index))
            {
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    document.Channels[index] = dialog.Result;
                    RefreshChannelsList();
                    RefreshDevicesList();
                }
            }
        }

        private void RemoveSelectedChannel()
        {
            if (readOnly || channelsList.SelectedItems.Count == 0) return;
            var channel = (SyncChannel)channelsList.SelectedItems[0].Tag;
            var key = SyncRuleEngine.ChannelKey(channel.Name);

            var subscribed = SyncRuleEngine.SubscribedChannels(document, deviceName);
            if (subscribed != null && !subscribed.Contains(key))
            {
                MessageBox.Show(this,
                    "This device is not subscribed to the " + channel.Name +
                        " channel and cannot see its entries. Subscribe to it before removing it.",
                    "Clipman Sync Rules", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            var confirm = MessageBox.Show(this,
                "Entries in this channel will move to the next matching channel or to the main history. No entries are deleted.",
                "Remove Channel", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (confirm != DialogResult.Yes) return;

            document.Channels.Remove(channel);
            foreach (var device in document.Devices)
            {
                if (device == null || device.Channels == null) continue;
                if (device.Channels.Count == 1 && (device.Channels[0] ?? string.Empty).Trim() == "*") continue;
                device.Channels.RemoveAll(candidate =>
                    string.Equals((candidate ?? string.Empty).Trim(), key, StringComparison.OrdinalIgnoreCase));
            }

            RefreshChannelsList();
            RefreshDevicesList();
        }

        // -----------------------------------------------------------------------------------
        // Devices
        // -----------------------------------------------------------------------------------

        private void RefreshDevicesList()
        {
            var previousName = SelectedDeviceName();
            var names = new List<string>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var device in document.Devices)
            {
                if (device == null) continue;
                var name = (device.Name ?? string.Empty).Trim();
                if (name.Length == 0) continue;
                if (seen.Add(name)) names.Add(name);
            }
            foreach (var name in store.GetDevices())
            {
                if (seen.Add(name)) names.Add(name);
            }
            names.Sort(StringComparer.CurrentCultureIgnoreCase);

            devicesList.BeginUpdate();
            try
            {
                devicesList.Items.Clear();
                foreach (var name in names)
                {
                    var device = FindDevice(name);
                    var receives = device == null
                        ? SyncRuleEngine.SubscriptionSummary(new List<string> { "*" })
                        : SyncRuleEngine.SubscriptionSummary(device.Channels);
                    var item = new ListViewItem(name);
                    item.SubItems.Add(receives);
                    item.Tag = name;
                    devicesList.Items.Add(item);
                }
            }
            finally
            {
                devicesList.EndUpdate();
            }

            var index = -1;
            for (var i = 0; i < names.Count; i++)
            {
                if (string.Equals(names[i], previousName, StringComparison.OrdinalIgnoreCase))
                {
                    index = i;
                    break;
                }
            }
            if (index < 0 && devicesList.Items.Count > 0) index = 0;
            if (index >= 0)
            {
                devicesList.Items[index].Selected = true;
                devicesList.Items[index].Focused = true;
            }
            UpdateDeviceButtonStates();
        }

        private SyncDevice FindDevice(string name)
        {
            foreach (var device in document.Devices)
            {
                if (device != null && string.Equals((device.Name ?? string.Empty).Trim(), name, StringComparison.OrdinalIgnoreCase))
                {
                    return device;
                }
            }
            return null;
        }

        private string SelectedDeviceName()
        {
            return devicesList.SelectedItems.Count == 0 ? string.Empty : Convert.ToString(devicesList.SelectedItems[0].Tag);
        }

        private void UpdateDeviceButtonStates()
        {
            editSubscriptionsButton.Enabled = !readOnly && devicesList.SelectedItems.Count > 0;
        }

        private void EditSelectedDeviceSubscriptions()
        {
            if (readOnly || devicesList.SelectedItems.Count == 0) return;
            var name = SelectedDeviceName();
            var existing = FindDevice(name);
            var currentChannels = existing == null ? new List<string> { "*" } : new List<string>(existing.Channels ?? new List<string>());

            using (var dialog = new SyncDeviceSubscriptionForm(name, document.Channels, currentChannels))
            {
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    if (existing == null)
                    {
                        existing = new SyncDevice { Name = name };
                        document.Devices.Add(existing);
                    }
                    existing.Channels = dialog.SelectedChannels;
                    RefreshDevicesList();
                }
            }
        }
    }

    /// <summary>
    /// Adds or edits one sync channel. Validates the whole prospective document (this channel
    /// replacing or joining <paramref name="contextDocument"/>) via <see cref="SyncRuleEngine"/>
    /// before accepting, so uniqueness, reserved names, and storage-name collisions are caught here.
    /// </summary>
    internal sealed class SyncChannelEditorForm : Form
    {
        private readonly SyncRulesDocument contextDocument;
        private readonly int editingIndex;
        private readonly TextBox nameBox;
        private readonly CheckedListBox groupsBox;
        private readonly TextBox otherGroupsBox;
        private readonly CheckedListBox devicesBox;
        private readonly TextBox otherDevicesBox;
        private readonly CheckBox richTextImagesBox;

        public SyncChannel Result { get; private set; }

        public SyncChannelEditorForm(SyncChannel existing, List<string> knownGroups, List<string> knownDevices,
            SyncRulesDocument contextDocument, int editingIndex)
        {
            this.contextDocument = contextDocument;
            this.editingIndex = editingIndex;

            var route = existing == null ? new SyncRoute() : (existing.Route ?? new SyncRoute());
            var knownGroupList = knownGroups ?? new List<string>();
            var knownDeviceList = knownDevices ?? new List<string>();

            Text = existing == null ? "Add Sync Channel" : "Edit Sync Channel";
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MinimizeBox = false;
            MaximizeBox = false;
            ShowInTaskbar = false;
            ClientSize = new Size(460, 470);
            KeyPreview = true;

            var nameLabel = new Label { Text = "&Name:", Location = new Point(12, 14), AutoSize = true };
            Controls.Add(nameLabel);
            nameBox = new TextBox
            {
                Location = new Point(100, 10),
                Width = 340,
                Text = existing == null ? string.Empty : (existing.Name ?? string.Empty),
                AccessibleName = "Channel name",
                AccessibleDescription = "Lowercase letters, digits, spaces, hyphens, and underscores, 1 to 32 characters. The names core, all, pinned, and sync-rules are reserved."
            };
            Controls.Add(nameBox);

            var groupsLabel = new Label { Text = "&Groups:", Location = new Point(12, 48), AutoSize = true };
            Controls.Add(groupsLabel);
            groupsBox = new CheckedListBox
            {
                Location = new Point(12, 66),
                Size = new Size(420, 90),
                CheckOnClick = true,
                AccessibleName = "Groups that route into this channel"
            };
            var checkedGroups = new List<string>(route.Groups ?? new List<string>());
            var extraGroups = new List<string>();
            foreach (var group in knownGroupList)
            {
                groupsBox.Items.Add(group, ContainsFold(checkedGroups, group));
            }
            foreach (var group in checkedGroups)
            {
                if (!ContainsFold(knownGroupList, group)) extraGroups.Add(group);
            }
            Controls.Add(groupsBox);

            var otherGroupsLabel = new Label { Text = "Ot&her groups (comma separated):", Location = new Point(12, 160), AutoSize = true };
            Controls.Add(otherGroupsLabel);
            otherGroupsBox = new TextBox
            {
                Location = new Point(12, 178),
                Width = 420,
                Text = string.Join(", ", extraGroups.ToArray()),
                AccessibleName = "Other groups",
                AccessibleDescription = "Additional group names not listed above, separated by commas."
            };
            Controls.Add(otherGroupsBox);

            var devicesLabel = new Label { Text = "Source de&vices:", Location = new Point(12, 210), AutoSize = true };
            Controls.Add(devicesLabel);
            devicesBox = new CheckedListBox
            {
                Location = new Point(12, 228),
                Size = new Size(420, 90),
                CheckOnClick = true,
                AccessibleName = "Source devices this channel captures from"
            };
            var checkedDevices = new List<string>(route.SourceDevices ?? new List<string>());
            var extraDevices = new List<string>();
            foreach (var device in knownDeviceList)
            {
                devicesBox.Items.Add(device, ContainsFold(checkedDevices, device));
            }
            foreach (var device in checkedDevices)
            {
                if (!ContainsFold(knownDeviceList, device)) extraDevices.Add(device);
            }
            Controls.Add(devicesBox);

            var otherDevicesLabel = new Label { Text = "Other so&urce devices (comma separated):", Location = new Point(12, 322), AutoSize = true };
            Controls.Add(otherDevicesLabel);
            otherDevicesBox = new TextBox
            {
                Location = new Point(12, 340),
                Width = 420,
                Text = string.Join(", ", extraDevices.ToArray()),
                AccessibleName = "Other source devices",
                AccessibleDescription = "Additional device names not listed above, separated by commas."
            };
            Controls.Add(otherDevicesBox);

            richTextImagesBox = new CheckBox
            {
                Text = "&Rich text images",
                Location = new Point(12, 372),
                AutoSize = true,
                Checked = string.Equals(route.Kind, "RichTextImages", StringComparison.Ordinal),
                AccessibleName = "Rich text images",
                AccessibleDescription = "Routes rich-text entries that contain an embedded image into this channel."
            };
            Controls.Add(richTextImagesBox);

            var ok = new Button { Text = "OK", Location = new Point(270, 410), Size = new Size(85, 28), DialogResult = DialogResult.None, AccessibleName = "OK" };
            ok.Click += (s, e) => AcceptChannel();
            Controls.Add(ok);
            var cancel = new Button { Text = "Cancel", Location = new Point(363, 410), Size = new Size(85, 28), DialogResult = DialogResult.Cancel, AccessibleName = "Cancel" };
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

        private void AcceptChannel()
        {
            var candidate = new SyncChannel
            {
                Name = nameBox.Text.Trim(),
                Route = new SyncRoute
                {
                    Groups = CombineChecked(groupsBox, otherGroupsBox.Text),
                    SourceDevices = CombineChecked(devicesBox, otherDevicesBox.Text),
                    Kind = richTextImagesBox.Checked ? "RichTextImages" : string.Empty
                }
            };

            var trial = SyncRuleEngine.Copy(contextDocument) ?? new SyncRulesDocument();
            if (editingIndex >= 0 && editingIndex < trial.Channels.Count)
            {
                trial.Channels[editingIndex] = candidate;
            }
            else
            {
                trial.Channels.Add(candidate);
            }

            var error = SyncRuleEngine.Validate(trial);
            if (error != null)
            {
                MessageBox.Show(this, error, "Clipman Sync Rules", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                nameBox.Focus();
                return;
            }

            Result = candidate;
            DialogResult = DialogResult.OK;
            Close();
        }

        private static List<string> CombineChecked(CheckedListBox list, string extraText)
        {
            var result = new List<string>();
            foreach (var item in list.CheckedItems)
            {
                var text = Convert.ToString(item);
                if (!ContainsFold(result, text)) result.Add(text);
            }
            foreach (var extra in ParseCommaList(extraText))
            {
                if (!ContainsFold(result, extra)) result.Add(extra);
            }
            return result;
        }

        private static List<string> ParseCommaList(string text)
        {
            var result = new List<string>();
            foreach (var part in (text ?? string.Empty).Split(','))
            {
                var trimmed = part.Trim();
                if (trimmed.Length > 0 && !ContainsFold(result, trimmed)) result.Add(trimmed);
            }
            return result;
        }

        private static bool ContainsFold(List<string> list, string value)
        {
            foreach (var item in list)
            {
                if (string.Equals(item, value, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }
    }

    /// <summary>
    /// Edits one device's channel subscription list: either the "*" wildcard (all channels) or an
    /// explicit checked subset of the current channels in the rules document.
    /// </summary>
    internal sealed class SyncDeviceSubscriptionForm : Form
    {
        private readonly CheckBox allChannelsBox;
        private readonly CheckedListBox channelsBox;

        public List<string> SelectedChannels { get; private set; }

        public SyncDeviceSubscriptionForm(string deviceName, List<SyncChannel> allChannels, List<string> currentChannels)
        {
            var channels = allChannels ?? new List<SyncChannel>();
            var current = currentChannels ?? new List<string>();
            var isAll = current.Count == 1 && (current[0] ?? string.Empty).Trim() == "*";

            Text = "Edit Subscriptions - " + (deviceName ?? string.Empty);
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MinimizeBox = false;
            MaximizeBox = false;
            ShowInTaskbar = false;
            ClientSize = new Size(360, 320);
            KeyPreview = true;

            allChannelsBox = new CheckBox
            {
                Text = "&All channels",
                Location = new Point(12, 12),
                AutoSize = true,
                Checked = isAll,
                AccessibleName = "All channels",
                AccessibleDescription = "When checked, this device receives every channel, including ones added later. The main history is always received."
            };
            Controls.Add(allChannelsBox);

            var channelsLabel = new Label { Text = "&Channels received:", Location = new Point(12, 42), AutoSize = true };
            Controls.Add(channelsLabel);

            channelsBox = new CheckedListBox
            {
                Location = new Point(12, 60),
                Size = new Size(330, 190),
                CheckOnClick = true,
                Enabled = !isAll,
                AccessibleName = "Channels received",
                AccessibleDescription = "Channels this device downloads besides the main history."
            };
            foreach (var channel in channels)
            {
                if (channel == null) continue;
                var key = SyncRuleEngine.ChannelKey(channel.Name);
                var isChecked = isAll || ContainsFold(current, key);
                channelsBox.Items.Add(channel.Name, isChecked);
            }
            Controls.Add(channelsBox);

            allChannelsBox.CheckedChanged += (s, e) => channelsBox.Enabled = !allChannelsBox.Checked;

            var ok = new Button { Text = "OK", Location = new Point(178, 264), Size = new Size(85, 28), DialogResult = DialogResult.None, AccessibleName = "OK" };
            ok.Click += (s, e) => AcceptSubscriptions();
            Controls.Add(ok);
            var cancel = new Button { Text = "Cancel", Location = new Point(271, 264), Size = new Size(85, 28), DialogResult = DialogResult.Cancel, AccessibleName = "Cancel" };
            Controls.Add(cancel);
            AcceptButton = ok;
            CancelButton = cancel;
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            allChannelsBox.Focus();
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

        private void AcceptSubscriptions()
        {
            if (allChannelsBox.Checked)
            {
                SelectedChannels = new List<string> { "*" };
            }
            else
            {
                var result = new List<string>();
                for (var i = 0; i < channelsBox.Items.Count; i++)
                {
                    if (!channelsBox.GetItemChecked(i)) continue;
                    var name = Convert.ToString(channelsBox.Items[i]);
                    var key = SyncRuleEngine.ChannelKey(name);
                    if (key.Length > 0 && !result.Contains(key)) result.Add(key);
                }
                SelectedChannels = result;
            }

            DialogResult = DialogResult.OK;
            Close();
        }

        private static bool ContainsFold(List<string> list, string value)
        {
            foreach (var item in list)
            {
                if (string.Equals((item ?? string.Empty).Trim(), value, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }
    }
}
