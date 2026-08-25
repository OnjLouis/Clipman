using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class InstanceState
    {
        public int Schema { get; set; }
        public string AppDirectory { get; set; }
        public string ExecutablePath { get; set; }
        public int ProcessId { get; set; }
        public long UpdatedAtUtcMs { get; set; }

        public InstanceState()
        {
            Schema = 1;
            AppDirectory = string.Empty;
            ExecutablePath = string.Empty;
            ProcessId = 0;
        }
    }

    internal sealed class PendingCommandEntry
    {
        public string EntryId { get; set; }
        public long CreatedAtUtcMs { get; set; }

        public PendingCommandEntry()
        {
            EntryId = string.Empty;
        }
    }

    internal static class InstanceStateStore
    {
        private static string StatePath
        {
            get
            {
                var root = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "Clipman");
                return Path.Combine(root, "running-instance.json");
            }
        }

        private static string PendingCommandEntryPath
        {
            get
            {
                var root = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "Clipman");
                return Path.Combine(root, "pending-command-entry.json");
            }
        }

        public static void PublishPendingCommandEntry(string entryId)
        {
            PublishPendingCommandEntry(PendingCommandEntryPath, entryId);
        }

        internal static void PublishPendingCommandEntry(string path, string entryId)
        {
            if (string.IsNullOrWhiteSpace(entryId)) return;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                JsonUtil.SaveAtomic(path, new PendingCommandEntry
                {
                    EntryId = entryId.Trim(),
                    CreatedAtUtcMs = TimeUtil.NowUnixMs()
                });
            }
            catch
            {
            }
        }

        public static string TakePendingCommandEntry(long maximumAgeMilliseconds)
        {
            return TakePendingCommandEntry(PendingCommandEntryPath, maximumAgeMilliseconds);
        }

        public static bool HasPendingCommandEntry()
        {
            return File.Exists(PendingCommandEntryPath);
        }

        internal static string TakePendingCommandEntry(string path, long maximumAgeMilliseconds)
        {
            try
            {
                var pending = JsonUtil.Load<PendingCommandEntry>(path);
                if (File.Exists(path))
                {
                    File.Delete(path);
                }
                if (pending == null || string.IsNullOrWhiteSpace(pending.EntryId)) return string.Empty;
                var age = TimeUtil.NowUnixMs() - pending.CreatedAtUtcMs;
                return age >= 0 && age <= Math.Max(1, maximumAgeMilliseconds)
                    ? pending.EntryId.Trim()
                    : string.Empty;
            }
            catch
            {
                return string.Empty;
            }
        }

        public static InstanceState Load()
        {
            try
            {
                return JsonUtil.Load<InstanceState>(StatePath);
            }
            catch
            {
                return new InstanceState();
            }
        }

        public static void PublishCurrent(string appDirectory)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(StatePath));
                JsonUtil.SaveAtomic(StatePath, new InstanceState
                {
                    Schema = 1,
                    AppDirectory = NormalizeDirectory(appDirectory),
                    ExecutablePath = Application.ExecutablePath,
                    ProcessId = Process.GetCurrentProcess().Id,
                    UpdatedAtUtcMs = TimeUtil.NowUnixMs()
                });
            }
            catch
            {
            }
        }

        public static void ClearIfCurrent(string appDirectory)
        {
            try
            {
                var state = Load();
                if (state == null) return;
                if (state.ProcessId != Process.GetCurrentProcess().Id) return;
                if (!SameDirectory(state.AppDirectory, appDirectory)) return;
                if (File.Exists(StatePath))
                {
                    File.Delete(StatePath);
                }
            }
            catch
            {
            }
        }

        public static bool IsSameRunningFolder(string appDirectory)
        {
            var state = Load();
            if (state == null || !IsProcessAlive(state.ProcessId)) return false;
            return SameDirectory(state.AppDirectory, appDirectory);
        }

        public static int RunningProcessId()
        {
            var state = Load();
            return state == null ? 0 : state.ProcessId;
        }

        private static bool IsProcessAlive(int processId)
        {
            if (processId <= 0) return false;
            try
            {
                using (Process.GetProcessById(processId))
                {
                    return true;
                }
            }
            catch
            {
                return false;
            }
        }

        private static bool SameDirectory(string left, string right)
        {
            return string.Equals(NormalizeDirectory(left), NormalizeDirectory(right), StringComparison.OrdinalIgnoreCase);
        }

        private static string NormalizeDirectory(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return string.Empty;
            return Path.GetFullPath(path)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }
    }
}
