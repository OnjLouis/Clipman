using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class RunningProcessPickerForm : Form
    {
        private readonly ListView processList;

        public string SelectedProcessName { get; private set; }

        public RunningProcessPickerForm()
        {
            Text = "Choose Running Application";
            StartPosition = FormStartPosition.CenterParent;
            Width = 720;
            Height = 500;
            MinimizeBox = false;
            MaximizeBox = false;
            ShowInTaskbar = false;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            KeyPreview = true;

            var label = new Label
            {
                Text = "Choose an application to ignore:",
                Left = 12,
                Top = 12,
                Width = 650,
                Height = 24
            };
            Controls.Add(label);

            processList = new ListView
            {
                Left = 12,
                Top = 40,
                Width = 680,
                Height = 360,
                View = View.Details,
                FullRowSelect = true,
                HideSelection = false,
                MultiSelect = false,
                AccessibleName = "Running applications",
                AccessibleDescription = "Running process names. Press Enter to add the selected process to ignored applications."
            };
            processList.Columns.Add("Process", 180);
            processList.Columns.Add("Window title", 470);
            processList.DoubleClick += (s, e) => AcceptSelection();
            processList.KeyDown += (s, e) =>
            {
                if (e.KeyCode == Keys.Enter)
                {
                    AcceptSelection();
                    e.Handled = true;
                }
            };
            Controls.Add(processList);

            var refresh = new Button
            {
                Text = "&Refresh",
                Left = 422,
                Top = 415,
                Width = 85
            };
            refresh.Click += (s, e) => PopulateProcesses();
            Controls.Add(refresh);

            var ok = new Button
            {
                Text = "OK",
                Left = 512,
                Top = 415,
                Width = 85,
                DialogResult = DialogResult.None
            };
            ok.Click += (s, e) => AcceptSelection();
            Controls.Add(ok);

            var cancel = new Button
            {
                Text = "Cancel",
                Left = 607,
                Top = 415,
                Width = 85,
                DialogResult = DialogResult.Cancel
            };
            Controls.Add(cancel);
            CancelButton = cancel;

            PopulateProcesses();
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            if (processList.Items.Count > 0)
            {
                processList.Items[0].Selected = true;
                processList.Items[0].Focused = true;
                processList.Focus();
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

        private void PopulateProcesses()
        {
            var selectedName = SelectedListProcessName();
            processList.BeginUpdate();
            try
            {
                processList.Items.Clear();
                foreach (var info in RunningProcessInfo())
                {
                    var item = new ListViewItem(info.ProcessName);
                    item.SubItems.Add(info.WindowTitle);
                    item.Tag = info.ProcessName;
                    processList.Items.Add(item);
                }
            }
            finally
            {
                processList.EndUpdate();
            }

            var index = FindProcessIndex(selectedName);
            if (index < 0 && processList.Items.Count > 0) index = 0;
            if (index >= 0)
            {
                processList.Items[index].Selected = true;
                processList.Items[index].Focused = true;
                processList.Items[index].EnsureVisible();
            }
        }

        private void AcceptSelection()
        {
            var processName = SelectedListProcessName();
            if (string.IsNullOrEmpty(processName)) return;
            SelectedProcessName = processName;
            DialogResult = DialogResult.OK;
            Close();
        }

        private string SelectedListProcessName()
        {
            if (processList.SelectedItems.Count == 0) return string.Empty;
            return Convert.ToString(processList.SelectedItems[0].Tag);
        }

        private int FindProcessIndex(string processName)
        {
            if (string.IsNullOrEmpty(processName)) return -1;
            for (var i = 0; i < processList.Items.Count; i++)
            {
                if (string.Equals(Convert.ToString(processList.Items[i].Tag), processName, StringComparison.OrdinalIgnoreCase))
                {
                    return i;
                }
            }

            return -1;
        }

        private static List<ProcessInfo> RunningProcessInfo()
        {
            var byName = new Dictionary<string, ProcessInfo>(StringComparer.OrdinalIgnoreCase);
            var currentProcessId = Process.GetCurrentProcess().Id;
            foreach (var process in Process.GetProcesses())
            {
                try
                {
                    if (process.Id == currentProcessId) continue;
                    var name = NormalizeProcessName(process.ProcessName);
                    if (string.IsNullOrEmpty(name)) continue;
                    var title = process.MainWindowTitle ?? string.Empty;
                    ProcessInfo existing;
                    if (!byName.TryGetValue(name, out existing))
                    {
                        byName[name] = new ProcessInfo { ProcessName = name, WindowTitle = title };
                    }
                    else if (string.IsNullOrEmpty(existing.WindowTitle) && !string.IsNullOrEmpty(title))
                    {
                        existing.WindowTitle = title;
                    }
                }
                catch
                {
                }
            }

            return byName.Values
                .OrderBy(p => p.ProcessName, StringComparer.CurrentCultureIgnoreCase)
                .ToList();
        }

        private static string NormalizeProcessName(string processName)
        {
            if (string.IsNullOrWhiteSpace(processName)) return string.Empty;
            var trimmed = processName.Trim();
            return trimmed.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
                ? Path.GetFileNameWithoutExtension(trimmed)
                : trimmed;
        }

        private sealed class ProcessInfo
        {
            public string ProcessName;
            public string WindowTitle;
        }
    }
}
