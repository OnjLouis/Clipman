using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;

namespace Clipman
{
    internal sealed class FileClipboardEventStore : IDisposable
    {
        private const int MaxEvents = 200;
        private readonly object sync = new object();
        private readonly Func<string> passwordProvider;
        private FileClipboardDatabase database = new FileClipboardDatabase();
        private FileSystemWatcher watcher;
        private Timer reloadTimer;

        public event EventHandler Changed;

        public string DatabasePath { get; private set; }
        public string LastStorageError { get; private set; }

        public FileClipboardEventStore(string databasePath, Func<string> passwordProvider)
        {
            if (string.IsNullOrWhiteSpace(databasePath))
            {
                throw new ArgumentException("File history database path cannot be blank.", "databasePath");
            }

            DatabasePath = databasePath;
            this.passwordProvider = passwordProvider ?? (() => string.Empty);
            lock (sync)
            {
                LoadLocked();
                ResetWatcherLocked();
            }
        }

        public List<ClipboardEventSummary> GetEvents()
        {
            return GetEvents("Manual", false);
        }

        public void Reload()
        {
            lock (sync)
            {
                LoadLocked();
                ResetWatcherLocked();
            }

            OnChanged();
        }

        public List<ClipboardEventSummary> GetEvents(string sortMode, bool descending)
        {
            lock (sync)
            {
                var pinned = database.Events
                    .Where(e => e.Pinned)
                    .OrderBy(e => e.ManualOrder)
                    .ThenByDescending(e => e.CapturedAt);
                var normal = SortNormalEvents(database.Events.Where(e => !e.Pinned), sortMode, descending);

                return pinned.Concat(normal)
                    .Select(Clone)
                    .ToList();
            }
        }

        private static IEnumerable<ClipboardEventSummary> SortNormalEvents(IEnumerable<ClipboardEventSummary> events, string sortMode, bool descending)
        {
            switch ((sortMode ?? string.Empty).Trim().ToUpperInvariant())
            {
                case "TIME":
                    return descending
                        ? events.OrderByDescending(e => e.CapturedAt)
                        : events.OrderBy(e => e.CapturedAt);
                case "FILES":
                    return descending
                        ? events.OrderByDescending(e => e.FileCount).ThenBy(PrimaryName, StringComparer.CurrentCultureIgnoreCase)
                        : events.OrderBy(e => e.FileCount).ThenBy(PrimaryName, StringComparer.CurrentCultureIgnoreCase);
                case "NAME":
                    return descending
                        ? events.OrderByDescending(PrimaryName, StringComparer.CurrentCultureIgnoreCase).ThenByDescending(e => e.CapturedAt)
                        : events.OrderBy(PrimaryName, StringComparer.CurrentCultureIgnoreCase).ThenByDescending(e => e.CapturedAt);
                case "OPERATION":
                    return descending
                        ? events.OrderByDescending(e => e.Operation ?? string.Empty, StringComparer.CurrentCultureIgnoreCase).ThenBy(PrimaryName, StringComparer.CurrentCultureIgnoreCase)
                        : events.OrderBy(e => e.Operation ?? string.Empty, StringComparer.CurrentCultureIgnoreCase).ThenBy(PrimaryName, StringComparer.CurrentCultureIgnoreCase);
                case "SOURCE":
                    return descending
                        ? events.OrderByDescending(e => e.Source ?? string.Empty, StringComparer.CurrentCultureIgnoreCase).ThenBy(PrimaryName, StringComparer.CurrentCultureIgnoreCase)
                        : events.OrderBy(e => e.Source ?? string.Empty, StringComparer.CurrentCultureIgnoreCase).ThenBy(PrimaryName, StringComparer.CurrentCultureIgnoreCase);
                case "MANUAL":
                default:
                    return descending
                        ? events.OrderByDescending(e => e.ManualOrder).ThenByDescending(e => e.CapturedAt)
                        : events.OrderBy(e => e.ManualOrder).ThenByDescending(e => e.CapturedAt);
            }
        }

        public void Add(ClipboardEventSummary summary)
        {
            if (summary == null) return;
            Normalize(summary);

            lock (sync)
            {
                var existingIndex = database.Events.FindIndex(item => SameFileClipboardEvent(item, summary));
                if (existingIndex >= 0)
                {
                    summary.Pinned = database.Events[existingIndex].Pinned;
                    summary.ManualOrder = database.Events[existingIndex].ManualOrder;
                    database.Events.RemoveAt(existingIndex);
                }

                if (summary.ManualOrder <= 0)
                {
                    summary.ManualOrder = NextManualOrderLocked();
                }
                if (!summary.Pinned)
                {
                    MoveToTopOfBandLocked(summary);
                }
                database.Events.Insert(0, Clone(summary));
                if (database.Events.Count > MaxEvents)
                {
                    TrimNormalEventsLocked();
                }

                SaveLocked();
            }

            OnChanged();
        }

