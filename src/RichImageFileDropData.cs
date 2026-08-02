using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows.Forms;

namespace Clipman
{
    internal static class RichImageFileDropData
    {
        internal const string PreferredDropEffectFormat = "Preferred DropEffect";
        internal const int MaximumRetainedDirectories = 16;
        internal const long MaximumRetainedBytes = 8L * 1024L * 1024L;
        internal static readonly TimeSpan MaximumAge = TimeSpan.FromHours(24);

        private const uint DropEffectCopy = 1;
        private static readonly object SyncRoot = new object();

        public static string Add(DataObject target, byte[] contents, string fileName)
        {
            return Add(target, contents, fileName, DefaultRoot(), DateTime.UtcNow);
        }

        internal static string Add(DataObject target, byte[] contents, string fileName, string root, DateTime nowUtc)
        {
            if (target == null) throw new ArgumentNullException("target");
            var path = CreateManagedFile(contents, fileName, root, nowUtc);
            var files = new StringCollection { path };
            target.SetFileDropList(files);
            target.SetData(PreferredDropEffectFormat, false, UInt32Stream(DropEffectCopy));
            return path;
        }

        public static void Cleanup()
        {
            try { Cleanup(DefaultRoot(), DateTime.UtcNow, string.Empty); }
            catch { }
        }

        internal static string CreateManagedFile(byte[] contents, string fileName, string root, DateTime nowUtc)
        {
            if (contents == null || contents.Length == 0 || contents.Length > RichImageData.MaximumStoredImageBytes)
            {
                throw new ArgumentException("Clipboard image contents must fit the stored image limit.", "contents");
            }
            if (string.IsNullOrWhiteSpace(fileName)) throw new ArgumentException("A clipboard image filename is required.", "fileName");
            if (string.IsNullOrWhiteSpace(root)) throw new ArgumentException("A managed clipboard-file root is required.", "root");

            lock (SyncRoot)
            {
                Directory.CreateDirectory(root);
                Cleanup(root, nowUtc, string.Empty);
                var directory = Path.Combine(root, Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(directory);
                var path = Path.Combine(directory, Path.GetFileName(fileName));
                try
                {
                    using (var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read, 8192, FileOptions.WriteThrough))
                    {
                        stream.Write(contents, 0, contents.Length);
                        stream.Flush();
                    }
                    Cleanup(root, nowUtc, directory);
                    return path;
                }
                catch
                {
                    TryDeleteDirectory(directory);
                    throw;
                }
            }
        }

        internal static void Cleanup(string root, DateTime nowUtc, string protectedDirectory)
        {
            if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root)) return;
            var canonicalRoot = EnsureTrailingSeparator(Path.GetFullPath(root));
            var protectedPath = string.IsNullOrWhiteSpace(protectedDirectory) ? string.Empty : Path.GetFullPath(protectedDirectory);
            var directories = new List<ManagedDirectory>();

            string[] paths;
            try { paths = Directory.GetDirectories(root); }
            catch { return; }
            foreach (var path in paths)
            {
                string canonicalPath;
                try { canonicalPath = Path.GetFullPath(path); }
                catch { continue; }
                if (!canonicalPath.StartsWith(canonicalRoot, StringComparison.OrdinalIgnoreCase)) continue;
                if (string.Equals(canonicalPath, protectedPath, StringComparison.OrdinalIgnoreCase))
                {
                    directories.Add(Describe(canonicalPath));
                    continue;
                }

                var directory = Describe(canonicalPath);
                if (nowUtc - directory.LastWriteUtc > MaximumAge)
                {
                    TryDeleteDirectory(canonicalPath);
                    continue;
                }
                directories.Add(directory);
            }

            var retainedCount = 0;
            long retainedBytes = 0;
            foreach (var directory in directories
                .OrderBy(value => string.Equals(value.Path, protectedPath, StringComparison.OrdinalIgnoreCase) ? 0 : 1)
                .ThenByDescending(value => value.LastWriteUtc))
            {
                var isProtected = string.Equals(directory.Path, protectedPath, StringComparison.OrdinalIgnoreCase);
                if (!isProtected && (retainedCount >= MaximumRetainedDirectories || retainedBytes + directory.Bytes > MaximumRetainedBytes))
                {
                    TryDeleteDirectory(directory.Path);
                    continue;
                }
                retainedCount++;
                retainedBytes += directory.Bytes;
            }

            try
            {
                if (Directory.Exists(root) && Directory.GetFileSystemEntries(root).Length == 0) Directory.Delete(root, false);
            }
            catch { }
        }

        private static ManagedDirectory Describe(string path)
        {
            try
            {
                var info = new DirectoryInfo(path);
                long bytes = 0;
                foreach (var file in info.GetFiles())
                {
                    try { bytes += file.Length; }
                    catch { }
                }
                return new ManagedDirectory(path, info.LastWriteTimeUtc, bytes);
            }
            catch
            {
                return new ManagedDirectory(path, DateTime.MinValue, 0);
            }
        }

        private static void TryDeleteDirectory(string path)
        {
            try { if (Directory.Exists(path)) Directory.Delete(path, true); }
            catch { }
        }

        private static string DefaultRoot()
        {
            return Path.Combine(Path.GetTempPath(), "Clipman", "ClipboardFiles");
        }

        private static string EnsureTrailingSeparator(string path)
        {
            return path.EndsWith(Path.DirectorySeparatorChar.ToString(), StringComparison.Ordinal) ? path : path + Path.DirectorySeparatorChar;
        }

        private static MemoryStream UInt32Stream(uint value)
        {
            var stream = new MemoryStream(4);
            using (var writer = new BinaryWriter(stream, Encoding.UTF8, true)) writer.Write(value);
            stream.Position = 0;
            return stream;
        }

        private sealed class ManagedDirectory
        {
            public ManagedDirectory(string path, DateTime lastWriteUtc, long bytes)
            {
                Path = path;
                LastWriteUtc = lastWriteUtc;
                Bytes = bytes;
            }

            public string Path { get; private set; }
            public DateTime LastWriteUtc { get; private set; }
            public long Bytes { get; private set; }
        }
    }
}
