using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Web.Script.Serialization;

namespace Clipman
{
    internal sealed class SettingsStore
    {
        private const string PointerFileName = "settings-location.json";
        public string AppDirectory { get; private set; }
        public string AppSettingsDirectory { get; private set; }
        public string SettingsDirectory { get; private set; }
        public string SettingsPath { get; private set; }

        public SettingsStore(string appDirectory)
        {
            AppDirectory = appDirectory;
            AppSettingsDirectory = Path.Combine(appDirectory, "Settings");
            SetActiveSettingsDirectory(AppSettingsDirectory);
        }

        public AppSettings Load()
        {
            Directory.CreateDirectory(AppSettingsDirectory);
            ResolveSettingsLocationConflicts();
            var loaded = LoadBestSettings();
            SettingsPath = loaded.Path;
            SettingsDirectory = Path.GetDirectoryName(SettingsPath) ?? AppSettingsDirectory;
            SyncConflictResolver.ResolveSettingsConflicts(SettingsPath);
            var hadSortDescending = SettingsFileContainsProperty(SettingsPath, "SortDescending");
            var hadFileHistorySortDescending = SettingsFileContainsProperty(SettingsPath, "FileHistorySortDescending");
            var hadUseDefaultDatabasePath = SettingsFileContainsProperty(SettingsPath, "UseDefaultDatabasePath");
            var hadRememberDatabasePassword = SettingsFileContainsProperty(SettingsPath, "RememberDatabasePassword");
            var hadLastSelectedHistoryTab = SettingsFileContainsProperty(SettingsPath, "LastSelectedHistoryTab");
            var settings = loaded.Settings;
            if (string.IsNullOrWhiteSpace(settings.ProtectedServerToken))
            {
                settings.ServerToken = ReadStringProperty(SettingsPath, "ServerToken");
            }
            if (!hadLastSelectedHistoryTab)
            {
                settings.LastSelectedHistoryTab = settings.LastSelectedTab == 1 ? HistoryTabs.Files : HistoryTabs.Text;
            }
            if (!hadRememberDatabasePassword && !string.IsNullOrWhiteSpace(settings.ProtectedDatabasePassword))
            {
                settings.RememberDatabasePassword = true;
            }
            if (!hadUseDefaultDatabasePath)
            {
                settings.UseDefaultDatabasePath = ShouldTreatAsDefaultDatabasePath(settings.DatabasePath);
            }
            Normalize(settings);
            PrepareSettingsDirectoryFor(settings);
            if (!hadSortDescending)
            {
                settings.SortDescending = DefaultSortDescending(settings.SortMode);
            }
            if (!hadFileHistorySortDescending)
            {
                settings.FileHistorySortDescending = DefaultFileHistorySortDescending(settings.FileHistorySortMode);
            }
            Save(settings);
            return settings;
        }