        public int DeleteMany(IEnumerable<string> ids)
        {
            var idSet = new HashSet<string>((ids ?? Enumerable.Empty<string>()).Where(id => !string.IsNullOrEmpty(id)));
            if (idSet.Count == 0) return 0;

            lock (sync)
            {
                var removed = database.Events.RemoveAll(e => idSet.Contains(e.Id) && !e.Pinned);
                if (removed == 0) return 0;
                SaveLocked();
                OnChanged();
                return removed;
            }
        }

        public int Clear()
        {
            lock (sync)
            {
                var count = database.Events.Count(e => !e.Pinned);
                if (count == 0) return 0;
                database.Events.RemoveAll(e => !e.Pinned);
                SaveLocked();
                OnChanged();
                return count;
            }
        }

        public int RemoveUnavailableEvents()
        {
            lock (sync)
            {
                var removed = database.Events.RemoveAll(e => !e.Pinned && IsUnavailableEvent(e));
                if (removed == 0) return 0;
                SaveLocked();
                OnChanged();
                return removed;
            }
        }

        public bool TogglePinned(string id)
        {
            if (string.IsNullOrWhiteSpace(id)) return false;
            lock (sync)
            {
                var item = database.Events.FirstOrDefault(e => string.Equals(e.Id, id, StringComparison.Ordinal));
                if (item == null) return false;
                item.Pinned = !item.Pinned;
                if (item.ManualOrder <= 0) item.ManualOrder = NextManualOrderLocked();
                SaveLocked();
                OnChanged();
                return item.Pinned;
            }
        }

        public void MoveEvents(IEnumerable<string> ids, int direction)
        {
            var selectedIds = (ids ?? Enumerable.Empty<string>())
                .Where(id => !string.IsNullOrWhiteSpace(id))
                .ToList();
            if (selectedIds.Count == 0 || direction == 0) return;

            lock (sync)
            {
                NormalizeDatabase();
                var idSet = new HashSet<string>(selectedIds);
                var firstEvent = database.Events.FirstOrDefault(e => idSet.Contains(e.Id));
                if (firstEvent == null) return;
                var pinned = firstEvent.Pinned;
                var section = database.Events
                    .Where(e => e.Pinned == pinned)
                    .OrderBy(e => e.ManualOrder)
                    .ThenByDescending(e => e.CapturedAt)
                    .ToList();
                var indexes = section
                    .Select((entry, index) => new { entry, index })
                    .Where(x => idSet.Contains(x.entry.Id))
                    .Select(x => x.index)
                    .OrderBy(i => i)
                    .ToList();
                if (indexes.Count == 0) return;
                if (direction < 0)
                {
                    if (indexes.First() == 0) return;
                }
                else
                {
                    if (indexes.Last() >= section.Count - 1) return;
                }

                var selected = section.Where(e => idSet.Contains(e.Id)).ToList();
                var firstIndex = indexes.First();
                var lastIndex = indexes.Last();
                foreach (var item in selected)
                {
                    section.Remove(item);
                }

                if (direction < 0)
                {
                    section.InsertRange(Math.Max(0, firstIndex - 1), selected);
                }
                else
                {
                    section.InsertRange(Math.Min(section.Count, lastIndex + 1 - selected.Count + 1), selected);
                }

                for (var i = 0; i < section.Count; i++)
                {
                    section[i].ManualOrder = i + 1;
                }
                SaveLocked();
                OnChanged();
            }
        }

        private static bool IsUnavailableEvent(ClipboardEventSummary item)
        {
            if (item == null) return false;
            if (item.Files == null || item.Files.Count == 0) return true;
            return item.Files.All(path => string.IsNullOrWhiteSpace(path) || (!File.Exists(path) && !Directory.Exists(path)));
        }

        public void ChangeDatabasePassword()
        {
            lock (sync)
            {
                SaveLocked();
            }
        }

        private void LoadLocked()
        {
            try
            {
                database = ClipDatabaseFile.Load<FileClipboardDatabase>(DatabasePath, CurrentPassword());
                NormalizeDatabase();
                LastStorageError = string.Empty;
            }
            catch (Exception ex)
            {
                if (!IsStorageAccessException(ex)) throw;
                database = new FileClipboardDatabase();
                LastStorageError = ex.Message;
            }
        }

