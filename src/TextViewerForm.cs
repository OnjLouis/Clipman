using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class FocusableImagePreview : Control
    {
        private readonly Image previewImage;

        public FocusableImagePreview(Image image, string accessibleName, string accessibleDescription)
        {
            if (image == null) throw new ArgumentNullException("image");
            previewImage = image;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.ResizeRedraw | ControlStyles.Selectable | ControlStyles.UserPaint, true);
            TabStop = true;
            BackColor = SystemColors.Window;
            AccessibleRole = AccessibleRole.Graphic;
            AccessibleName = accessibleName ?? "Image preview";
            AccessibleDescription = accessibleDescription ?? string.Empty;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            e.Graphics.Clear(BackColor);
            if (previewImage.Width > 0 && previewImage.Height > 0 && ClientSize.Width > 0 && ClientSize.Height > 0)
            {
                var scale = Math.Min((double)ClientSize.Width / previewImage.Width, (double)ClientSize.Height / previewImage.Height);
                var width = Math.Max(1, (int)Math.Round(previewImage.Width * scale));
                var height = Math.Max(1, (int)Math.Round(previewImage.Height * scale));
                var bounds = new Rectangle((ClientSize.Width - width) / 2, (ClientSize.Height - height) / 2, width, height);
                e.Graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                e.Graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                e.Graphics.DrawImage(previewImage, bounds);
            }
            if (Focused && ShowFocusCues && ClientSize.Width > 4 && ClientSize.Height > 4)
            {
                var focusBounds = ClientRectangle;
                focusBounds.Inflate(-2, -2);
                ControlPaint.DrawFocusRectangle(e.Graphics, focusBounds);
            }
        }

        protected override void OnGotFocus(EventArgs e)
        {
            base.OnGotFocus(e);
            Invalidate();
        }

        protected override void OnLostFocus(EventArgs e)
        {
            base.OnLostFocus(e);
            Invalidate();
        }
    }

    internal sealed class TextViewerForm : Form
    {
        private readonly TextBoxBase textBox;
        private readonly ListView linksList;
        private readonly Control focusControl;
        private readonly Image previewImage;
        private readonly Func<string, bool> copySelection;
        private readonly Action<Uri> openLink;

        public TextViewerForm(string text)
            : this("Clipman Entry Text", text, "Clipboard entry text", "Read-only clipboard entry text.", false, null)
        {
        }

        public TextViewerForm(string title, string text, string accessibleName, string accessibleDescription, bool showCopyButton)
            : this(title, text, accessibleName, accessibleDescription, showCopyButton, null)
        {
        }

        public TextViewerForm(string title, string text, string accessibleName, string accessibleDescription, bool showCopyButton, IReadOnlyList<KeyValuePair<string, string>> details)
            : this(title, text, accessibleName, accessibleDescription, showCopyButton, details, null)
        {
        }

        public TextViewerForm(string title, string text, string accessibleName, string accessibleDescription, bool showCopyButton, IReadOnlyList<KeyValuePair<string, string>> details, RichTextPayload richText, Func<string, bool> copySelection = null, Action<Uri> openLink = null)
        {
            this.copySelection = copySelection;
            this.openLink = openLink;
            Text = title;
            StartPosition = FormStartPosition.CenterParent;
            Width = 850;
            Height = 600;
            KeyPreview = true;

            var normalizedRichText = RichTextData.Normalize(richText);
            RichImageInfo embeddedImage;
            var hasEmbeddedImage = RichImageData.TryDecode(normalizedRichText, out embeddedImage);
            if (normalizedRichText != null && !string.IsNullOrEmpty(normalizedRichText.RtfBase64))
            {
                var richViewer = new RichTextBox
                {
                    Dock = DockStyle.Fill,
                    ReadOnly = true,
                    ScrollBars = RichTextBoxScrollBars.Both,
                    WordWrap = false,
                    DetectUrls = true,
                    AccessibleName = accessibleName,
                    AccessibleDescription = accessibleDescription
                };
                try
                {
                    richViewer.Rtf = System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(normalizedRichText.RtfBase64));
                }
                catch
                {
                    richViewer.Text = text ?? string.Empty;
                }
                textBox = richViewer;
            }
            else
            {
                textBox = new TextBox
                {
                    Dock = DockStyle.Fill,
                    Multiline = true,
                    ReadOnly = true,
                    ScrollBars = ScrollBars.Both,
                    WordWrap = false,
                    Text = text ?? string.Empty,
                    AccessibleName = accessibleName,
                    AccessibleDescription = accessibleDescription
                };
            }
            Control primaryControl = textBox;
            if (hasEmbeddedImage)
            {
                previewImage = new Bitmap(embeddedImage.Image);
                var imageName = string.IsNullOrWhiteSpace(embeddedImage.FileName) ? "clipboard image" : embeddedImage.FileName;
                var picture = new FocusableImagePreview(
                    previewImage,
                    "Image preview, " + imageName + ", " + embeddedImage.Width + " by " + embeddedImage.Height + " pixels",
                    embeddedImage.MimeType + ".")
                {
                    Dock = DockStyle.Fill
                };
                embeddedImage.Dispose();
                var imagePanel = new TableLayoutPanel
                {
                    Dock = DockStyle.Fill,
                    ColumnCount = 1,
                    RowCount = 2
                };
                imagePanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
                imagePanel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
                imagePanel.RowStyles.Add(new RowStyle(SizeType.Absolute, 64));
                imagePanel.Controls.Add(picture, 0, 0);
                imagePanel.Controls.Add(textBox, 0, 1);
                primaryControl = imagePanel;
                focusControl = picture;
            }
            else
            {
                if (embeddedImage != null) embeddedImage.Dispose();
                focusControl = textBox;
            }

            if (copySelection != null)
            {
                textBox.PreviewKeyDown += KeepEnterInControl;
                textBox.KeyDown += (s, e) =>
                {
                    if (e.KeyData != Keys.Enter) return;
                    e.SuppressKeyPress = true;
                    if (textBox.SelectionLength > 0) CopyPreviewText(textBox.SelectedText);
                };
            }

            var hasDetails = details != null && details.Count > 0;
            if (openLink != null)
            {
                var urls = LinkPresentation.WebUrisIn(textBox.Text);
                if (!string.Equals(textBox.Text, text, StringComparison.Ordinal))
                    urls = urls.Concat(LinkPresentation.WebUrisIn(text));
                var destinations = urls.GroupBy(uri => uri.OriginalString, StringComparer.Ordinal).Select(group => group.First()).ToArray();
                if (destinations.Length > 0)
                {
                    linksList = new ListView
                    {
                        Dock = DockStyle.Fill,
                        View = View.Details,
                        HeaderStyle = ColumnHeaderStyle.None,
                        FullRowSelect = true,
                        MultiSelect = false,
                        HideSelection = false,
                        TabIndex = 1,
                        AccessibleName = "Links",
                        AccessibleDescription = "Use the arrow keys to select a link. Control+C copies its address. Enter opens it. The Application key opens its menu."
                    };
                    linksList.Columns.Add("Address", 750);
                    linksList.Resize += (s, e) => linksList.Columns[0].Width = Math.Max(1, linksList.ClientSize.Width - SystemInformation.VerticalScrollBarWidth);
                    foreach (var link in destinations)
                        linksList.Items.Add(new ListViewItem(link.OriginalString) { Tag = link });
                    linksList.Items[0].Selected = true;
                    linksList.Items[0].Focused = true;

                    var menu = new ContextMenuStrip();
                    menu.Items.Add("&Copy Link\tCtrl+C", null, (s, e) => CopySelectedLink());
                    menu.Items.Add("&Open Link\tEnter", null, (s, e) => OpenPreviewLink(SelectedLink()));
                    menu.Opening += (s, e) => e.Cancel = SelectedLink() == null;
                    linksList.ContextMenuStrip = menu;
                    linksList.PreviewKeyDown += (s, e) =>
                    {
                        if (e.KeyData == Keys.Enter || IsLinksMenuKey(e.KeyData)) e.IsInputKey = true;
                    };
                    linksList.KeyDown += (s, e) =>
                    {
                        if (e.KeyData == Keys.Enter) OpenPreviewLink(SelectedLink());
                        else if (IsLinksMenuKey(e.KeyData)) ShowLinksMenu();
                        else return;
                        e.SuppressKeyPress = true;
                    };
                    linksList.MouseDoubleClick += (s, e) =>
                    {
                        var item = linksList.GetItemAt(e.X, e.Y);
                        if (item != null) OpenPreviewLink(item.Tag as Uri);
                    };
                }
            }

            var content = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 1,
                RowCount = 1 + (linksList == null ? 0 : 1) + (hasDetails ? 1 : 0)
            };
            content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            content.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            primaryControl.TabIndex = 0;
            content.Controls.Add(primaryControl, 0, 0);
            if (linksList != null)
            {
                content.RowStyles.Add(new RowStyle(SizeType.Absolute, 105));
                content.Controls.Add(linksList, 0, 1);
            }

            if (hasDetails)
            {
                content.RowStyles.Add(new RowStyle(SizeType.Absolute, 145));
                var detailsList = new ListView
                {
                    Dock = DockStyle.Fill,
                    View = View.Details,
                    FullRowSelect = true,
                    MultiSelect = false,
                    HeaderStyle = ColumnHeaderStyle.None,
                    HideSelection = false,
                    TabIndex = 2,
                    AccessibleName = "Entry details",
                    AccessibleDescription = "Use the arrow keys to select a detail. F1 explains the selected detail."
                };
                detailsList.Columns.Add("Property", 180);
                detailsList.Columns.Add("Value", 590);
                foreach (var detail in details)
                {
                    var item = new ListViewItem(detail.Key);
                    item.SubItems.Add(detail.Value ?? string.Empty);
                    detailsList.Items.Add(item);
                }
                detailsList.Items[0].Selected = true;
                detailsList.Items[0].Focused = true;
                content.Controls.Add(detailsList, 0, content.RowCount - 1);
            }

            Controls.Add(content);

            var buttons = new FlowLayoutPanel
            {
                Dock = DockStyle.Bottom,
                FlowDirection = FlowDirection.RightToLeft,
                Height = 42
            };
            var close = new Button
            {
                Text = "Close",
                Width = 90,
                DialogResult = DialogResult.OK
            };
            buttons.Controls.Add(close);
            if (showCopyButton)
            {
                var copy = new Button
                {
                    Text = "Copy",
                    Width = 90
                };
                copy.Click += (s, e) =>
                {
                    Clipboard.SetText(textBox.Text ?? string.Empty, TextDataFormat.UnicodeText);
                };
                buttons.Controls.Add(copy);
            }
            Controls.Add(buttons);

            AcceptButton = close;
            CancelButton = close;
            ContextHelp.Prepare(this, true);
            Shown += (s, e) =>
            {
                textBox.SelectionStart = 0;
                textBox.SelectionLength = 0;
                ActiveControl = focusControl;
                focusControl.Focus();
            };
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                if (previewImage != null) previewImage.Dispose();
                if (linksList != null) linksList.ContextMenuStrip.Dispose();
            }
            base.Dispose(disposing);
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            if (linksList != null && linksList.Focused)
            {
                if (keyData == (Keys.Control | Keys.C) && copySelection != null)
                {
                    CopySelectedLink();
                    return true;
                }
                if (keyData == (Keys.Alt | Keys.Enter))
                {
                    OpenPreviewLink(SelectedLink());
                    return true;
                }
            }
            if (textBox.Focused && keyData == (Keys.Alt | Keys.Enter) && openLink != null)
            {
                OpenPreviewLink(LinkPresentation.WebUriAtSelection(textBox.Text, textBox.SelectionStart, textBox.SelectionLength));
                return true;
            }
            return base.ProcessCmdKey(ref msg, keyData);
        }

        private static void KeepEnterInControl(object sender, PreviewKeyDownEventArgs e)
        {
            if (e.KeyData == Keys.Enter) e.IsInputKey = true;
        }

        private static bool IsLinksMenuKey(Keys keyData)
        {
            return keyData == Keys.Apps || keyData == (Keys.Shift | Keys.F10);
        }

        private Uri SelectedLink()
        {
            return linksList.SelectedItems.Count == 1 ? linksList.SelectedItems[0].Tag as Uri : null;
        }

        private void CopySelectedLink()
        {
            var link = SelectedLink();
            if (link != null && copySelection != null) CopyPreviewText(link.OriginalString);
        }

        private void ShowLinksMenu()
        {
            if (SelectedLink() == null) return;
            var selected = linksList.SelectedItems[0];
            selected.EnsureVisible();
            linksList.ContextMenuStrip.Show(linksList, new Point(selected.Bounds.Left + 8, selected.Bounds.Bottom));
        }

        private void CopyPreviewText(string text)
        {
            if (!copySelection(text)) ShowShortcutError("Could not copy the selected text.");
        }

        private void OpenPreviewLink(Uri uri)
        {
            if (uri == null)
            {
                System.Media.SystemSounds.Beep.Play();
                return;
            }
            try { openLink(uri); }
            catch (Exception) { ShowShortcutError("Could not open the selected link."); }
        }

        private void ShowShortcutError(string message)
        {
            MessageBox.Show(this, message, Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.Control && e.KeyCode == Keys.A)
            {
                textBox.SelectAll();
                e.Handled = true;
                e.SuppressKeyPress = true;
                return;
            }
            if (e.KeyCode == Keys.Escape)
            {
                Close();
                e.Handled = true;
                return;
            }
            base.OnKeyDown(e);
        }
    }
}
