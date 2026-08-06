using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class SharedUpdateState
    {
        public int Schema { get; set; }
        public string Version { get; set; }
        public long BuildStampUtcMs { get; set; }
        public string ExeSha256 { get; set; }
        public string UpdatedByMachine { get; set; }
        public long UpdatedAtUtcMs { get; set; }
        public long CloseRequestUntilUtcMs { get; set; }
        public string CloseRequestId { get; set; }
        public string CloseRequestedByMachine { get; set; }

        public SharedUpdateState()
        {
            Schema = 1;
            Version = string.Empty;
            ExeSha256 = string.Empty;
            UpdatedByMachine = string.Empty;
            CloseRequestId = string.Empty;
            CloseRequestedByMachine = string.Empty;
        }
    }

    internal static class SharedUpdateStateStore
    {
        private const string StateFileName = "clipman-shared-state.json";

        public static string StatePath(string settingsDirectory)
        {
            return Path.Combine(settingsDirectory, StateFileName);
        }

        public static SharedUpdateState Load(string settingsDirectory)
        {
            if (string.IsNullOrWhiteSpace(settingsDirectory)) return new SharedUpdateState();
            try
            {
                ResolveStateConflicts(settingsDirectory);
                return TryLoad(StatePath(settingsDirectory)) ?? new SharedUpdateState();
            }
            catch
            {
                return new SharedUpdateState();
            }
        }

        public static bool CanCoordinateExecutable(string settingsDirectory, string executablePath)
        {
            if (string.IsNullOrWhiteSpace(settingsDirectory) || string.IsNullOrWhiteSpace(executablePath)) return false;
            try
            {
                var executableDirectory = Path.GetDirectoryName(Path.GetFullPath(executablePath));
                if (string.IsNullOrWhiteSpace(executableDirectory)) return false;
                var expectedSettingsDirectory = Path.Combine(executableDirectory, "Settings");
                return string.Equals(
                    NormalizeDirectory(settingsDirectory),
                    NormalizeDirectory(expectedSettingsDirectory),
                    StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        public static void PublishCurrentBuild(string settingsDirectory, string executablePath)
        {
            if (!CanCoordinateExecutable(settingsDirectory, executablePath)) return;
            try
            {
                Directory.CreateDirectory(settingsDirectory);
                var existing = Load(settingsDirectory);
                if (existing != null && existing.BuildStampUtcMs > BuildInfo.BuildStampUtcMs)
                {
                    return;
                }

                JsonUtil.SaveAtomic(StatePath(settingsDirectory), CurrentState(executablePath));
            }
            catch
            {
            }
        }

        public static bool ShouldRestartForState(string settingsDirectory, string executablePath, out SharedUpdateState state, out string reason)
        {
            state = null;
            reason = string.Empty;
            if (!CanCoordinateExecutable(settingsDirectory, executablePath)) return false;
            try
            {
                state = Load(settingsDirectory);
                if (state == null || state.BuildStampUtcMs <= BuildInfo.BuildStampUtcMs)
                {
                    return false;
                }

                var expectedHash = (state.ExeSha256 ?? string.Empty).Trim();
                if (expectedHash.Length == 0)
                {
                    reason = "shared state has newer build stamp";
                    return true;
                }

                var diskHash = HashFile(executablePath);
                if (string.Equals(diskHash, expectedHash, StringComparison.OrdinalIgnoreCase))
                {
                    reason = "shared state and executable hash indicate a newer build is on disk";
                    return true;
                }

                reason = "shared state is newer, but the updated executable has not synced to this machine yet";
                return false;
            }
            catch
            {
                return false;
            }
        }

        public static void PublishCloseRequest(string settingsDirectory, string executablePath, int seconds)
        {
            if (!CanCoordinateExecutable(settingsDirectory, executablePath)) return;
            try
            {
                Directory.CreateDirectory(settingsDirectory);
                var state = Load(settingsDirectory) ?? new SharedUpdateState();
                state.CloseRequestUntilUtcMs = TimeUtil.NowUnixMs() + Math.Max(10, seconds) * 1000L;
                state.CloseRequestId = Guid.NewGuid().ToString("N");
                state.CloseRequestedByMachine = Environment.MachineName ?? string.Empty;
                if (state.BuildStampUtcMs <= 0)
                {
                    state.BuildStampUtcMs = BuildInfo.BuildStampUtcMs;
                }
                if (string.IsNullOrWhiteSpace(state.Version))
                {
                    state.Version = AppVersion();
                }
                if (string.IsNullOrWhiteSpace(state.ExeSha256))
                {
                    state.ExeSha256 = CurrentExeHash(executablePath);
                }
                JsonUtil.SaveAtomic(StatePath(settingsDirectory), state);
            }
            catch
            {
            }
        }

        public static bool HasActiveCloseRequest(string settingsDirectory, string executablePath, string lastHandledRequestId, out SharedUpdateState state)
        {
            state = null;
            if (!CanCoordinateExecutable(settingsDirectory, executablePath)) return false;
            try
            {
                state = Load(settingsDirectory);
                if (state == null) return false;
                if (state.CloseRequestUntilUtcMs <= TimeUtil.NowUnixMs()) return false;
                if (string.IsNullOrWhiteSpace(state.CloseRequestId)) return false;
                if (string.Equals(state.CloseRequestId, lastHandledRequestId, StringComparison.OrdinalIgnoreCase)) return false;
                if (string.Equals(state.CloseRequestedByMachine, Environment.MachineName, StringComparison.OrdinalIgnoreCase)) return false;
                return true;
            }
            catch
            {
                return false;
            }
        }

        public static bool IsNewerStateFromAnotherMachine(SharedUpdateState state)
        {
            if (state == null) return false;
            if (state.BuildStampUtcMs <= BuildInfo.BuildStampUtcMs) return false;
            if (string.Equals(state.UpdatedByMachine, Environment.MachineName, StringComparison.OrdinalIgnoreCase)) return false;
            return true;
        }

        public static string CurrentExeHash()
        {
            return CurrentExeHash(Application.ExecutablePath);
        }

        private static string CurrentExeHash(string executablePath)
        {
            try
            {
                return HashFile(executablePath);
            }
            catch
            {
                return string.Empty;
            }
        }

        private static SharedUpdateState CurrentState(string executablePath)
        {
            return new SharedUpdateState
            {
                Schema = 1,
                Version = AppVersion(),
                BuildStampUtcMs = BuildInfo.BuildStampUtcMs,
                ExeSha256 = CurrentExeHash(executablePath),
                UpdatedByMachine = Environment.MachineName ?? string.Empty,
                UpdatedAtUtcMs = TimeUtil.NowUnixMs()
            };
        }

        private static void ResolveStateConflicts(string settingsDirectory)
        {
            try
            {
                var canonicalPath = StatePath(settingsDirectory);
                var conflicts = Directory.GetFiles(settingsDirectory, "*.json")
                    .Where(path => IsStateConflict(path, canonicalPath))
                    .ToList();
                if (conflicts.Count == 0) return;

                var candidates = new List<Tuple<string, SharedUpdateState>>();
                var canonical = TryLoad(canonicalPath);
                if (canonical != null) candidates.Add(Tuple.Create(canonicalPath, canonical));
                foreach (var conflict in conflicts)
                {
                    var candidate = TryLoad(conflict);
                    if (candidate != null) candidates.Add(Tuple.Create(conflict, candidate));
                }

                var newest = candidates
                    .Where(item => item.Item2 != null)
                    .OrderByDescending(item => item.Item2.BuildStampUtcMs)
                    .ThenByDescending(item => item.Item2.UpdatedAtUtcMs)
                    .FirstOrDefault();
                if (newest != null && newest.Item2 != null)
                {
                    JsonUtil.SaveAtomic(canonicalPath, newest.Item2);
                }

                if (newest == null || newest.Item2 == null) return;
                foreach (var conflict in conflicts)
                {
                    TryDelete(conflict);
                }
            }
            catch
            {
            }
        }

        private static bool IsStateConflict(string path, string canonicalPath)
        {
            if (string.Equals(path, canonicalPath, StringComparison.OrdinalIgnoreCase)) return false;
            var name = Path.GetFileNameWithoutExtension(path);
            if (string.IsNullOrWhiteSpace(name) ||
                !name.StartsWith("clipman-shared-state", StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            var suffix = name.Substring("clipman-shared-state".Length).Trim().ToLowerInvariant();
            if (suffix.Length == 0) return false;
            return suffix.Contains("conflicted copy") ||
                suffix.StartsWith(".sync-conflict-", StringComparison.Ordinal) ||
                suffix.Contains("[conflict]") ||
                suffix.Contains(" conflict") ||
                suffix.StartsWith("_conf(") ||
                suffix.StartsWith("-") ||
                suffix.StartsWith("(");
        }

        private static SharedUpdateState TryLoad(string path)
        {
            try
            {
                return File.Exists(path) ? JsonUtil.Load<SharedUpdateState>(path) : null;
            }
            catch
            {
                return null;
            }
        }

        private static string NormalizeDirectory(string path)
        {
            return Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }

        private static string HashFile(string path)
        {
            using (var sha = SHA256.Create())
            using (var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", string.Empty).ToLowerInvariant();
            }
        }

        private static string AppVersion()
        {
            var version = Assembly.GetExecutingAssembly().GetName().Version;
            return version == null ? "1.1.0" : version.Major + "." + version.Minor + "." + version.Build;
        }

        private static void TryDelete(string path)
        {
            try
            {
                if (File.Exists(path))
                {
                    File.Delete(path);
                }
            }
            catch
            {
            }
        }
    }
}
