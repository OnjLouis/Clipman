using System;
using System.IO;
using System.Text;
using System.Windows.Forms;

namespace Clipman
{
    internal static class ClipboardUrlData
    {
        private const string UnicodeUrlFormat = "UniformResourceLocatorW";
        private const string LegacyUrlFormat = "UniformResourceLocator";
        private const int MaximumEncodedBytes = (LinkPresentation.MaximumUrlCharacters + 1) * 2;

        internal static string TryRead(IDataObject data)
        {
            if (data == null) return null;
            try
            {
                if (data.GetDataPresent(DataFormats.FileDrop, false)) return null;
                return ReadFormat(data, UnicodeUrlFormat, Encoding.Unicode)
                    ?? ReadFormat(data, LegacyUrlFormat, Encoding.Default);
            }
            catch
            {
                return null;
            }
        }

        private static string ReadFormat(IDataObject data, string format, Encoding encoding)
        {
            if (!data.GetDataPresent(format, false)) return null;
            var value = data.GetData(format, false);
            var text = value as string;
            if (text == null)
            {
                var bytes = value as byte[];
                if (bytes == null)
                {
                    var stream = value as Stream;
                    if (stream == null) return null;
                    var position = stream.CanSeek ? stream.Position : 0;
                    try
                    {
                        if (stream.CanSeek) stream.Position = 0;
                        using (var copy = new MemoryStream())
                        {
                            var buffer = new byte[4096];
                            while (copy.Length <= MaximumEncodedBytes)
                            {
                                var count = stream.Read(buffer, 0,
                                    Math.Min(buffer.Length, MaximumEncodedBytes + 1 - (int)copy.Length));
                                if (count == 0) break;
                                copy.Write(buffer, 0, count);
                            }
                            bytes = copy.ToArray();
                        }
                    }
                    finally
                    {
                        if (stream.CanSeek) stream.Position = position;
                    }
                }
                if (bytes.Length > MaximumEncodedBytes) return null;
                if (encoding == Encoding.Unicode && bytes.Length % 2 != 0) return null;
                text = encoding.GetString(bytes);
            }

            var candidate = text.Split('\0')[0].Trim();
            if (candidate.Length > LinkPresentation.MaximumUrlCharacters) return null;
            Uri ignored;
            return LinkClassifier.TryGetLinkOnlyUri(candidate, out ignored) ? candidate : null;
        }
    }
}