        private void SaveLocked()
        {
            database.UpdatedUnixMs = TimeUtil.NowUnixMs();
            try
            {
                ClipDatabaseFile.SaveAtomic(DatabasePath, database, CurrentPassword());
                LastStorageError = string.Empty;
                if (watcher == null)
                {
                    ResetWatcherLocked();
                }
            }
            catch (Exception ex)
            {
                if (!IsStorageAccessException(ex)) throw;
                LastStorageError = ex.Message;
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
            if (string.IsNullOrEmpty(dir) || string.IsNullOrEmpty(file)) return;

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
                LastStorageError = ex.Message;
                if (watcher != null) watcher.Dispose();
                if (reloadTimer != null) reloadTimer.Dispose();
                watcher = null;
                reloadTimer = null;
            }
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

        private void NormalizeDatabase()
        {
            if (database == null) database = new FileClipboardDatabase();
            if (database.Events == null) database.Events = new List<ClipboardEventSummary>();
            database.Version = Math.Max(1, database.Version);
            foreach (var item in database.Events)
            {
                Normalize(item);
            }
            database.Events = database.Events
                .Where(e => e != null)
                .OrderBy(e => e.Pinned ? 0 : 1)
                .ThenBy(e => e.ManualOrder)
                .ThenByDescending(e => e.CapturedAt)
                .ToList();
            foreach (var item in database.Events.Where(e => e.ManualOrder <= 0))
            {
                item.ManualOrder = NextManualOrderLocked();
            }
            TrimNormalEventsLocked();
        }

        private static void Normalize(ClipboardEventSummary item)
        {
            if (item == null) return;
            if (string.IsNullOrWhiteSpace(item.Id)) item.Id = Guid.NewGuid().ToString("N");
            if (item.CapturedAt == default(DateTime)) item.CapturedAt = DateTime.Now;
            if (item.Source == null) item.Source = string.Empty;
            if (item.Operation == null) item.Operation = string.Empty;
            if (item.SourceMachine == null) item.SourceMachine = string.Empty;
            if (item.Files == null) item.Files = new List<string>();
            if (item.Formats == null) item.Formats = new List<string>();
            if (item.FileCount <= 0 && item.Files.Count > 0) item.FileCount = item.Files.Count;
        }

        private long NextManualOrderLocked()
        {
            return database.Events.Count == 0 ? 1 : database.Events.Max(e => e.ManualOrder) + 1;
        }

        private static string PrimaryName(ClipboardEventSummary item)
        {
            if (item == null) return string.Empty;
            if (item.Files != null && item.Files.Count > 0 && !string.IsNullOrWhiteSpace(item.Files[0]))
            {
                var name = Path.GetFileName(item.Files[0]);
                return string.IsNullOrWhiteSpace(name) ? item.Files[0] : name;
            }

            if (!string.IsNullOrWhiteSpace(item.Operation)) return item.Operation;
            if (item.Formats != null && item.Formats.Count > 0) return item.Formats[0] ?? string.Empty;
            return "Clipboard event";
        }

        private void MoveToTopOfBandLocked(ClipboardEventSummary item)
        {
            if (item == null) return;
            foreach (var existing in database.Events.Where(e => e.Pinned == item.Pinned && e.ManualOrder > 0))
            {
                existing.ManualOrder++;
            }
            item.ManualOrder = 1;
        }

        private void TrimNormalEventsLocked()
        {
            if (database.Events.Count <= MaxEvents) return;
            var normal = database.Events
                .Where(e => !e.Pinned)
                .OrderBy(e => e.ManualOrder)
                .ThenByDescending(e => e.CapturedAt)
                .ToList();
            var removable = database.Events.Count - MaxEvents;
            foreach (var item in normal.AsEnumerable().Reverse().Take(removable).ToList())
            {
                database.Events.Remove(item);
            }
        }

        private static bool SameFileClipboardEvent(ClipboardEventSummary left, ClipboardEventSummary right)
        {
            if (left == null || right == null) return false;
            if (left.Files == null || right.Files == null) return false;
            if (left.Files.Count != right.Files.Count) return false;
            if (left.Files.Count == 0) return false;

            var leftFiles = left.Files
                .Where(path => !string.IsNullOrWhiteSpace(path))
                .Select(path => path.Trim())
                .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
                .ToList();
            var rightFiles = right.Files
                .Where(path => !string.IsNullOrWhiteSpace(path))
                .Select(path => path.Trim())
                .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
                .ToList();

            return leftFiles.SequenceEqual(rightFiles, StringComparer.OrdinalIgnoreCase);
        }

        private static ClipboardEventSummary Clone(ClipboardEventSummary source)
        {
            if (source == null) return null;
            Normalize(source);
            return new ClipboardEventSummary
            {
                Id = source.Id,
                CapturedAt = source.CapturedAt,
                Source = source.Source ?? string.Empty,
                Operation = source.Operation ?? string.Empty,
                SourceMachine = source.SourceMachine ?? string.Empty,
                ContainsText = source.ContainsText,
                FileCount = source.FileCount,
                Files = source.Files == null ? new List<string>() : source.Files.ToList(),
                Formats = source.Formats == null ? new List<string>() : source.Formats.ToList(),
                Pinned = source.Pinned,
                ManualOrder = source.ManualOrder
            };
        }

        private string CurrentPassword()
        {
            return passwordProvider == null ? string.Empty : (passwordProvider() ?? string.Empty);
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
