using System;
using System.Runtime.InteropServices;

namespace Clipman
{
    internal static class ClipboardPrivacySignals
    {
        private const string ClipboardViewerIgnoreFormatName = "Clipboard Viewer Ignore";
        private const string ExcludeMonitorFormatName = "ExcludeClipboardContentFromMonitorProcessing";
        private const string CanIncludeInHistoryFormatName = "CanIncludeInClipboardHistory";
        private const string CanUploadToCloudFormatName = "CanUploadToCloudClipboard";

        private static readonly uint ClipboardViewerIgnoreFormat = NativeMethods.RegisterClipboardFormat(ClipboardViewerIgnoreFormatName);
        private static readonly uint ExcludeMonitorFormat = NativeMethods.RegisterClipboardFormat(ExcludeMonitorFormatName);
        private static readonly uint CanIncludeInHistoryFormat = NativeMethods.RegisterClipboardFormat(CanIncludeInHistoryFormatName);
        private static readonly uint CanUploadToCloudFormat = NativeMethods.RegisterClipboardFormat(CanUploadToCloudFormatName);

        public static ClipboardPrivacySignal Detect()
        {
            if (FormatAvailable(ClipboardViewerIgnoreFormat))
            {
                return new ClipboardPrivacySignal(ClipboardViewerIgnoreFormatName);
            }

            if (FormatAvailable(ExcludeMonitorFormat))
            {
                return new ClipboardPrivacySignal(ExcludeMonitorFormatName);
            }

            bool opened = false;
            try
            {
                if (!NativeMethods.OpenClipboard(IntPtr.Zero))
                {
                    return null;
                }

                opened = true;
                if (ClipboardDwordEqualsZero(CanIncludeInHistoryFormat))
                {
                    return new ClipboardPrivacySignal(CanIncludeInHistoryFormatName + " = 0");
                }

                if (ClipboardDwordEqualsZero(CanUploadToCloudFormat))
                {
                    return new ClipboardPrivacySignal(CanUploadToCloudFormatName + " = 0");
                }
            }
            catch
            {
                return null;
            }
            finally
            {
                if (opened)
                {
                    NativeMethods.CloseClipboard();
                }
            }

            return null;
        }

        private static bool FormatAvailable(uint format)
        {
            return format != 0 && NativeMethods.IsClipboardFormatAvailable(format);
        }

        private static bool ClipboardDwordEqualsZero(uint format)
        {
            if (format == 0 || !NativeMethods.IsClipboardFormatAvailable(format))
            {
                return false;
            }

            var handle = NativeMethods.GetClipboardData(format);
            if (handle == IntPtr.Zero)
            {
                return false;
            }

            var size = NativeMethods.GlobalSize(handle);
            if (size.ToUInt64() < 4)
            {
                return false;
            }

            var pointer = NativeMethods.GlobalLock(handle);
            if (pointer == IntPtr.Zero)
            {
                return false;
            }

            try
            {
                return Marshal.ReadInt32(pointer) == 0;
            }
            finally
            {
                NativeMethods.GlobalUnlock(handle);
            }
        }
    }

    internal sealed class ClipboardPrivacySignal
    {
        public ClipboardPrivacySignal(string reason)
        {
            Reason = reason ?? string.Empty;
        }

        public string Reason { get; private set; }
    }
}