        public void Save(AppSettings settings)
        {
            PrepareSettingsDirectoryFor(settings);
            Directory.CreateDirectory(SettingsDirectory);
            Normalize(settings);
            JsonUtil.SaveAtomic(SettingsPath, settings);
            SaveDataFolderPointer(SettingsDirectory);
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
            settings.StorageMode = NormalizeStorageMode(settings.StorageMode);
            settings.ServerUrl = ServerSettingsSanitizer.CleanUrl(settings.ServerUrl);
            var plainServerToken = ServerSettingsSanitizer.CleanToken(settings.ServerToken);
            if (plainServerToken.Length == 0 && !string.IsNullOrWhiteSpace(settings.ProtectedServerToken))
            {
                try
                {
                    plainServerToken = ServerSettingsSanitizer.CleanToken(ServerTokenProtector.Unprotect(settings.ProtectedServerToken));
                }
                catch
                {
                    settings.ProtectedServerToken = string.Empty;
                }
            }
            settings.ServerToken = plainServerToken;
            settings.ProtectedServerToken = plainServerToken.Length == 0 ? string.Empty : ServerTokenProtector.Protect(plainServerToken);
            if (string.IsNullOrWhiteSpace(settings.ShowHistoryHotkey))
            {
                settings.ShowHistoryHotkey = "Ctrl+Alt+\\";
            }
            if (string.IsNullOrWhiteSpace(settings.ToggleActiveHotkey))
            {
                settings.ToggleActiveHotkey = "Ctrl+Alt+`";
            }
            if (settings.QuickCopyHotkeys == null)
            {
                settings.QuickCopyHotkeys = new List<QuickCopyBinding>();
            }
            settings.QuickCopyHotkeys = settings.QuickCopyHotkeys
                .Where(b => b != null && !string.IsNullOrWhiteSpace(b.EntryId) && !string.IsNullOrWhiteSpace(b.Hotkey))
                .GroupBy(b => b.EntryId.Trim(), StringComparer.OrdinalIgnoreCase)
                .Select(g => new QuickCopyBinding
                {
                    EntryId = g.First().EntryId.Trim(),
                    Hotkey = g.First().Hotkey.Trim(),
                    Mode = QuickPasteModes.Normalize(g.First().Mode)
                })
                .GroupBy(b => b.Hotkey, StringComparer.OrdinalIgnoreCase)
                .Select(g => g.First())
                .ToList();
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
            if (string.IsNullOrWhiteSpace(settings.FileHistorySortMode))
            {
                settings.FileHistorySortMode = "Manual";
            }
            settings.FileHistorySortMode = NormalizeFileHistorySortMode(settings.FileHistorySortMode);
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
            settings.LastSelectedHistoryTab = HistoryTabs.Normalize(settings.LastSelectedHistoryTab, settings.LinksHistoryEnabled);
            if (settings.LastPreferencesTab < 0 || settings.LastPreferencesTab > 5)
            {
                settings.LastPreferencesTab = 0;
            }
            settings.SensitiveDataMode = SensitiveDataExclusion.NormalizeMode(settings.SensitiveDataMode);
            if (settings.SensitiveDataPresetIds == null)
            {
                settings.SensitiveDataPresetIds = new List<string>();
            }
            var knownSensitivePresets = new HashSet<string>(SensitiveDataExclusion.BuiltInPresets.Select(p => p.Id), StringComparer.OrdinalIgnoreCase);
            settings.SensitiveDataPresetIds = settings.SensitiveDataPresetIds
                .Where(id => !string.IsNullOrWhiteSpace(id) && knownSensitivePresets.Contains(id.Trim()))
                .Select(id => id.Trim())
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
            if (settings.DiagnosticsFileHistoryLimit < 0)
            {
                settings.DiagnosticsFileHistoryLimit = 0;
            }
            if (settings.DiagnosticsFileHistoryLimit > 200)
            {
                settings.DiagnosticsFileHistoryLimit = 200;
            }
            if (!string.IsNullOrWhiteSpace(settings.ProtectedDatabasePassword))
            {
                settings.DatabaseEncryptionEnabled = true;
                if (!settings.RememberDatabasePassword)
                {
                    settings.ProtectedDatabasePassword = string.Empty;
                }
            }
            if (!settings.DatabaseEncryptionEnabled)
            {
                settings.RememberDatabasePassword = false;
                settings.ProtectedDatabasePassword = string.Empty;
            }
            if (!settings.RememberDatabasePassword)
            {
                settings.ProtectedDatabasePassword = string.Empty;
            }
            settings.PlainDatabasePassword = string.Empty;
        }

        private static string ReadStringProperty(string path, string propertyName)
        {
            try
            {
                if (!File.Exists(path)) return string.Empty;
                var serializer = new System.Web.Script.Serialization.JavaScriptSerializer();
                var data = serializer.Deserialize<Dictionary<string, object>>(File.ReadAllText(path));
                if (data == null) return string.Empty;
                foreach (var pair in data)
                {
                    if (string.Equals(pair.Key, propertyName, StringComparison.OrdinalIgnoreCase))
                    {
                        return Convert.ToString(pair.Value) ?? string.Empty;
                    }
                }
            }
            catch
            {
            }
            return string.Empty;
        }

        private static string NormalizeStorageMode(string mode)
        {
            return string.Equals((mode ?? string.Empty).Trim(), "Server", StringComparison.OrdinalIgnoreCase)
                ? "Server"
                : "File";
        }

        private LoadedSettings LoadBestSettings()
        {
            var candidates = SettingsCandidates();
            foreach (var path in candidates.Where(File.Exists))
            {
                try
                {
                    var settings = JsonUtil.Load<AppSettings>(path);
                    return new LoadedSettings(path, settings);
                }
                catch
                {
                }
            }

            return new LoadedSettings(Path.Combine(AppSettingsDirectory, MachineSettingsFileName()), new AppSettings());
        }

        private IEnumerable<string> SettingsCandidates()
        {
            var candidates = new List<string>();
            var pointerFolder = LoadDataFolderPointer();
            if (!string.IsNullOrWhiteSpace(pointerFolder))
            {
                candidates.Add(Path.Combine(pointerFolder, MachineSettingsFileName()));
            }
            candidates.Add(Path.Combine(AppSettingsDirectory, MachineSettingsFileName()));

            return candidates
                .Where(path => !string.IsNullOrWhiteSpace(path))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
        }

