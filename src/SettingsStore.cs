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
            var settings = JsonUtil.Load<AppSettings>(SettingsPath);
            Normalize(settings);
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
            if (string.IsNullOrWhiteSpace(settings.DatabasePath))
            {
                settings.DatabasePath = DefaultDatabasePath();
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
            if (settings.LastPreferencesTab < 0 || settings.LastPreferencesTab > 3)
            {
                settings.LastPreferencesTab = 0;
            }
            settings.DatabaseEncryptionEnabled = !string.IsNullOrWhiteSpace(settings.ProtectedDatabasePassword);
        }

        private string DefaultDatabasePath()
        {
            return Path.Combine(SettingsDirectory, "clipman-history.clipdb");
        }

        private static string MachineSettingsFileName()
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

            return safe + "-settings.json";
        }
    }
}
