using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
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
        private readonly Control focusControl;
        private readonly Image previewImage;

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

        public TextViewerForm(string title, string text, string accessibleName, string accessibleDescription, bool showCopyButton, IReadOnlyList<KeyValuePair<string, string>> details, RichTextPayload richText)
        {
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
            TextBoundaryNavigator.Attach(textBox);

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

            var content = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                ColumnCount = 1,
                RowCount = details != null && details.Count > 0 ? 2 : 1
            };
            content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            content.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            content.Controls.Add(primaryControl, 0, 0);

            if (details != null && details.Count > 0)
            {
                content.RowStyles.Add(new RowStyle(SizeType.Absolute, 145));
                var detailsList = new ListView
                {
                    Dock = DockStyle.Fill,
                    View = View.Details,
                    FullRowSelect = true,
                    HeaderStyle = ColumnHeaderStyle.None,
                    HideSelection = false,
                    AccessibleName = "Entry details",
                    AccessibleDescription = "Metadata for the selected clipboard entry."
                };
                detailsList.Columns.Add("Property", 180);
                detailsList.Columns.Add("Value", 590);
                foreach (var detail in details)
                {
                    var item = new ListViewItem(detail.Key);
                    item.SubItems.Add(detail.Value ?? string.Empty);
                    detailsList.Items.Add(item);
                }
                content.Controls.Add(detailsList, 0, 1);
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
            Shown += (s, e) =>
            {
                textBox.SelectionStart = 0;
                textBox.SelectionLength = 0;
                focusControl.Focus();
            };
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && previewImage != null) previewImage.Dispose();
            base.Dispose(disposing);
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