        private string LoadDataFolderPointer()
        {
            var path = Path.Combine(AppSettingsDirectory, PointerFileName);
            ResolveSettingsLocationConflicts();
            if (!File.Exists(path)) return string.Empty;

            try
            {
                var pointer = JsonUtil.Load<SettingsLocationPointer>(path);
                return pointer == null ? string.Empty : pointer.FolderForMachine(MachineNameSafe());
            }
            catch
            {
                return string.Empty;
            }
        }

        private void SaveDataFolderPointer(string folder)
        {
            if (string.IsNullOrWhiteSpace(folder)) return;
            try
            {
                Directory.CreateDirectory(AppSettingsDirectory);
                var path = Path.Combine(AppSettingsDirectory, PointerFileName);
                ResolveSettingsLocationConflicts();
                var pointer = LoadSettingsLocationPointer(path) ?? new SettingsLocationPointer();
                pointer.SetFolderForMachine(MachineNameSafe(), folder);
                DeleteSettingsLocationConflicts(path);
                JsonUtil.SaveAtomic(path, pointer);
            }
            catch
            {
            }
        }

        private void ResolveSettingsLocationConflicts()
        {
            try
            {
                var canonicalPath = Path.Combine(AppSettingsDirectory, PointerFileName);
                var conflicts = SyncConflictResolver.FindConflictSiblings(canonicalPath).ToList();
                if (conflicts.Count == 0) return;

                var candidates = new List<Tuple<string, SettingsLocationPointer, DateTime>>();
                AddSettingsLocationCandidate(candidates, canonicalPath);
                foreach (var conflict in conflicts)
                {
                    AddSettingsLocationCandidate(candidates, conflict);
                }

                var merged = MergeSettingsLocationPointers(candidates);
                if (merged != null)
                {
                    Directory.CreateDirectory(AppSettingsDirectory);
                    JsonUtil.SaveAtomic(canonicalPath, merged);
                }

                DeleteSettingsLocationConflicts(canonicalPath);
            }
            catch
            {
            }
        }

        private static void AddSettingsLocationCandidate(List<Tuple<string, SettingsLocationPointer, DateTime>> candidates, string path)
        {
            try
            {
                if (!File.Exists(path)) return;
                candidates.Add(Tuple.Create(path, LoadSettingsLocationPointer(path), File.GetLastWriteTimeUtc(path)));
            }
            catch
            {
            }
        }

        private static SettingsLocationPointer LoadSettingsLocationPointer(string path)
        {
            try
            {
                if (!File.Exists(path)) return null;
                var serializer = new JavaScriptSerializer();
                var data = serializer.Deserialize<Dictionary<string, object>>(File.ReadAllText(path));
                if (data == null) return null;

                var pointer = new SettingsLocationPointer();
                object dataFolder;
                if (TryGetCaseInsensitive(data, "dataFolder", out dataFolder))
                {
                    pointer.DataFolder = Convert.ToString(dataFolder) ?? string.Empty;
                }

                object clients;
                if (TryGetCaseInsensitive(data, "clients", out clients))
                {
                    var clientDictionary = clients as Dictionary<string, object>;
                    if (clientDictionary != null)
                    {
                        foreach (var pair in clientDictionary)
                        {
                            var value = Convert.ToString(pair.Value) ?? string.Empty;
                            if (!string.IsNullOrWhiteSpace(pair.Key) && !string.IsNullOrWhiteSpace(value))
                            {
                                pointer.Clients[pair.Key.Trim()] = value;
                            }
                        }
                    }
                }

                return pointer;
            }
            catch
            {
                return null;
            }
        }

        private static bool TryGetCaseInsensitive(Dictionary<string, object> data, string key, out object value)
        {
            foreach (var pair in data)
            {
                if (string.Equals(pair.Key, key, StringComparison.OrdinalIgnoreCase))
                {
                    value = pair.Value;
                    return true;
                }
            }

            value = null;
            return false;
        }

        private static SettingsLocationPointer MergeSettingsLocationPointers(IEnumerable<Tuple<string, SettingsLocationPointer, DateTime>> candidates)
        {
            var merged = new SettingsLocationPointer();
            var sawAny = false;
            foreach (var item in candidates
                .Where(candidate => candidate.Item2 != null)
                .OrderBy(candidate => candidate.Item3))
            {
                var pointer = item.Item2;
                if (IsValidSettingsLocation(pointer.DataFolder))
                {
                    merged.DataFolder = pointer.DataFolder;
                    sawAny = true;
                }

                foreach (var pair in pointer.Clients ?? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase))
                {
                    if (string.IsNullOrWhiteSpace(pair.Key) || !IsValidSettingsLocation(pair.Value))
                    {
                        continue;
                    }

                    merged.Clients[pair.Key.Trim()] = pair.Value;
                    sawAny = true;
                }
            }

