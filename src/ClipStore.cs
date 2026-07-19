using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace Clipman
{
    internal sealed class ClipStore : IDisposable
    {
        private readonly object sync = new object();
        private FileSystemWatcher watcher;
        private Timer reloadTimer;
        private Timer serverPollTimer;
        private ClipDatabase database = new ClipDatabase();
        private Func<string> passwordProvider;
        private ServerStorageClient serverClient;
        private string serverRevision = string.Empty;
        private bool serverSyncInProgress;
        private bool storageUnavailable;
        private long serverLastPollUnixMs;
        private long serverLastSuccessUnixMs;
        private long serverLastUploadUnixMs;
        private long serverNextPollUnixMs;
        private int serverConsecutiveFailures;
        private bool lastChangeWasExternal;

        public event EventHandler Changed;

        public string DatabasePath { get; private set; }
        public string LastStorageError { get; private set; }

        public ServerSyncStatus GetServerSyncStatus()
        {
            lock (sync)
            {
                return new ServerSyncStatus
                {
                    Enabled = serverClient != null,
                    Configured = serverClient != null && serverClient.IsConfigured,
                    Revision = serverRevision,
                    LastPollUnixMs = serverLastPollUnixMs,
                    LastSuccessUnixMs = serverLastSuccessUnixMs,
                    LastUploadUnixMs = serverLastUploadUnixMs,
                    NextPollUnixMs = serverNextPollUnixMs,
                    ConsecutiveFailures = serverConsecutiveFailures,
                    LastError = LastStorageError
                };
            }
        }
        public bool LastChangeWasExternal
        {
            get
            {
                lock (sync)
                {
                    return lastChangeWasExternal;
                }
            }
        }

        public ClipStore(string databasePath) : this(databasePath, string.Empty)
        {
        }

        public ClipStore(string databasePath, string password)
        {
            passwordProvider = () => password ?? string.Empty;
            SetDatabasePath(databasePath);
        }

        public ClipStore(string databasePath, Func<string> passwordProvider)
        {
            this.passwordProvider = passwordProvider ?? (() => string.Empty);
            SetDatabasePath(databasePath);
        }

        public void SetDatabasePath(string databasePath)
        {
            SetDatabasePath(databasePath, passwordProvider);
        }

        public void SetDatabasePath(string databasePath, string password)
        {
            SetDatabasePath(databasePath, () => password ?? string.Empty);
        }

        public void SetDatabasePath(string databasePath, Func<string> passwordProvider)
        {
            if (string.IsNullOrWhiteSpace(databasePath))
            {
                throw new ArgumentException("Database path cannot be blank.", "databasePath");
            }

            lock (sync)
            {
                DatabasePath = databasePath;
                this.passwordProvider = passwordProvider ?? (() => string.Empty);
                LoadLocked();
                ResetWatcherLocked();
            }

            OnChanged();
        }

        public void ConfigureServerStorage(bool enabled, string serverUrl, string serverToken)
        {
            var queueInitialSync = false;
            lock (sync)
            {
                if (serverPollTimer != null)
                {
                    serverPollTimer.Dispose();
                    serverPollTimer = null;
                }

                serverClient = enabled ? new ServerStorageClient(serverUrl, serverToken, CurrentPassword()) : null;
                serverRevision = string.Empty;
                ResetServerStatusLocked();
                if (serverClient == null || !serverClient.IsConfigured)
                {
                    return;
                }

                serverPollTimer = new Timer(delegate { PollServer(); }, null, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
                queueInitialSync = true;
            }

            if (queueInitialSync)
            {
                QueueInitialServerSync();
            }
            OnChanged();
        }

        public void ChangeDatabasePassword()
        {
            lock (sync)
            {
                SaveLocked();
            }
        }

        public void Reload()
        {
            lock (sync)
            {
                LoadLocked();
                if (serverClient != null && serverClient.IsConfigured)
                {
                    SyncFromServerLocked(false);
                }
                ResetWatcherLocked();
            }

            OnChanged();
        }

        public List<ClipEntry> GetEntries()
        {
            return GetEntries("LastUsed", "All", true);
        }

        public List<ClipEntry> GetEntries(string sortMode)
        {
            return GetEntries(sortMode, "All", true);
        }

        public List<ClipEntry> GetEntries(string sortMode, string groupFilter)
        {
            return GetEntries(sortMode, groupFilter, true);
        }

        public List<ClipEntry> GetEntries(string sortMode, string groupFilter, bool descending)
        {
            lock (sync)
            {
                var filtered = FilterByGroup(database.Entries, groupFilter).ToList();
                var pinned = filtered
                    .Where(e => e.Pinned)
                    .OrderBy(e => e.ManualOrder)
                    .ThenByDescending(e => e.CreatedUnixMs);
                var normal = SortNormalEntries(filtered.Where(e => !e.Pinned), sortMode, descending);

                return pinned.Concat(normal).Select(Clone).ToList();
            }
        }

        public ClipEntry GetEntryById(string id)
        {
            if (string.IsNullOrWhiteSpace(id)) return null;
            lock (sync)
            {
                var entry = database.Entries.FirstOrDefault(e => string.Equals(e.Id, id, StringComparison.Ordinal));
                return entry == null ? null : Clone(entry);
            }
        }

        public ClipEntry GetNewestRemoteEntry(string localMachineName)
        {
            var local = (localMachineName ?? string.Empty).Trim();
            lock (sync)
            {
                var entry = database.Entries
                    .Where(e => e != null &&
                        !string.IsNullOrEmpty(e.Text) &&
                        !string.Equals((e.SourceMachine ?? string.Empty).Trim(), local, StringComparison.OrdinalIgnoreCase))
                    .OrderByDescending(e => e.CreatedUnixMs)
                    .FirstOrDefault();
                return entry == null ? null : Clone(entry);
            }
        }

        public bool HasRecentlyTouchedRemoteText(string text, string localMachineName, long withinMilliseconds)
        {
            if (string.IsNullOrEmpty(text)) return false;
            var local = (localMachineName ?? string.Empty).Trim();
            var cutoff = TimeUtil.NowUnixMs() - Math.Max(1, withinMilliseconds);
            lock (sync)
            {
                return database.Entries.Any(e =>
                    e != null &&
                    string.Equals(e.Text ?? string.Empty, text, StringComparison.Ordinal) &&
                    !string.IsNullOrWhiteSpace(e.SourceMachine) &&
                    !string.Equals((e.SourceMachine ?? string.Empty).Trim(), local, StringComparison.OrdinalIgnoreCase) &&
                    Math.Max(e.CreatedUnixMs, e.LastUsedUnixMs) >= cutoff);
            }
        }

        private static IEnumerable<ClipEntry> SortNormalEntries(IEnumerable<ClipEntry> entries, string sortMode, bool descending)
        {
            switch ((sortMode ?? string.Empty).Trim().ToUpperInvariant())
            {
                case "ADDED":
                    return descending
                        ? entries.OrderByDescending(e => e.CreatedUnixMs)
                        : entries.OrderBy(e => e.CreatedUnixMs);
                case "TEXT":
                    return descending
                        ? entries.OrderByDescending(e => e.Text ?? string.Empty, StringComparer.CurrentCultureIgnoreCase)
                        : entries.OrderBy(e => e.Text ?? string.Empty, StringComparer.CurrentCultureIgnoreCase);
                case "GROUP":
                    return descending
                        ? entries
                        .OrderByDescending(e => string.IsNullOrWhiteSpace(e.Group) ? "\uffff" : e.Group.Trim(), StringComparer.CurrentCultureIgnoreCase)
                        .ThenByDescending(e => e.Text ?? string.Empty, StringComparer.CurrentCultureIgnoreCase)
                        : entries
                        .OrderBy(e => string.IsNullOrWhiteSpace(e.Group) ? "\uffff" : e.Group.Trim(), StringComparer.CurrentCultureIgnoreCase)
                        .ThenBy(e => e.Text ?? string.Empty, StringComparer.CurrentCultureIgnoreCase);
                case "MACHINE":
                    return descending
                        ? entries
                        .OrderByDescending(e => string.IsNullOrWhiteSpace(e.SourceMachine) ? "\uffff" : e.SourceMachine.Trim(), StringComparer.CurrentCultureIgnoreCase)
                        .ThenByDescending(e => e.Text ?? string.Empty, StringComparer.CurrentCultureIgnoreCase)
                        : entries
                        .OrderBy(e => string.IsNullOrWhiteSpace(e.SourceMachine) ? "\uffff" : e.SourceMachine.Trim(), StringComparer.CurrentCultureIgnoreCase)
                        .ThenBy(e => e.Text ?? string.Empty, StringComparer.CurrentCultureIgnoreCase);
                case "MANUAL":
                    return descending
                        ? entries.OrderByDescending(e => e.ManualOrder)
                        : entries.OrderBy(e => e.ManualOrder);
                default:
                    return descending
                        ? entries.OrderByDescending(e => e.LastUsedUnixMs)
                        : entries.OrderBy(e => e.LastUsedUnixMs);
            }
        }

        public ClipEntry AddText(string text, string duplicateMode, int maxEntries, int maxDays)
        {
            return AddText(text, duplicateMode, maxEntries, maxDays, string.Empty);
        }

        public ClipEntry AddText(string text, string duplicateMode, int maxEntries, int maxDays, string group)
        {
            if (string.IsNullOrEmpty(text))
            {
                return null;
            }

            lock (sync)
            {
                var existing = database.Entries.FirstOrDefault(e => e.Text == text);
                var mode = (duplicateMode ?? "MoveToTop").Trim();
                if (existing != null && mode.Equals("Ignore", StringComparison.OrdinalIgnoreCase))
                {
                    return Clone(existing);
                }
                if (existing != null && mode.Equals("MoveToTop", StringComparison.OrdinalIgnoreCase))
                {
                    existing.LastUsedUnixMs = TimeUtil.NowUnixMs();
                    existing.SourceMachine = CurrentMachineName();
                    PruneLocked(maxEntries, maxDays);
                    SaveLocked();
                    OnChanged();
                    return Clone(existing);
                }

                var entry = new ClipEntry
                {
                    Id = Guid.NewGuid().ToString("N"),
                    Text = text,
                    Group = (group ?? string.Empty).Trim(),
                    SourceMachine = CurrentMachineName(),
                    CreatedUnixMs = TimeUtil.NowUnixMs(),
                    LastUsedUnixMs = TimeUtil.NowUnixMs(),
                    ManualOrder = NextManualOrderLocked()
                };
                database.Entries.Add(entry);
                PruneLocked(maxEntries, maxDays);
                SaveLocked();
                OnChanged();
                return Clone(entry);
            }
        }

        public int PushEntriesToOtherMachines(IEnumerable<string> ids, bool keepDuplicateEntries)
        {
            var idSet = new HashSet<string>((ids ?? Enumerable.Empty<string>()).Where(id => !string.IsNullOrWhiteSpace(id)));
            if (idSet.Count == 0) return 0;

            lock (sync)
            {
                var selected = database.Entries
                    .Where(e => e != null && idSet.Contains(e.Id) && !string.IsNullOrEmpty(e.Text))
                    .ToList();
                if (selected.Count == 0) return 0;

                var now = TimeUtil.NowUnixMs();
                foreach (var entry in selected)
                {
                    var stamp = now++;
                    if (!keepDuplicateEntries)
                    {
                        entry.SourceMachine = CurrentMachineName();
                        entry.CreatedUnixMs = stamp;
                        entry.LastUsedUnixMs = stamp;
                        continue;
                    }

                    database.Entries.Add(new ClipEntry
                    {
                        Id = Guid.NewGuid().ToString("N"),
                        Text = entry.Text ?? string.Empty,
                        Name = entry.Name ?? string.Empty,
                        Group = entry.Group ?? string.Empty,
                        SourceMachine = CurrentMachineName(),
                        CreatedUnixMs = stamp,
                        LastUsedUnixMs = stamp,
                        Pinned = false,
                        IsTemplate = entry.IsTemplate,
                        ManualOrder = NextManualOrderLocked()
                    });
                }

                SaveLocked();
                OnChanged();
                return selected.Count;
            }
        }

        public void MarkUsed(string id)
        {
            lock (sync)
            {
                var entry = database.Entries.FirstOrDefault(e => e.Id == id);
                if (entry == null) return;
                entry.LastUsedUnixMs = TimeUtil.NowUnixMs();
                SaveLocked();
            }
        }

        public void Delete(string id)
        {
            lock (sync)
            {
                var entry = database.Entries.FirstOrDefault(e => e.Id == id);
                if (entry == null) return;
                database.Entries.Remove(entry);
                AddDeletedEntryLocked(id, entry.Text);
                SaveLocked();
                OnChanged();
            }
        }

        public int DeleteMany(IEnumerable<string> ids)
        {
            var idSet = new HashSet<string>((ids ?? Enumerable.Empty<string>()).Where(id => !string.IsNullOrEmpty(id)));
            if (idSet.Count == 0) return 0;

            lock (sync)
            {
                var removedIds = database.Entries
                    .Where(e => idSet.Contains(e.Id))
                    .Select(e => new { e.Id, e.Text })
                    .ToList();
                var removed = database.Entries.RemoveAll(e => idSet.Contains(e.Id));
                if (removed == 0) return 0;
                foreach (var removedEntry in removedIds)
                {
                    AddDeletedEntryLocked(removedEntry.Id, removedEntry.Text);
                }
                SaveLocked();
                OnChanged();
                return removed;
            }
        }

        public void ReplaceAll(IEnumerable<ClipEntry> entries)
        {
            lock (sync)
            {
                database = new ClipDatabase();
                foreach (var entry in entries.Where(e => e != null && !string.IsNullOrEmpty(e.Text)))
                {
                    database.Entries.Add(new ClipEntry
                    {
                        Id = string.IsNullOrWhiteSpace(entry.Id) ? Guid.NewGuid().ToString("N") : entry.Id,
                        Text = entry.Text,
                        Name = entry.Name ?? string.Empty,
                        Group = entry.Group ?? string.Empty,
                        SourceMachine = entry.SourceMachine ?? string.Empty,
                        CreatedUnixMs = entry.CreatedUnixMs == 0 ? TimeUtil.NowUnixMs() : entry.CreatedUnixMs,
                        LastUsedUnixMs = entry.LastUsedUnixMs == 0 ? TimeUtil.NowUnixMs() : entry.LastUsedUnixMs,
                        Pinned = entry.Pinned,
                        IsTemplate = entry.IsTemplate,
                        ManualOrder = entry.ManualOrder
                    });
                }
                NormalizeManualOrderLocked();
                SaveLocked();
                OnChanged();
            }
        }

        public void ImportFromFile(string path, bool replace)
        {
            var imported = LoadEntriesFromFile(path, CurrentPassword());
            ImportEntries(imported, replace);
        }

        public void ImportFromFile(string path, bool replace, string importPassword)
        {
            var imported = LoadEntriesFromFile(path, importPassword ?? string.Empty);
            ImportEntries(imported, replace);
        }

        private void ImportEntries(List<ClipEntry> imported, bool replace)
        {
            if (replace)
            {
                ReplaceAll(imported);
                return;
            }

            lock (sync)
            {
                foreach (var entry in imported)
                {
                    if (string.IsNullOrEmpty(entry.Text)) continue;
                    if (database.Entries.Any(e => e.Text == entry.Text)) continue;
                    if (entry.ManualOrder <= 0) entry.ManualOrder = NextManualOrderLocked();
                    database.Entries.Add(entry);
                }
                NormalizeManualOrderLocked();
                SaveLocked();
                OnChanged();
            }
        }

        public void ExportToFile(string path)
        {
            ExportToFile(path, CurrentPassword());
        }

        public void ExportToFile(string path, string exportPassword)
        {
            lock (sync)
            {
                database.UpdatedUnixMs = TimeUtil.NowUnixMs();
                ClipDatabaseFile.SaveAtomic(path, database, exportPassword == null ? CurrentPassword() : exportPassword);
            }
        }

        public bool HasCurrentPassword()
        {
            return !string.IsNullOrEmpty(CurrentPassword());
        }

        public bool CurrentPasswordMatches(string password)
        {
            return string.Equals(CurrentPassword(), password ?? string.Empty, StringComparison.Ordinal);
        }

        public bool TogglePinned(string id)
        {
            lock (sync)
            {
                var entry = database.Entries.FirstOrDefault(e => e.Id == id);
                if (entry == null) return false;
                entry.Pinned = !entry.Pinned;
                SaveLocked();
                OnChanged();
                return entry.Pinned;
            }
        }

        public void SetPinned(string id, bool pinned)
        {
            lock (sync)
            {
                var entry = database.Entries.FirstOrDefault(e => e.Id == id);
                if (entry == null) return;
                entry.Pinned = pinned;
                SaveLocked();
                OnChanged();
            }
        }

        public void SetName(string id, string name)
        {
            lock (sync)
            {
                var entry = database.Entries.FirstOrDefault(e => e.Id == id);
                if (entry == null) return;
                entry.Name = (name ?? string.Empty).Trim();
                SaveLocked();
                OnChanged();
            }
        }

        public void SetNameAndText(string id, string name, string text)
        {
            if (string.IsNullOrEmpty(id)) return;
            lock (sync)
            {
                var entry = database.Entries.FirstOrDefault(e => e.Id == id);
                if (entry == null) return;
                entry.Name = (name ?? string.Empty).Trim();
                entry.Text = text ?? string.Empty;
                entry.LastUsedUnixMs = TimeUtil.NowUnixMs();
                SaveLocked();
                OnChanged();
            }
        }

        public void SetTemplate(string id, bool isTemplate)
        {
            if (string.IsNullOrEmpty(id)) return;
            lock (sync)
            {
                var entry = database.Entries.FirstOrDefault(e => e.Id == id);
                if (entry == null) return;
                entry.IsTemplate = isTemplate;
                SaveLocked();
                OnChanged();
            }
        }

        public void SetGroup(IEnumerable<string> ids, string groupName)
        {
            var idSet = new HashSet<string>((ids ?? Enumerable.Empty<string>()).Where(id => !string.IsNullOrEmpty(id)));
            if (idSet.Count == 0) return;
            lock (sync)
            {
                foreach (var entry in database.Entries.Where(e => idSet.Contains(e.Id)))
                {
                    entry.Group = (groupName ?? string.Empty).Trim();
                }
                SaveLocked();
                OnChanged();
            }
        }

        public List<string> GetGroups()
        {
            lock (sync)
            {
                return database.Entries
                    .Select(e => (e.Group ?? string.Empty).Trim())
                    .Where(g => g.Length > 0)
                    .Distinct(StringComparer.CurrentCultureIgnoreCase)
                    .OrderBy(g => g, StringComparer.CurrentCultureIgnoreCase)
                    .ToList();
            }
        }

        public void ReplaceText(string id, string text)
        {
            if (string.IsNullOrEmpty(id)) return;
            lock (sync)
            {
                var entry = database.Entries.FirstOrDefault(e => e.Id == id);
                if (entry == null) return;
                entry.Text = text ?? string.Empty;
                entry.LastUsedUnixMs = TimeUtil.NowUnixMs();
                SaveLocked();
                OnChanged();
            }
        }

        public void MoveEntries(IEnumerable<string> ids, int direction)
        {
            var selectedIds = new HashSet<string>((ids ?? Enumerable.Empty<string>()).Where(id => !string.IsNullOrEmpty(id)));
            if (selectedIds.Count == 0 || direction == 0) return;

            lock (sync)
            {
                NormalizeManualOrderLocked();
                var selectedEntries = database.Entries.Where(e => selectedIds.Contains(e.Id)).ToList();
                if (selectedEntries.Count == 0) return;
                if (selectedEntries.Any(e => e.Pinned != selectedEntries[0].Pinned)) return;

                var pinnedBand = selectedEntries[0].Pinned;
                var ordered = database.Entries
                    .Where(e => e.Pinned == pinnedBand)
                    .OrderBy(e => e.ManualOrder)
                    .ToList();
                var selected = ordered.Where(e => selectedIds.Contains(e.Id)).ToList();
                if (selected.Count == 0) return;
                var indexes = selected.Select(e => ordered.IndexOf(e)).OrderBy(i => i).ToList();
                var first = indexes.First();
                var last = indexes.Last();
                foreach (var entry in selected)
                {
                    ordered.Remove(entry);
                }

                if (direction < 0)
                {
                    ordered.InsertRange(Math.Max(0, first - 1), selected);
                }
                else
                {
                    ordered.InsertRange(Math.Min(ordered.Count, last + 1 - selected.Count + 1), selected);
                }

                for (var i = 0; i < ordered.Count; i++)
                {
                    ordered[i].ManualOrder = i + 1;
                }
                SaveLocked();
                OnChanged();
            }
        }

        public void SetManualOrder(IEnumerable<string> orderedIds)
        {
            var order = (orderedIds ?? Enumerable.Empty<string>())
                .Where(id => !string.IsNullOrEmpty(id))
                .Select((id, index) => new { Id = id, Index = index + 1L })
                .ToDictionary(x => x.Id, x => x.Index);
            if (order.Count == 0) return;

            lock (sync)
            {
                foreach (var entry in database.Entries)
                {
                    long manualOrder;
                    if (order.TryGetValue(entry.Id, out manualOrder))
                    {
                        entry.ManualOrder = manualOrder;
                    }
                }
                SaveLocked();
                OnChanged();
            }
        }

        public List<ClipEntry> InsertEntriesAfter(IEnumerable<ClipEntry> entries, string afterId, bool removeDuplicates)
        {
            var source = (entries ?? Enumerable.Empty<ClipEntry>())
                .Where(e => e != null && !string.IsNullOrEmpty(e.Text))
                .ToList();
            var inserted = new List<ClipEntry>();
            if (source.Count == 0) return inserted;

            lock (sync)
            {
                NormalizeManualOrderLocked();
                if (removeDuplicates)
                {
                    var texts = new HashSet<string>(source.Select(e => e.Text));
                    database.Entries.RemoveAll(e => texts.Contains(e.Text));
                }

                var after = string.IsNullOrEmpty(afterId)
                    ? null
                    : database.Entries.FirstOrDefault(e => e.Id == afterId);
                var order = after == null ? NextManualOrderLocked() : after.ManualOrder + 1;
                foreach (var entry in database.Entries.Where(e => e.ManualOrder >= order))
                {
                    entry.ManualOrder += source.Count;
                }

                foreach (var entry in source)
                {
                    var now = TimeUtil.NowUnixMs();
                    var newEntry = new ClipEntry
                    {
                        Id = Guid.NewGuid().ToString("N"),
                        Text = entry.Text,
                        Name = entry.Name ?? string.Empty,
                        Group = entry.Group ?? string.Empty,
                        SourceMachine = entry.SourceMachine ?? string.Empty,
                        CreatedUnixMs = entry.CreatedUnixMs == 0 ? now : entry.CreatedUnixMs,
                        LastUsedUnixMs = entry.LastUsedUnixMs == 0 ? now : entry.LastUsedUnixMs,
                        Pinned = entry.Pinned,
                        IsTemplate = entry.IsTemplate,
                        ManualOrder = order++
                    };
                    database.Entries.Add(newEntry);
                    inserted.Add(Clone(newEntry));
                }

                NormalizeManualOrderLocked();
                SaveLocked();
                OnChanged();
                return inserted;
            }
        }

        public List<ClipEntry> InsertEntriesAtNormalStart(IEnumerable<ClipEntry> entries, bool removeDuplicates)
        {
            var source = (entries ?? Enumerable.Empty<ClipEntry>())
                .Where(e => e != null && !string.IsNullOrEmpty(e.Text))
                .ToList();
            var inserted = new List<ClipEntry>();
            if (source.Count == 0) return inserted;

            lock (sync)
            {
                NormalizeManualOrderLocked();
                if (removeDuplicates)
                {
                    var texts = new HashSet<string>(source.Select(e => e.Text));
                    database.Entries.RemoveAll(e => texts.Contains(e.Text));
                }

                var firstNormal = database.Entries
                    .Where(e => !e.Pinned)
                    .OrderBy(e => e.ManualOrder)
                    .FirstOrDefault();
                var order = firstNormal == null ? NextManualOrderLocked() : firstNormal.ManualOrder;
                foreach (var entry in database.Entries.Where(e => e.ManualOrder >= order))
                {
                    entry.ManualOrder += source.Count;
                }

                foreach (var entry in source)
                {
                    var now = TimeUtil.NowUnixMs();
                    var newEntry = new ClipEntry
                    {
                        Id = Guid.NewGuid().ToString("N"),
                        Text = entry.Text,
                        Name = entry.Name ?? string.Empty,
                        Group = entry.Group ?? string.Empty,
                        SourceMachine = entry.SourceMachine ?? string.Empty,
                        CreatedUnixMs = entry.CreatedUnixMs == 0 ? now : entry.CreatedUnixMs,
                        LastUsedUnixMs = entry.LastUsedUnixMs == 0 ? now : entry.LastUsedUnixMs,
                        Pinned = false,
                        IsTemplate = entry.IsTemplate,
                        ManualOrder = order++
                    };
                    database.Entries.Add(newEntry);
                    inserted.Add(Clone(newEntry));
                }

                NormalizeManualOrderLocked();
                SaveLocked();
                OnChanged();
                return inserted;
            }
        }

        public static List<ClipEntry> LoadEntriesFromFile(string path)
        {
            return LoadEntriesFromFile(path, string.Empty);
        }

        public static List<ClipEntry> LoadEntriesFromFile(string path, string password)
        {
            var extension = Path.GetExtension(path).ToLowerInvariant();
            if (extension == ".txt")
            {
                return File.ReadAllText(path).Split(new[] { "\r\n---\r\n", "\n---\n" }, StringSplitOptions.RemoveEmptyEntries)
                    .Select(t => new ClipEntry { Text = t.Trim(), SourceMachine = CurrentMachineName(), CreatedUnixMs = TimeUtil.NowUnixMs(), LastUsedUnixMs = TimeUtil.NowUnixMs() })
                    .Where(e => e.Text.Length > 0)
                    .ToList();
            }

            if (SqliteClipboardImporter.LooksLikeSqliteDatabase(path))
            {
                return SqliteClipboardImporter.LoadEntries(path);
            }

            var db = ClipDatabaseFile.Load(path, password);
            return (db.Entries ?? new List<ClipEntry>())
                .Where(e => !string.IsNullOrEmpty(e.Text))
                .Select(Clone)
                .ToList();
        }

        private void LoadLocked()
        {
            var password = CurrentPassword();
            try
            {
                SyncConflictResolver.ResolveDatabaseConflicts(DatabasePath, password);
                database = ClipDatabaseFile.Load(DatabasePath, password);
                if (database.Entries == null) database.Entries = new List<ClipEntry>();
                NormalizeDeletedEntriesLocked();
                ApplyDeletedEntriesLocked();
                NormalizeManualOrderLocked();
                storageUnavailable = false;
                LastStorageError = string.Empty;
            }
            catch (Exception ex)
            {
                if (!IsStorageAccessException(ex)) throw;
                database = new ClipDatabase();
                storageUnavailable = true;
                LastStorageError = ex.Message;
            }
        }

        private void SaveLocked()
        {
            database.UpdatedUnixMs = TimeUtil.NowUnixMs();
            try
            {
                if (storageUnavailable)
                {
                    MergeExistingDatabaseIfAvailableLocked();
                }

                NormalizeDeletedEntriesLocked();
                ApplyDeletedEntriesLocked();
                ClipDatabaseFile.SaveAtomic(DatabasePath, database, CurrentPassword());
                storageUnavailable = false;
                LastStorageError = string.Empty;
                if (watcher == null)
                {
                    ResetWatcherLocked();
                }
                UploadToServerLocked();
            }
            catch (Exception ex)
            {
                if (!IsStorageAccessException(ex) && !IsRecoverableServerException(ex)) throw;
                storageUnavailable = true;
                LastStorageError = ex.Message;
            }
        }

        private string CurrentPassword()
        {
            return passwordProvider == null ? string.Empty : (passwordProvider() ?? string.Empty);
        }

        private void PruneLocked(int maxEntries, int maxDays)
        {
            if (maxDays > 0)
            {
                var cutoff = TimeUtil.NowUnixMs() - (long)TimeSpan.FromDays(maxDays).TotalMilliseconds;
                database.Entries.RemoveAll(e => !IsProtected(e) && e.LastUsedUnixMs > 0 && e.LastUsedUnixMs < cutoff);
            }

            if (maxEntries > 0)
            {
                var removable = database.Entries
                    .Where(e => !IsProtected(e))
                    .OrderByDescending(e => e.LastUsedUnixMs)
                    .Skip(maxEntries)
                    .Select(e => e.Id)
                    .ToList();
                if (removable.Count > 0)
                {
                    database.Entries.RemoveAll(e => removable.Contains(e.Id));
                }
            }
        }

        private long NextManualOrderLocked()
        {
            return database.Entries.Count == 0 ? 1 : database.Entries.Max(e => e.ManualOrder) + 1;
        }

        private void NormalizeManualOrderLocked()
        {
            var next = 1L;
            foreach (var entry in database.Entries.OrderBy(e => e.ManualOrder <= 0 ? long.MaxValue : e.ManualOrder).ThenBy(e => e.CreatedUnixMs))
            {
                if (entry.CreatedUnixMs == 0) entry.CreatedUnixMs = TimeUtil.NowUnixMs();
                if (entry.LastUsedUnixMs == 0) entry.LastUsedUnixMs = entry.CreatedUnixMs;
                if (entry.Name == null) entry.Name = string.Empty;
                if (entry.Group == null) entry.Group = string.Empty;
                if (entry.SourceMachine == null) entry.SourceMachine = string.Empty;
                entry.ManualOrder = next++;
            }
        }

        private void ResetWatcherLocked()
        {
            if (watcher != null) watcher.Dispose();
            if (reloadTimer != null) reloadTimer.Dispose();
            watcher = null;
            reloadTimer = null;

            var dir = Path.GetDirectoryName(DatabasePath);
            var file = Path.GetFileName(DatabasePath);
            if (string.IsNullOrEmpty(dir) || string.IsNullOrEmpty(file))
            {
                return;
            }

            try
            {
                Directory.CreateDirectory(dir);
                reloadTimer = new Timer(delegate { ReloadFromWatcher(); }, null, Timeout.Infinite, Timeout.Infinite);
                watcher = new FileSystemWatcher(dir, file)
                {
                    NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName | NotifyFilters.CreationTime
                };
                watcher.Changed += WatcherChanged;
                watcher.Created += WatcherChanged;
                watcher.Renamed += WatcherChanged;
                watcher.EnableRaisingEvents = true;
            }
            catch (Exception ex)
            {
                if (!IsStorageAccessException(ex)) throw;
                storageUnavailable = true;
                LastStorageError = ex.Message;
                if (watcher != null) watcher.Dispose();
                if (reloadTimer != null) reloadTimer.Dispose();
                watcher = null;
                reloadTimer = null;
            }
        }

        private void ResetServerStatusLocked()
        {
            serverLastPollUnixMs = 0;
            serverLastSuccessUnixMs = 0;
            serverLastUploadUnixMs = 0;
            serverNextPollUnixMs = 0;
            serverConsecutiveFailures = 0;
        }

        private void MarkServerSuccessLocked(bool upload)
        {
            var now = TimeUtil.NowUnixMs();
            serverLastSuccessUnixMs = now;
            if (upload)
            {
                serverLastUploadUnixMs = now;
            }
            serverConsecutiveFailures = 0;
            serverNextPollUnixMs = 0;
        }

        private void MarkServerFailureLocked()
        {
            var now = TimeUtil.NowUnixMs();
            serverConsecutiveFailures = Math.Min(serverConsecutiveFailures + 1, 8);
            var delaySeconds = Math.Min(60, 2 << Math.Min(serverConsecutiveFailures, 5));
            serverNextPollUnixMs = now + delaySeconds * 1000L;
        }

        private void PollServer()
        {
            var changed = false;
            lock (sync)
            {
                try
                {
                    if (serverClient == null || !serverClient.IsConfigured || serverSyncInProgress) return;
                    var now = TimeUtil.NowUnixMs();
                    if (serverNextPollUnixMs > now) return;
                    serverLastPollUnixMs = now;
                    var metadata = serverClient.GetMetadata();
                    storageUnavailable = false;
                    LastStorageError = string.Empty;
                    MarkServerSuccessLocked(false);
                    if (!string.IsNullOrWhiteSpace(metadata.Revision) &&
                        !string.Equals(metadata.Revision, serverRevision, StringComparison.Ordinal))
                    {
                        changed = SyncFromServerLocked(false);
                    }
                }
                catch (WebException ex)
                {
                    if (serverClient != null && serverClient.IsNotFound(ex))
                    {
                        try
                        {
                            changed = SyncFromServerLocked(true);
                            return;
                        }
                        catch (WebException retryEx)
                        {
                            if (serverClient != null && serverClient.IsNotFound(retryEx)) return;
                            storageUnavailable = true;
                            LastStorageError = "Server poll failed: " + retryEx.Message;
                            MarkServerFailureLocked();
                            return;
                        }
                    }
                    storageUnavailable = true;
                    LastStorageError = "Server poll failed: " + ex.Message;
                    MarkServerFailureLocked();
                    return;
                }
                catch (Exception ex)
                {
                    if (!IsRecoverableServerException(ex)) return;
                    storageUnavailable = true;
                    LastStorageError = "Server poll failed: " + ex.Message;
                    MarkServerFailureLocked();
                    return;
                }
            }

            if (changed)
            {
                OnChanged(true);
            }
        }

        private bool SyncFromServerLocked(bool uploadLocalWhenMissing)
        {
            if (serverClient == null || !serverClient.IsConfigured) return false;
            if (serverSyncInProgress) return false;

            serverSyncInProgress = true;
            try
            {
                ServerDatabaseDownload download;
                try
                {
                    download = serverClient.Download();
                }
                catch (WebException ex)
                {
                    if (serverClient.IsNotFound(ex))
                    {
                        if (uploadLocalWhenMissing && !storageUnavailable && database.Entries.Count > 0)
                        {
                            ClipDatabaseFile.SaveAtomic(DatabasePath, database, CurrentPassword());
                            var metadata = serverClient.Upload(File.ReadAllBytes(DatabasePath), string.Empty);
                            serverRevision = metadata == null ? string.Empty : metadata.Revision;
                            storageUnavailable = false;
                            LastStorageError = string.Empty;
                            MarkServerSuccessLocked(true);
                        }
                        return false;
                    }
                    throw;
                }

                if (download.Data == null || download.Data.Length == 0) return false;
                var tempPath = DatabasePath + ".server-download.tmp";
                WriteBytesAtomic(tempPath, download.Data);
                var downloadedDatabase = ClipDatabaseFile.Load(tempPath, CurrentPassword());
                TryDelete(tempPath);
                var uploadMerged = HasLocalStateMissingFromServer(downloadedDatabase, database);
                var changed = MergeDatabaseIntoLocked(database, downloadedDatabase);
                if (database.Entries == null) database.Entries = new List<ClipEntry>();
                NormalizeManualOrderLocked();
                serverRevision = download.Metadata == null ? string.Empty : download.Metadata.Revision;
                ClipDatabaseFile.SaveAtomic(DatabasePath, database, CurrentPassword());
                if (uploadMerged)
                {
                    var mergedMetadata = serverClient.Upload(File.ReadAllBytes(DatabasePath), serverRevision);
                    serverRevision = mergedMetadata == null ? string.Empty : mergedMetadata.Revision;
                }
                storageUnavailable = false;
                LastStorageError = string.Empty;
                MarkServerSuccessLocked(uploadMerged);
                return changed;
            }
            finally
            {
                serverSyncInProgress = false;
            }
        }

        private void QueueInitialServerSync()
        {
            ThreadPool.QueueUserWorkItem(delegate
            {
                var changed = false;
                lock (sync)
                {
                    try
                    {
                        changed = SyncFromServerLocked(true);
                    }
                    catch (Exception ex)
                    {
                        storageUnavailable = true;
                        LastStorageError = "Server sync failed: " + ex.Message;
                        MarkServerFailureLocked();
                    }
                }

                OnChanged(changed);
            });
        }

        private void UploadToServerLocked()
        {
            if (serverClient == null || !serverClient.IsConfigured || serverSyncInProgress) return;
            if (!File.Exists(DatabasePath)) return;

            serverSyncInProgress = true;
            try
            {
                try
                {
                    var metadata = serverClient.Upload(File.ReadAllBytes(DatabasePath), serverRevision);
                    serverRevision = metadata == null ? string.Empty : metadata.Revision;
                    storageUnavailable = false;
                    LastStorageError = string.Empty;
                    MarkServerSuccessLocked(true);
                    return;
                }
                catch (WebException ex)
                {
                    if (!serverClient.IsConflict(ex)) throw;
                }

                var server = serverClient.Download();
                var localDatabase = database;
                WriteBytesAtomic(DatabasePath + ".server.tmp", server.Data);
                var serverDatabase = ClipDatabaseFile.Load(DatabasePath + ".server.tmp", CurrentPassword());
                MergeDatabaseIntoLocked(localDatabase, serverDatabase);
                database = localDatabase;
                NormalizeManualOrderLocked();
                ClipDatabaseFile.SaveAtomic(DatabasePath, database, CurrentPassword());
                var retry = serverClient.Upload(File.ReadAllBytes(DatabasePath), server.Metadata == null ? string.Empty : server.Metadata.Revision);
                serverRevision = retry == null ? string.Empty : retry.Revision;
                TryDelete(DatabasePath + ".server.tmp");
                storageUnavailable = false;
                LastStorageError = string.Empty;
                MarkServerSuccessLocked(true);
            }
            catch
            {
                MarkServerFailureLocked();
                throw;
            }
            finally
            {
                serverSyncInProgress = false;
            }
        }

        private static bool MergeDatabaseIntoLocked(ClipDatabase target, ClipDatabase source)
        {
            if (target == null || source == null || source.Entries == null) return false;
            if (target.Entries == null) target.Entries = new List<ClipEntry>();
            var changed = false;
            changed = MergeDeletedEntries(target, source) || changed;
            ApplyDeletedEntries(target);
            foreach (var entry in source.Entries.Where(e => e != null && !string.IsNullOrEmpty(e.Text)))
            {
                if (IsDeleted(target, entry)) continue;
                var existing = target.Entries.FirstOrDefault(e =>
                    !string.IsNullOrEmpty(e.Id) &&
                    string.Equals(e.Id, entry.Id, StringComparison.Ordinal));
                if (existing == null)
                {
                    existing = target.Entries.FirstOrDefault(e => string.Equals(e.Text, entry.Text, StringComparison.Ordinal));
                }
                if (existing == null)
                {
                    target.Entries.Add(Clone(entry));
                    changed = true;
                    continue;
                }

                changed = MergeEntryMetadata(existing, entry) || changed;
            }
            ApplyDeletedEntries(target);
            return changed;
        }

        private static bool MergeEntryMetadata(ClipEntry existing, ClipEntry incoming)
        {
            var changed = false;
            var incomingWins = incoming.LastUsedUnixMs >= existing.LastUsedUnixMs;
            var incomingCreatedWins = incoming.CreatedUnixMs > existing.CreatedUnixMs;

            if (incoming.LastUsedUnixMs > existing.LastUsedUnixMs)
            {
                existing.LastUsedUnixMs = incoming.LastUsedUnixMs;
                changed = true;
            }
            if (incoming.CreatedUnixMs > 0 &&
                (existing.CreatedUnixMs == 0 ||
                 incomingCreatedWins ||
                 (!incomingWins && incoming.CreatedUnixMs < existing.CreatedUnixMs)))
            {
                existing.CreatedUnixMs = incoming.CreatedUnixMs;
                changed = true;
            }
            if (!string.IsNullOrWhiteSpace(incoming.Name) && incomingWins && !string.Equals(existing.Name ?? string.Empty, incoming.Name.Trim(), StringComparison.Ordinal))
            {
                existing.Name = incoming.Name.Trim();
                changed = true;
            }
            if (!string.IsNullOrWhiteSpace(incoming.Group) && incomingWins && !string.Equals(existing.Group ?? string.Empty, incoming.Group.Trim(), StringComparison.Ordinal))
            {
                existing.Group = incoming.Group.Trim();
                changed = true;
            }
            if (!string.IsNullOrWhiteSpace(incoming.SourceMachine) &&
                (incomingWins || incomingCreatedWins) &&
                !string.Equals(existing.SourceMachine ?? string.Empty, incoming.SourceMachine.Trim(), StringComparison.Ordinal))
            {
                existing.SourceMachine = incoming.SourceMachine.Trim();
                changed = true;
            }
            if (incoming.Pinned && !existing.Pinned)
            {
                existing.Pinned = true;
                changed = true;
            }
            if (existing.ManualOrder <= 0 || (incoming.ManualOrder > 0 && incoming.ManualOrder < existing.ManualOrder))
            {
                if (existing.ManualOrder != incoming.ManualOrder)
                {
                    existing.ManualOrder = incoming.ManualOrder;
                    changed = true;
                }
            }

            return changed;
        }

        private static bool HasLocalStateMissingFromServer(ClipDatabase target, ClipDatabase source)
        {
            if (target == null || source == null || source.Entries == null) return false;
            NormalizeDeletedEntries(target);
            NormalizeDeletedEntries(source);

            if (source.DeletedEntries != null)
            {
                foreach (var deleted in source.DeletedEntries.Where(d => d != null && !string.IsNullOrWhiteSpace(d.Id)))
                {
                    var targetDeleted = target.DeletedEntries == null
                        ? null
                        : target.DeletedEntries.FirstOrDefault(d => string.Equals(d.Id, deleted.Id, StringComparison.Ordinal));
                    if (targetDeleted == null || deleted.DeletedUnixMs > targetDeleted.DeletedUnixMs)
                    {
                        return true;
                    }
                }
            }

            var targetEntries = target.Entries ?? new List<ClipEntry>();
            foreach (var entry in source.Entries.Where(e => e != null && !string.IsNullOrEmpty(e.Text)))
            {
                if (IsDeleted(target, entry)) continue;
                if (!targetEntries.Any(e =>
                    (!string.IsNullOrEmpty(e.Id) && string.Equals(e.Id, entry.Id, StringComparison.Ordinal)) ||
                    string.Equals(e.Text, entry.Text, StringComparison.Ordinal)))
                {
                    return true;
                }
            }
            return false;
        }

        private static void WriteBytesAtomic(string path, byte[] data)
        {
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            var temp = path + ".download.tmp";
            File.WriteAllBytes(temp, data ?? new byte[0]);
            if (File.Exists(path))
            {
                File.Replace(temp, path, null);
            }
            else
            {
                File.Move(temp, path);
            }
        }

        private static void TryDelete(string path)
        {
            try { if (File.Exists(path)) File.Delete(path); }
            catch { }
        }

        private void WatcherChanged(object sender, FileSystemEventArgs e)
        {
            if (reloadTimer != null) reloadTimer.Change(500, Timeout.Infinite);
        }

        private void ReloadFromWatcher()
        {
            lock (sync)
            {
                try
                {
                    LoadLocked();
                }
                catch
                {
                    return;
                }
            }

            OnChanged(true);
        }

        private static ClipEntry Clone(ClipEntry entry)
        {
            return new ClipEntry
            {
                Id = entry.Id,
                Text = entry.Text ?? string.Empty,
                Name = entry.Name ?? string.Empty,
                Group = entry.Group ?? string.Empty,
                SourceMachine = entry.SourceMachine ?? string.Empty,
                CreatedUnixMs = entry.CreatedUnixMs,
                LastUsedUnixMs = entry.LastUsedUnixMs,
                Pinned = entry.Pinned,
                IsTemplate = entry.IsTemplate,
                ManualOrder = entry.ManualOrder
            };
        }

        private static IEnumerable<ClipEntry> FilterByGroup(IEnumerable<ClipEntry> source, string groupFilter)
        {
            var filter = (groupFilter ?? "All").Trim();
            if (filter.Length == 0 || filter.Equals("All", StringComparison.OrdinalIgnoreCase))
            {
                return source;
            }
            if (filter.Equals("Pinned", StringComparison.OrdinalIgnoreCase))
            {
                return source.Where(e => e.Pinned);
            }
            if (filter.Equals("Named", StringComparison.OrdinalIgnoreCase))
            {
                return source.Where(e => !string.IsNullOrWhiteSpace(e.Name));
            }
            if (filter.Equals("Ungrouped", StringComparison.OrdinalIgnoreCase))
            {
                return source.Where(e => string.IsNullOrWhiteSpace(e.Group));
            }
            return source.Where(e => string.Equals((e.Group ?? string.Empty).Trim(), filter, StringComparison.CurrentCultureIgnoreCase));
        }

        private static bool IsProtected(ClipEntry entry)
        {
            return entry != null && (entry.Pinned || !string.IsNullOrWhiteSpace(entry.Name));
        }

        private void MergeExistingDatabaseIfAvailableLocked()
        {
            if (!File.Exists(DatabasePath)) return;
            var existing = ClipDatabaseFile.Load(DatabasePath, CurrentPassword());
            if (existing == null || existing.Entries == null || existing.Entries.Count == 0) return;

            MergeDeletedEntries(database, existing);
            ApplyDeletedEntriesLocked();
            foreach (var entry in existing.Entries.Where(e => e != null && !string.IsNullOrEmpty(e.Text)))
            {
                if (IsDeleted(database, entry)) continue;
                if (database.Entries.Any(e =>
                    (!string.IsNullOrEmpty(e.Id) && string.Equals(e.Id, entry.Id, StringComparison.Ordinal)) ||
                    string.Equals(e.Text, entry.Text, StringComparison.Ordinal)))
                {
                    continue;
                }

                database.Entries.Add(Clone(entry));
            }

            NormalizeManualOrderLocked();
        }

        private void AddDeletedEntryLocked(string id, string text)
        {
            if (string.IsNullOrWhiteSpace(id)) return;
            if (database.DeletedEntries == null) database.DeletedEntries = new List<DeletedClipEntry>();
            var textHash = ComputeTextHash(text);
            var existing = database.DeletedEntries.FirstOrDefault(d => string.Equals(d.Id, id, StringComparison.Ordinal));
            if (existing == null)
            {
                database.DeletedEntries.Add(new DeletedClipEntry
                {
                    Id = id,
                    TextHash = textHash,
                    DeletedUnixMs = TimeUtil.NowUnixMs(),
                    SourceMachine = CurrentMachineName()
                });
            }
            else
            {
                existing.TextHash = textHash;
                existing.DeletedUnixMs = TimeUtil.NowUnixMs();
                existing.SourceMachine = CurrentMachineName();
            }
            NormalizeDeletedEntriesLocked();
        }

        private void NormalizeDeletedEntriesLocked()
        {
            NormalizeDeletedEntries(database);
        }

        private static void NormalizeDeletedEntries(ClipDatabase target)
        {
            if (target == null) return;
            if (target.DeletedEntries == null)
            {
                target.DeletedEntries = new List<DeletedClipEntry>();
                return;
            }

            var cutoff = TimeUtil.NowUnixMs() - (long)TimeSpan.FromDays(90).TotalMilliseconds;
            target.DeletedEntries = target.DeletedEntries
                .Where(d => d != null && !string.IsNullOrWhiteSpace(d.Id) && (d.DeletedUnixMs == 0 || d.DeletedUnixMs >= cutoff))
                .Select(d =>
                {
                    d.TextHash = d.TextHash ?? string.Empty;
                    return d;
                })
                .GroupBy(d => d.Id, StringComparer.Ordinal)
                .Select(g => g.OrderByDescending(d => d.DeletedUnixMs).First())
                .ToList();
        }

        private void ApplyDeletedEntriesLocked()
        {
            ApplyDeletedEntries(database);
        }

        private static void ApplyDeletedEntries(ClipDatabase target)
        {
            if (target == null || target.Entries == null || target.DeletedEntries == null || target.DeletedEntries.Count == 0) return;
            var deletedIds = new HashSet<string>(target.DeletedEntries.Select(d => d.Id).Where(id => !string.IsNullOrWhiteSpace(id)), StringComparer.Ordinal);
            var deletedHashes = new HashSet<string>(target.DeletedEntries.Select(d => d.TextHash).Where(hash => !string.IsNullOrWhiteSpace(hash)), StringComparer.Ordinal);
            if (deletedIds.Count == 0 && deletedHashes.Count == 0) return;
            target.Entries.RemoveAll(e =>
                e != null &&
                (deletedIds.Contains(e.Id) || deletedHashes.Contains(ComputeTextHash(e.Text))));
        }

        private static bool IsDeleted(ClipDatabase target, string id)
        {
            return target != null &&
                   !string.IsNullOrWhiteSpace(id) &&
                   target.DeletedEntries != null &&
                   target.DeletedEntries.Any(d => string.Equals(d.Id, id, StringComparison.Ordinal));
        }

        private static bool IsDeleted(ClipDatabase target, ClipEntry entry)
        {
            if (entry == null) return false;
            if (IsDeleted(target, entry.Id)) return true;
            if (target == null || target.DeletedEntries == null || string.IsNullOrEmpty(entry.Text)) return false;
            var textHash = ComputeTextHash(entry.Text);
            return target.DeletedEntries.Any(d => !string.IsNullOrWhiteSpace(d.TextHash) && string.Equals(d.TextHash, textHash, StringComparison.Ordinal));
        }

        private static bool MergeDeletedEntries(ClipDatabase target, ClipDatabase source)
        {
            if (target == null || source == null) return false;
            NormalizeDeletedEntries(target);
            NormalizeDeletedEntries(source);
            if (source.DeletedEntries == null || source.DeletedEntries.Count == 0) return false;

            var changed = false;
            foreach (var sourceDeleted in source.DeletedEntries)
            {
                if (sourceDeleted == null || string.IsNullOrWhiteSpace(sourceDeleted.Id)) continue;
                var targetDeleted = target.DeletedEntries.FirstOrDefault(d => string.Equals(d.Id, sourceDeleted.Id, StringComparison.Ordinal));
                if (targetDeleted == null)
                {
                    target.DeletedEntries.Add(new DeletedClipEntry
                    {
                        Id = sourceDeleted.Id,
                        TextHash = sourceDeleted.TextHash ?? string.Empty,
                        DeletedUnixMs = sourceDeleted.DeletedUnixMs,
                        SourceMachine = sourceDeleted.SourceMachine ?? string.Empty
                    });
                    changed = true;
                }
                else if (sourceDeleted.DeletedUnixMs > targetDeleted.DeletedUnixMs)
                {
                    targetDeleted.DeletedUnixMs = sourceDeleted.DeletedUnixMs;
                    targetDeleted.SourceMachine = sourceDeleted.SourceMachine ?? string.Empty;
                    targetDeleted.TextHash = sourceDeleted.TextHash ?? targetDeleted.TextHash ?? string.Empty;
                    changed = true;
                }
                else if (string.IsNullOrWhiteSpace(targetDeleted.TextHash) && !string.IsNullOrWhiteSpace(sourceDeleted.TextHash))
                {
                    targetDeleted.TextHash = sourceDeleted.TextHash;
                    changed = true;
                }
            }
            NormalizeDeletedEntries(target);
            return changed;
        }

        private static string ComputeTextHash(string text)
        {
            if (string.IsNullOrEmpty(text)) return string.Empty;
            using (var sha = SHA256.Create())
            {
                return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(text))).Replace("-", string.Empty).ToLowerInvariant();
            }
        }

        private static bool IsStorageAccessException(Exception ex)
        {
            return ex is IOException ||
                   ex is UnauthorizedAccessException ||
                   ex is DirectoryNotFoundException ||
                   ex is PathTooLongException ||
                   ex is NotSupportedException ||
                   ex is System.Security.SecurityException;
        }

        private static string CurrentMachineName()
        {
            return (Environment.MachineName ?? string.Empty).Trim();
        }

        private void OnChanged()
        {
            OnChanged(false);
        }

        private void OnChanged(bool external)
        {
            lock (sync)
            {
                lastChangeWasExternal = external;
            }
            var handler = Changed;
            if (handler != null)
            {
                handler(this, EventArgs.Empty);
            }
        }

        public void Dispose()
        {
            if (watcher != null) watcher.Dispose();
            if (reloadTimer != null) reloadTimer.Dispose();
            if (serverPollTimer != null) serverPollTimer.Dispose();
        }

        private static bool IsRecoverableServerException(Exception ex)
        {
            return ex is WebException ||
                   ex is IOException ||
                   ex is UnauthorizedAccessException ||
                   ex is DatabasePasswordRequiredException ||
                   ex is InvalidOperationException;
        }
    }
}
