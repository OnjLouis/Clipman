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
            lock (sync)
            {
                return database.Events
                    .OrderByDescending(e => e.CapturedAt)
                    .Select(Clone)
                    .ToList();
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
                    database.Events.RemoveAt(existingIndex);
                }

                database.Events.Insert(0, Clone(summary));
                if (database.Events.Count > MaxEvents)
                {
                    database.Events.RemoveRange(MaxEvents, database.Events.Count - MaxEvents);
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
                var removed = database.Events.RemoveAll(e => idSet.Contains(e.Id));
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
                var count = database.Events.Count;
                if (count == 0) return 0;
                database.Events.Clear();
                SaveLocked();
                OnChanged();
                return count;
            }
        }

        public int RemoveUnavailableEvents()
        {
            lock (sync)
            {
                var removed = database.Events.RemoveAll(IsUnavailableEvent);
                if (removed == 0) return 0;
                SaveLocked();
                OnChanged();
                return removed;
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
                .OrderByDescending(e => e.CapturedAt)
                .Take(MaxEvents)
                .ToList();
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
                Formats = source.Formats == null ? new List<string>() : source.Formats.ToList()
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
