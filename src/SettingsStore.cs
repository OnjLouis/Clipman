using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace Clipman
{
    internal sealed class SettingsStore
    {
        public string AppDirectory { get; private set; }
        public string SettingsDirectory { get; private set; }
        public string SettingsPath { get; private set; }

        public SettingsStore(string appDirectory)
        {
            AppDirectory = appDirectory;
            SettingsDirectory = Path.Combine(appDirectory, "Settings");
            SettingsPath = Path.Combine(SettingsDirectory, MachineSettingsFileName());
        }

        public AppSettings Load()
        {
            Directory.CreateDirectory(SettingsDirectory);
            SyncConflictResolver.ResolveSettingsConflicts(SettingsPath);
            var hadSortDescending = SettingsFileContainsProperty("SortDescending");
            var hadUseDefaultDatabasePath = SettingsFileContainsProperty("UseDefaultDatabasePath");
            var settings = JsonUtil.Load<AppSettings>(SettingsPath);
            if (!hadUseDefaultDatabasePath)
            {
                settings.UseDefaultDatabasePath = ShouldTreatAsDefaultDatabasePath(settings.DatabasePath);
            }
            Normalize(settings);
            if (!hadSortDescending)
            {
                settings.SortDescending = DefaultSortDescending(settings.SortMode);
            }
            Save(settings);
            return settings;
        }

        public void Save(AppSettings settings)
        {
            Directory.CreateDirectory(SettingsDirectory);
            Normalize(settings);
            JsonUtil.SaveAtomic(SettingsPath, settings);
        }

        public string DatabasePassword(AppSettings settings)
        {
            if (settings == null || string.IsNullOrWhiteSpace(settings.ProtectedDatabasePassword)) return string.Empty;
            return DatabasePasswordProtector.Unprotect(settings.ProtectedDatabasePassword);
        }

        private void Normalize(AppSettings settings)
        {
            if (settings.UseDefaultDatabasePath || string.IsNullOrWhiteSpace(settings.DatabasePath))
            {
                settings.DatabasePath = DefaultDatabasePath();
                settings.UseDefaultDatabasePath = true;
            }
            if (settings.MaxHistoryEntries < 0)
            {
                settings.MaxHistoryEntries = 0;
            }
            if (settings.MaxHistoryDays < 0)
            {
                settings.MaxHistoryDays = 0;
            }
            if (settings.IgnoredProcesses == null)
            {
                settings.IgnoredProcesses = new List<string>();
            }
            if (string.IsNullOrWhiteSpace(settings.SortMode))
            {
                settings.SortMode = "LastUsed";
            }
            if (string.IsNullOrWhiteSpace(settings.GroupFilter))
            {
                settings.GroupFilter = "All";
            }
            if (string.IsNullOrWhiteSpace(settings.DuplicateMode))
            {
                settings.DuplicateMode = settings.RemoveDuplicates ? "MoveToTop" : "KeepBoth";
            }
            if (settings.LastSelectedTab < 0 || settings.LastSelectedTab > 1)
            {
                settings.LastSelectedTab = 0;
            }
            if (settings.LastPreferencesTab < 0 || settings.LastPreferencesTab > 4)
            {
                settings.LastPreferencesTab = 0;
            }
            if (settings.DiagnosticsFileHistoryLimit < 0)
            {
                settings.DiagnosticsFileHistoryLimit = 0;
            }
            if (settings.DiagnosticsFileHistoryLimit > 200)
            {
                settings.DiagnosticsFileHistoryLimit = 200;
            }
            settings.DatabaseEncryptionEnabled = !string.IsNullOrWhiteSpace(settings.ProtectedDatabasePassword);
        }

        private bool SettingsFileContainsProperty(string propertyName)
        {
            if (string.IsNullOrWhiteSpace(propertyName) || !File.Exists(SettingsPath))
            {
                return false;
            }

            try
            {
                var text = File.ReadAllText(SettingsPath);
                return text.IndexOf("\"" + propertyName + "\"", StringComparison.OrdinalIgnoreCase) >= 0;
            }
            catch
            {
                return false;
            }
        }

        private static bool DefaultSortDescending(string sortMode)
        {
            switch ((sortMode ?? string.Empty).Trim().ToUpperInvariant())
            {
                case "TEXT":
                case "GROUP":
                case "MACHINE":
                case "MANUAL":
                    return false;
                default:
                    return true;
            }
        }

        public string DefaultDatabasePath()
        {
            return Path.Combine(SettingsDirectory, "clipman-history.clipdb");
        }

        public string DefaultFileHistoryDatabasePath()
        {
            return Path.Combine(SettingsDirectory, MachineNameSafe() + "-file-history.clipdb");
        }

        private bool ShouldTreatAsDefaultDatabasePath(string databasePath)
        {
            if (string.IsNullOrWhiteSpace(databasePath)) return true;
            if (IsCurrentDefaultDatabasePath(databasePath)) return true;

            try
            {
                var full = Path.GetFullPath(databasePath);
                var file = Path.GetFileName(full);
                var parent = Directory.GetParent(full);
                return string.Equals(file, "clipman-history.clipdb", StringComparison.OrdinalIgnoreCase) &&
                    parent != null &&
                    string.Equals(parent.Name, "Settings", StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        public bool IsCurrentDefaultDatabasePath(string databasePath)
        {
            if (string.IsNullOrWhiteSpace(databasePath)) return false;
            try
            {
                return string.Equals(
                    Path.GetFullPath(databasePath),
                    Path.GetFullPath(DefaultDatabasePath()),
                    StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        private static string MachineSettingsFileName()
        {
            return MachineNameSafe() + "-settings.json";
        }

        private static string MachineNameSafe()
        {
            var name = Environment.MachineName;
            if (string.IsNullOrWhiteSpace(name))
            {
                name = "ThisComputer";
            }

            var invalid = Path.GetInvalidFileNameChars();
            var safe = new string(name.Select(ch => invalid.Contains(ch) ? '_' : ch).ToArray()).Trim();
            if (string.IsNullOrWhiteSpace(safe))
            {
                safe = "ThisComputer";
            }

            return safe;
        }
    }
}