            return sawAny ? merged : null;
        }

        private static bool IsValidSettingsLocation(string folder)
        {
            if (string.IsNullOrWhiteSpace(folder)) return false;
            try
            {
                var full = Path.GetFullPath(folder);
                return Directory.Exists(full);
            }
            catch
            {
                return false;
            }
        }

        private static void DeleteSettingsLocationConflicts(string canonicalPath)
        {
            foreach (var conflict in SyncConflictResolver.FindConflictSiblings(canonicalPath))
            {
                try
                {
                    File.Delete(conflict);
                }
                catch
                {
                }
            }
        }

        private void PrepareSettingsDirectoryFor(AppSettings settings)
        {
            if (settings == null)
            {
                SetActiveSettingsDirectory(AppSettingsDirectory);
                return;
            }

            if (settings.UseDefaultDatabasePath || string.IsNullOrWhiteSpace(settings.DatabasePath))
            {
                SetActiveSettingsDirectory(AppSettingsDirectory);
                return;
            }

            try
            {
                var directory = Path.GetDirectoryName(Path.GetFullPath(settings.DatabasePath));
                SetActiveSettingsDirectory(string.IsNullOrWhiteSpace(directory) ? AppSettingsDirectory : directory);
            }
            catch
            {
                SetActiveSettingsDirectory(AppSettingsDirectory);
            }
        }

        private void SetActiveSettingsDirectory(string directory)
        {
            SettingsDirectory = string.IsNullOrWhiteSpace(directory) ? AppSettingsDirectory : directory;
            SettingsPath = Path.Combine(SettingsDirectory, MachineSettingsFileName());
        }

        private bool SettingsFileContainsProperty(string settingsPath, string propertyName)
        {
            if (string.IsNullOrWhiteSpace(propertyName) || string.IsNullOrWhiteSpace(settingsPath) || !File.Exists(settingsPath))
            {
                return false;
            }

            try
            {
                var text = File.ReadAllText(settingsPath);
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

        private static bool DefaultFileHistorySortDescending(string sortMode)
        {
            switch ((sortMode ?? string.Empty).Trim().ToUpperInvariant())
            {
                case "TIME":
                    return true;
                default:
                    return false;
            }
        }

        private static string NormalizeFileHistorySortMode(string sortMode)
        {
            switch ((sortMode ?? string.Empty).Trim().ToUpperInvariant())
            {
                case "TIME":
                    return "Time";
                case "FILES":
                    return "Files";
                case "NAME":
                    return "Name";
                case "OPERATION":
                    return "Operation";
                case "SOURCE":
                    return "Source";
                case "MANUAL":
                    return "Manual";
                default:
                    return "Manual";
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

        public string DefaultSecretsDatabasePath()
        {
            return Path.Combine(SettingsDirectory, MachineNameSafe() + "-secrets.clipdb");
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

        private sealed class LoadedSettings
        {
            public string Path { get; private set; }
            public AppSettings Settings { get; private set; }

            public LoadedSettings(string path, AppSettings settings)
            {
                Path = path;
                Settings = settings ?? new AppSettings();
            }
        }

        private sealed class SettingsLocationPointer
        {
            public string dataFolder { get; set; }
            public Dictionary<string, string> clients { get; set; }

            public SettingsLocationPointer()
            {
                dataFolder = string.Empty;
                clients = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            }

            [ScriptIgnore]
            public string DataFolder
            {
                get { return dataFolder ?? string.Empty; }
                set { dataFolder = value ?? string.Empty; }
            }

            [ScriptIgnore]
            public Dictionary<string, string> Clients
            {
                get
                {
                    if (clients == null)
                    {
                        clients = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    }
                    return clients;
                }
                set { clients = value ?? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase); }
            }

            public string FolderForMachine(string machineName)
            {
                if (!string.IsNullOrWhiteSpace(machineName) && Clients != null)
                {
                    foreach (var pair in Clients)
                    {
                        if (string.Equals(pair.Key, machineName, StringComparison.OrdinalIgnoreCase))
                        {
                            return pair.Value ?? string.Empty;
                        }
                    }
                }

                return DataFolder ?? string.Empty;
            }

            public void SetFolderForMachine(string machineName, string folder)
            {
                if (Clients == null)
                {
                    Clients = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                }

                if (!string.IsNullOrWhiteSpace(machineName))
                {
                    Clients[machineName.Trim()] = folder ?? string.Empty;
                }
            }
        }
    }
}
