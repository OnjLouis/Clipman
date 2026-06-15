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
