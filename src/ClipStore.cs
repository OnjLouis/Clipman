using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;

namespace Clipman
{
    internal sealed class ClipStore : IDisposable
    {
        private readonly object sync = new object();
        private FileSystemWatcher watcher;
        private Timer reloadTimer;
        private ClipDatabase database = new ClipDatabase();
        private Func<string> passwordProvider;

        public event EventHandler Changed;

        public string DatabasePath { get; private set; }

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

        public void ChangeDatabasePassword()
        {
            lock (sync)
            {
                SaveLocked();
            }
        }

        public List<ClipEntry> GetEntries()
        {
            return GetEntries("LastUsed");
        }

        public List<ClipEntry> GetEntries(string sortMode)
        {
            return GetEntries(sortMode, "All");
        }

        public List<ClipEntry> GetEntries(string sortMode, string groupFilter)
        {
            lock (sync)
            {
                var filtered = FilterByGroup(database.Entries, groupFilter).ToList();
                var pinned = filtered
                    .Where(e => e.Pinned)
                    .OrderBy(e => e.ManualOrder)
                    .ThenByDescending(e => e.CreatedUnixMs);
                var normal = SortNormalEntries(filtered.Where(e => !e.Pinned), sortMode);

                return pinned.Concat(normal).Select(Clone).ToList();
            }
        }

        private static IEnumerable<ClipEntry> SortNormalEntries(IEnumerable<ClipEntry> entries, string sortMode)
        {
            switch ((sortMode ?? string.Empty).Trim().ToUpperInvariant())
            {
                case "ADDED":
                    return entries.OrderByDescending(e => e.CreatedUnixMs);
                case "TEXT":
                    return entries.OrderBy(e => e.Text ?? string.Empty, StringComparer.CurrentCultureIgnoreCase);
                case "GROUP":
                    return entries
                        .OrderBy(e => string.IsNullOrWhiteSpace(e.Group) ? "\uffff" : e.Group.Trim(), StringComparer.CurrentCultureIgnoreCase)
                        .ThenBy(e => e.Text ?? string.Empty, StringComparer.CurrentCultureIgnoreCase);
                case "MACHINE":
                    return entries
                        .OrderBy(e => string.IsNullOrWhiteSpace(e.SourceMachine) ? "\uffff" : e.SourceMachine.Trim(), StringComparer.CurrentCultureIgnoreCase)
                        .ThenBy(e => e.Text ?? string.Empty, StringComparer.CurrentCultureIgnoreCase);
                case "MANUAL":
                    return entries.OrderBy(e => e.ManualOrder);
                default:
                    return entries.OrderByDescending(e => e.LastUsedUnixMs);
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
                var removed = database.Entries.RemoveAll(e => idSet.Contains(e.Id));
                if (removed == 0) return 0;
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
            lock (sync)
            {
                database.UpdatedUnixMs = TimeUtil.NowUnixMs();
                ClipDatabaseFile.SaveAtomic(path, database, CurrentPassword());
            }
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
            SyncConflictResolver.ResolveDatabaseConflicts(DatabasePath, password);
            database = ClipDatabaseFile.Load(DatabasePath, password);
            if (database.Entries == null) database.Entries = new List<ClipEntry>();
            NormalizeManualOrderLocked();
        }

        private void SaveLocked()
        {
            database.UpdatedUnixMs = TimeUtil.NowUnixMs();
            ClipDatabaseFile.SaveAtomic(DatabasePath, database, CurrentPassword());
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

            var dir = Path.GetDirectoryName(DatabasePath);
            var file = Path.GetFileName(DatabasePath);
            if (string.IsNullOrEmpty(dir) || string.IsNullOrEmpty(file))
            {
                watcher = null;
                reloadTimer = null;
                return;
            }

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

            OnChanged();
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

        private static string CurrentMachineName()
        {
            return (Environment.MachineName ?? string.Empty).Trim();
        }

        private void OnChanged()
        {
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
        }
    }
}
