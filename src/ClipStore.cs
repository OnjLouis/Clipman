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
        private int serverPollGeneration;
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
        private string machineName;

        // Sync channels (sync-rules-spec.md sections 3-6). Every field below is inert while
        // RulesActiveLocked() is false, which is the state of a client without the feature.
        private const string SyncRulesFileName = "clipman-sync-rules.clipdb";
        private const string ChannelFilePrefix = "clipman-channel-";
        private const string PendingWritesFileName = "pending-writes.json";
        private const long ChannelAnnouncementLifetimeMs = 10000;
        private const long SyncRulesAbsentRecheckMs = 60000;

        private readonly List<ChannelSlot> channelSlots = new List<ChannelSlot>();
        private Dictionary<string, string> residence = new Dictionary<string, string>(StringComparer.Ordinal);
        private Dictionary<string, DeletedClipEntry> assembledMarkers = new Dictionary<string, DeletedClipEntry>(StringComparer.Ordinal);
        private List<string> channelWriteOrder = new List<string>();
        private SyncRulesDocument syncRules;
        private string syncRulesRevision = string.Empty;
        private ServerStorageClient syncRulesClient;
        private string serverUrl = string.Empty;
        private string serverToken = string.Empty;
        private string serverCaCertPem = string.Empty;
        private string serverCaHost = string.Empty;
        private long syncRulesNextCheckUnixMs;
        private bool selfRegistrationAttempted;
        private bool channelsAdoptedRemoteState;
        private bool viewChangedNotificationPending;
        private string channelAnnouncement = string.Empty;
        private long channelAnnouncementUnixMs;

        /// <summary>
        /// One sync channel as it stood at the last transfer. <see cref="Key"/> is the empty string
        /// for the core channel, which keeps using the existing database file and bucket.
        /// <see cref="PlainHash"/> is the dirty-detection hash of the plaintext with the
        /// database-level UpdatedUnixMs zeroed (spec section 5, upload step 4).
        /// </summary>
        private sealed class ChannelSlot
        {
            public string Key;
            public string Revision;
            public string PlainHash;
            public ClipDatabase Database;
            public ServerStorageClient Client;
            public string CacheFilePath;
            public bool Exists;
            public bool NeedsUpload;

            public ChannelSlot()
            {
                Key = string.Empty;
                Revision = string.Empty;
                PlainHash = string.Empty;
                CacheFilePath = string.Empty;
                Database = new ClipDatabase();
            }
        }

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

        public ClipStore(string databasePath, string password) : this(databasePath, password, Environment.MachineName)
        {
        }

        public ClipStore(string databasePath, string password, string machineName)
        {
            this.machineName = NormalizeMachineName(machineName);
            passwordProvider = () => password ?? string.Empty;
            SetDatabasePath(databasePath);
        }

        public ClipStore(string databasePath, Func<string> passwordProvider) : this(databasePath, passwordProvider, Environment.MachineName)
        {
        }

        public ClipStore(string databasePath, Func<string> passwordProvider, string machineName)
        {
            this.machineName = NormalizeMachineName(machineName);
            this.passwordProvider = passwordProvider ?? (() => string.Empty);
            SetDatabasePath(databasePath);
        }

        public void SetMachineName(string value)
        {
            lock (sync)
            {
                machineName = NormalizeMachineName(value);
            }
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

        public void ConfigureServerStorage(
            bool enabled,
            string serverUrl,
            string serverToken,
            string serverCaCertPem,
            string serverCaHost)
        {
            var queueInitialSync = false;
            lock (sync)
            {
                serverPollGeneration++;
                if (serverPollTimer != null)
                {
                    serverPollTimer.Dispose();
                    serverPollTimer = null;
                }

                this.serverUrl = serverUrl ?? string.Empty;
                this.serverToken = ServerSettingsSanitizer.CleanToken(serverToken);
                this.serverCaCertPem = serverCaCertPem ?? string.Empty;
                this.serverCaHost = serverCaHost ?? string.Empty;
                serverClient = enabled
                    ? new ServerStorageClient(
                        serverUrl,
                        serverToken,
                        CurrentPassword(),
                        serverCaCertPem,
                        serverCaHost)
                    : null;
                serverRevision = string.Empty;
                syncRulesClient = null;
                syncRulesRevision = string.Empty;
                syncRulesNextCheckUnixMs = 0;
                selfRegistrationAttempted = false;
                ConfigureChannelClientsLocked();
                ResetServerStatusLocked();
                if (serverClient == null || !serverClient.IsConfigured)
                {
                    return;
                }

                var pollGeneration = serverPollGeneration;
                serverPollTimer = new Timer(
                    delegate { PollServer(pollGeneration); },
                    null,
                    CalculateServerPollDelayMilliseconds(TimeUtil.NowUnixMs(), serverNextPollUnixMs),
                    Timeout.Infinite);
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
                    ServerSyncLocked(false, false);
                }
                ResetWatcherLocked();
            }

            OnChanged();
        }

        public void RecordServerRetryFailure(Exception error)
        {
            lock (sync)
            {
                storageUnavailable = true;
                LastStorageError = "Server retry failed: " + (error == null ? "Unknown error." : error.Message);
                MarkServerFailureLocked();
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

        public ClipEntry AddText(string text, string duplicateMode, int maxEntries, int maxDays, string group, RichTextPayload richText = null)
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
                    var normalizedRichText = RichTextData.Normalize(richText);
                    if (normalizedRichText != null)
                    {
                        existing.RichText = normalizedRichText;
                        existing.RichTextUpdatedUnixMs = existing.LastUsedUnixMs;
                    }
                    PruneLocked(maxEntries, maxDays);
                    SaveLocked();
                    OnChanged();
                    return Clone(existing);
                }

                var now = TimeUtil.NowUnixMs();
                var newEntryRichText = RichTextData.Normalize(richText);
                var entry = new ClipEntry
                {
                    Id = Guid.NewGuid().ToString("N"),
                    Text = text,
                    Group = (group ?? string.Empty).Trim(),
                    SourceMachine = CurrentMachineName(),
                    CreatedUnixMs = now,
                    LastUsedUnixMs = now,
                    ModifiedUnixMs = now,
                    ManualOrder = NextManualOrderLocked(),
                    RichText = newEntryRichText,
                    RichTextUpdatedUnixMs = newEntryRichText == null ? 0 : now
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
                        ModifiedUnixMs = stamp,
                        Pinned = false,
                        IsTemplate = entry.IsTemplate,
                        ManualOrder = NextManualOrderLocked(),
                        RichText = RichTextData.Clone(entry.RichText),
                        RichTextUpdatedUnixMs = entry.RichTextUpdatedUnixMs
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
                        ModifiedUnixMs = entry.ModifiedUnixMs,
                        Pinned = entry.Pinned,
                        IsTemplate = entry.IsTemplate,
                        ManualOrder = entry.ManualOrder,
                        RichText = RichTextData.Clone(entry.RichText),
                        RichTextUpdatedUnixMs = entry.RichTextUpdatedUnixMs
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
                entry.ModifiedUnixMs = TimeUtil.NowUnixMs();
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
                entry.ModifiedUnixMs = TimeUtil.NowUnixMs();
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
                entry.ModifiedUnixMs = TimeUtil.NowUnixMs();
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
                var now = TimeUtil.NowUnixMs();
                entry.Name = (name ?? string.Empty).Trim();
                var nextText = text ?? string.Empty;
                if (!string.Equals(entry.Text ?? string.Empty, nextText, StringComparison.Ordinal))
                {
                    entry.RichText = null;
                    entry.RichTextUpdatedUnixMs = now;
                }
                entry.Text = nextText;
                entry.LastUsedUnixMs = now;
                entry.ModifiedUnixMs = now;
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
                entry.ModifiedUnixMs = TimeUtil.NowUnixMs();
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
                var requestedGroup = (groupName ?? string.Empty).Trim();
                var canonicalGroup = CanonicalLabels(database.Entries, e => e.Group)
                    .FirstOrDefault(group => string.Equals(group, requestedGroup, StringComparison.CurrentCultureIgnoreCase))
                    ?? requestedGroup;
                var now = TimeUtil.NowUnixMs();
                foreach (var entry in database.Entries.Where(e => idSet.Contains(e.Id)))
                {
                    entry.Group = canonicalGroup;
                    entry.ModifiedUnixMs = now;
                }
                SaveLocked();
                OnChanged();
            }
        }

        public List<string> GetGroups()
        {
            lock (sync)
            {
                return CanonicalLabels(database.Entries, e => e.Group);
            }
        }

        private string CanonicalGroupLocked(string groupName)
        {
            var requested = (groupName ?? string.Empty).Trim();
            return CanonicalLabels(database.Entries, entry => entry.Group)
                .FirstOrDefault(group => string.Equals(group, requested, StringComparison.CurrentCultureIgnoreCase))
                ?? requested;
        }

        public ClipEntry AddManualEntry(string text, string name, string group, bool pinned, bool isTemplate, string duplicateMode, int maxEntries, int maxDays)
        {
            if (string.IsNullOrWhiteSpace(text)) return null;
            text = text.Trim();
            lock (sync)
            {
                var now = TimeUtil.NowUnixMs();
                var existing = database.Entries.FirstOrDefault(e => e.Text == text);
                var mode = (duplicateMode ?? "MoveToTop").Trim();
                if (existing != null && mode.Equals("Ignore", StringComparison.OrdinalIgnoreCase))
                {
                    return Clone(existing);
                }

                ClipEntry entry;
                if (existing != null && mode.Equals("MoveToTop", StringComparison.OrdinalIgnoreCase))
                {
                    entry = existing;
                    entry.Name = (name ?? string.Empty).Trim();
                    entry.Group = CanonicalGroupLocked(group);
                    entry.Pinned = pinned;
                    entry.IsTemplate = isTemplate;
                    entry.SourceMachine = CurrentMachineName();
                    entry.LastUsedUnixMs = now;
                    entry.ModifiedUnixMs = now;
                }
                else
                {
                    entry = new ClipEntry
                    {
                        Id = Guid.NewGuid().ToString("N"),
                        Text = text,
                        Name = (name ?? string.Empty).Trim(),
                        Group = CanonicalGroupLocked(group),
                        Pinned = pinned,
                        IsTemplate = isTemplate,
                        SourceMachine = CurrentMachineName(),
                        CreatedUnixMs = now,
                        LastUsedUnixMs = now,
                        ModifiedUnixMs = now,
                        ManualOrder = NextManualOrderLocked()
                    };
                    database.Entries.Add(entry);
                }
                PruneLocked(maxEntries, maxDays);
                SaveLocked();
                OnChanged();
                return Clone(entry);
            }
        }

        public ClipEntry MergeCapturedText(string baseId, string firstTapId, string mergedText, int maxEntries, int maxDays, string group)
        {
            if (string.IsNullOrEmpty(mergedText)) return null;
            lock (sync)
            {
                var baseEntry = database.Entries.FirstOrDefault(item => string.Equals(item.Id, baseId, StringComparison.OrdinalIgnoreCase));
                var firstTapEntry = database.Entries.FirstOrDefault(item => string.Equals(item.Id, firstTapId, StringComparison.OrdinalIgnoreCase));
                var target = baseEntry != null && !baseEntry.Pinned
                    ? baseEntry
                    : firstTapEntry != null && !firstTapEntry.Pinned
                        ? firstTapEntry
                        : null;
                var now = TimeUtil.NowUnixMs();

                if (target == null)
                {
                    target = new ClipEntry
                    {
                        Id = Guid.NewGuid().ToString("N"),
                        Text = mergedText,
                        Group = (group ?? string.Empty).Trim(),
                        SourceMachine = CurrentMachineName(),
                        CreatedUnixMs = now,
                        LastUsedUnixMs = now,
                        ModifiedUnixMs = now,
                        ManualOrder = NextManualOrderLocked()
                    };
                    database.Entries.Add(target);
                }
                else
                {
                    target.Text = mergedText;
                    target.SourceMachine = CurrentMachineName();
                    target.LastUsedUnixMs = now;
                    target.ModifiedUnixMs = now;
                    target.IsTemplate = false;
                    target.RichText = null;
                    target.RichTextUpdatedUnixMs = now;
                    if (string.IsNullOrWhiteSpace(target.Group) && !string.IsNullOrWhiteSpace(group))
                    {
                        target.Group = group.Trim();
                    }
                }

                if (firstTapEntry != null && !firstTapEntry.Pinned && !string.Equals(firstTapEntry.Id, target.Id, StringComparison.OrdinalIgnoreCase))
                {
                    AddDeletedEntryLocked(firstTapEntry.Id, firstTapEntry.Text);
                    database.Entries.Remove(firstTapEntry);
                }
                PruneLocked(maxEntries, maxDays);
                SaveLocked();
                OnChanged();
                return Clone(target);
            }
        }

        public bool TrySetNameIfUnchanged(string id, string expectedText, string name)
        {
            if (string.IsNullOrEmpty(id)) return false;
            lock (sync)
            {
                var entry = database.Entries.FirstOrDefault(e => e.Id == id);
                if (entry == null || !string.IsNullOrWhiteSpace(entry.Name) ||
                    !string.Equals(entry.Text ?? string.Empty, expectedText ?? string.Empty, StringComparison.Ordinal))
                {
                    return false;
                }
                entry.Name = (name ?? string.Empty).Trim();
                entry.ModifiedUnixMs = TimeUtil.NowUnixMs();
                SaveLocked();
                OnChanged();
                return true;
            }
        }

        public long EmbeddedImageByteCount()
        {
            lock (sync)
            {
                long total = 0;
                foreach (var entry in database.Entries)
                {
                    if (entry == null) continue;
                    total += RichImageData.StoredByteCount(entry.RichText);
                    if (total >= RichImageData.MaximumDatabaseImageBytes) return total;
                }
                return total;
            }
        }

        public void ReplaceText(string id, string text)
        {
            if (string.IsNullOrEmpty(id)) return;
            lock (sync)
            {
                var entry = database.Entries.FirstOrDefault(e => e.Id == id);
                if (entry == null) return;
                var nextText = text ?? string.Empty;
                entry.Text = nextText;
                entry.LastUsedUnixMs = TimeUtil.NowUnixMs();
                entry.ModifiedUnixMs = entry.LastUsedUnixMs;
                entry.RichText = null;
                entry.RichTextUpdatedUnixMs = entry.LastUsedUnixMs;
                SaveLocked();
                OnChanged();
            }
        }

        public void MoveEntries(IEnumerable<string> ids, int direction)
        {
            MoveEntries(ids, direction, null);
        }

        public void MoveEntries(IEnumerable<string> ids, int direction, IEnumerable<string> visibleIds)
        {
            var selectedIds = new HashSet<string>((ids ?? Enumerable.Empty<string>()).Where(id => !string.IsNullOrEmpty(id)));
            if (selectedIds.Count == 0 || direction == 0) return;
            var visibleOrder = (visibleIds ?? Enumerable.Empty<string>())
                .Where(id => !string.IsNullOrEmpty(id))
                .Distinct()
                .ToList();

            lock (sync)
            {
                NormalizeManualOrderLocked();
                var selectedEntries = database.Entries.Where(e => selectedIds.Contains(e.Id)).ToList();
                if (selectedEntries.Count == 0) return;
                if (selectedEntries.Any(e => e.Pinned != selectedEntries[0].Pinned)) return;

                var pinnedBand = selectedEntries[0].Pinned;
                var band = database.Entries
                    .Where(e => e.Pinned == pinnedBand)
                    .OrderBy(e => e.ManualOrder)
                    .ToList();
                var ordered = visibleOrder.Count == 0
                    ? band
                    : visibleOrder
                        .Select(id => band.FirstOrDefault(entry => entry.Id == id))
                        .Where(entry => entry != null)
                        .ToList();
                var selected = ordered.Where(e => selectedIds.Contains(e.Id)).ToList();
                if (selected.Count != selectedEntries.Count) return;
                var indexes = selected.Select(e => ordered.IndexOf(e)).OrderBy(i => i).ToList();
                var first = indexes.First();
                var last = indexes.Last();
                if ((direction < 0 && first == 0) || (direction > 0 && last == ordered.Count - 1)) return;
                var manualOrderSlots = ordered.Select(e => e.ManualOrder).OrderBy(value => value).ToList();
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

                var now = TimeUtil.NowUnixMs();
                for (var i = 0; i < ordered.Count; i++)
                {
                    var nextOrder = manualOrderSlots[i];
                    if (ordered[i].ManualOrder != nextOrder)
                    {
                        ordered[i].ManualOrder = nextOrder;
                        ordered[i].ModifiedUnixMs = now;
                    }
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
                var now = TimeUtil.NowUnixMs();
                foreach (var entry in database.Entries)
                {
                    long manualOrder;
                    if (order.TryGetValue(entry.Id, out manualOrder))
                    {
                        if (entry.ManualOrder != manualOrder)
                        {
                            entry.ManualOrder = manualOrder;
                            entry.ModifiedUnixMs = now;
                        }
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
                        ModifiedUnixMs = entry.ModifiedUnixMs == 0 ? now : entry.ModifiedUnixMs,
                        Pinned = entry.Pinned,
                        IsTemplate = entry.IsTemplate,
                        ManualOrder = order++,
                        RichText = RichTextData.Clone(entry.RichText),
                        RichTextUpdatedUnixMs = entry.RichTextUpdatedUnixMs
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
                        ModifiedUnixMs = entry.ModifiedUnixMs == 0 ? now : entry.ModifiedUnixMs,
                        Pinned = false,
                        IsTemplate = entry.IsTemplate,
                        ManualOrder = order++,
                        RichText = RichTextData.Clone(entry.RichText),
                        RichTextUpdatedUnixMs = entry.RichTextUpdatedUnixMs
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

        public List<ClipEntry> LoadEntriesFromFile(string path)
        {
            return LoadEntriesFromFile(path, string.Empty);
        }

        public List<ClipEntry> LoadEntriesFromFile(string path, string password)
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
                ResolveSyncRulesConflictsLocked(password);
                LoadSyncRulesFromDiskLocked(password);
                if (RulesActiveLocked())
                {
                    LoadChannelsFromDiskLocked(password);
                    storageUnavailable = false;
                    LastStorageError = string.Empty;
                    return;
                }

                ClearChannelStateLocked();
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
                ClearChannelStateLocked();
                storageUnavailable = true;
                LastStorageError = ex.Message;
            }
        }

        private void SaveLocked()
        {
            if (RulesActiveLocked())
            {
                SaveChannelsLocked(false);
                return;
            }

            SaveSingleDatabaseLocked();
        }

        private void SaveSingleDatabaseLocked()
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
                // Channel and rules files are siblings of the history file, so the watcher covers
                // every container in the folder and WatcherChanged filters by name. A rules file is
                // watched even while rules are inactive, or a device would never notice another
                // device enabling them in a shared folder.
                watcher = new FileSystemWatcher(dir, "*" + ClipDatabaseFile.CompressedExtension)
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

        internal static int CalculateServerPollDelayMilliseconds(long nowUnixMs, long nextPollUnixMs)
        {
            const int normalPollMilliseconds = 2000;
            if (nextPollUnixMs <= nowUnixMs + normalPollMilliseconds)
            {
                return normalPollMilliseconds;
            }

            return (int)Math.Min(int.MaxValue, nextPollUnixMs - nowUnixMs);
        }

        private void ScheduleNextServerPoll(int pollGeneration)
        {
            lock (sync)
            {
                if (pollGeneration != serverPollGeneration ||
                    serverPollTimer == null ||
                    serverClient == null ||
                    !serverClient.IsConfigured)
                {
                    return;
                }

                var delay = CalculateServerPollDelayMilliseconds(TimeUtil.NowUnixMs(), serverNextPollUnixMs);
                serverPollTimer.Change(delay, Timeout.Infinite);
            }
        }

        private void PollServer(int pollGeneration)
        {
            var changed = false;
            try
            {
                lock (sync)
                {
                    try
                    {
                        if (serverClient == null || !serverClient.IsConfigured || serverSyncInProgress) return;
                        var now = TimeUtil.NowUnixMs();
                        if (serverNextPollUnixMs > now) return;
                        serverLastPollUnixMs = now;
                        changed = ServerSyncLocked(false, true);
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

            }
            finally
            {
                // A channel pass that failed part way can still have changed the view, and every
                // failure branch above returns early, so the latch is consulted here rather than
                // relying on the value returned by the pass.
                if (changed || TakeViewChangedNotification())
                {
                    OnChanged(true);
                }
                ScheduleNextServerPoll(pollGeneration);
            }
        }

        private bool TakeViewChangedNotification()
        {
            lock (sync)
            {
                var pending = viewChangedNotificationPending;
                viewChangedNotificationPending = false;
                return pending;
            }
        }

        /// <summary>
        /// One server sync pass. The sync rules bucket is consulted first (spec section 5, download
        /// step 1) so that enabling the feature elsewhere is noticed; with rules inactive the rest
        /// is the unchanged single-bucket flow.
        /// </summary>
        private bool ServerSyncLocked(bool uploadLocalWhenMissing, bool headFirst)
        {
            if (serverClient == null || !serverClient.IsConfigured) return false;

            var changed = false;
            if (RefreshSyncRulesFromServerLocked())
            {
                ReconfigureChannelsLocked();
                changed = true;
            }

            if (!RulesActiveLocked())
            {
                if (headFirst)
                {
                    var metadata = serverClient.GetMetadata();
                    storageUnavailable = false;
                    LastStorageError = string.Empty;
                    MarkServerSuccessLocked(false);
                    if (string.IsNullOrWhiteSpace(metadata.Revision) ||
                        string.Equals(metadata.Revision, serverRevision, StringComparison.Ordinal))
                    {
                        return changed;
                    }
                }
                return SyncFromServerLocked(uploadLocalWhenMissing) || changed;
            }

            changed = SyncChannelsFromServerLocked(uploadLocalWhenMissing) || changed;
            SelfRegisterDeviceLocked();
            changed = RetryPendingWritesLocked(TimeUtil.NowUnixMs()) || changed;
            if (AnyChannelNeedsUploadLocked())
            {
                SaveChannelsLocked(false);
            }
            return changed;
        }

        private bool SyncFromServerLocked(bool uploadLocalWhenMissing)
        {
            if (serverClient == null || !serverClient.IsConfigured) return false;
            if (serverSyncInProgress) return false;
            if (RulesActiveLocked()) return SyncChannelsFromServerLocked(uploadLocalWhenMissing);

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
                        changed = ServerSyncLocked(true, false);
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
                serverRevision = string.Empty;
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
            var incomingModifiedWins = incoming.ModifiedUnixMs > existing.ModifiedUnixMs;
            var bothLegacy = incoming.ModifiedUnixMs <= 0 && existing.ModifiedUnixMs <= 0;
            var legacyTextRepair = bothLegacy &&
                !string.IsNullOrWhiteSpace(existing.Id) &&
                string.Equals(existing.Id, incoming.Id, StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(existing.Text ?? string.Empty, incoming.Text ?? string.Empty, StringComparison.Ordinal);

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
            if (incomingModifiedWins)
            {
                var textChanged = !string.Equals(existing.Text ?? string.Empty, incoming.Text ?? string.Empty, StringComparison.Ordinal);
                existing.Text = incoming.Text ?? string.Empty;
                existing.Name = (incoming.Name ?? string.Empty).Trim();
                existing.Group = (incoming.Group ?? string.Empty).Trim();
                existing.Pinned = incoming.Pinned;
                existing.IsTemplate = incoming.IsTemplate;
                existing.ManualOrder = incoming.ManualOrder;
                existing.ModifiedUnixMs = incoming.ModifiedUnixMs;
                if (textChanged)
                {
                    existing.RichText = RichTextData.Clone(incoming.RichText);
                    existing.RichTextUpdatedUnixMs = Math.Max(incoming.RichTextUpdatedUnixMs, incoming.ModifiedUnixMs);
                }
                changed = true;
            }
            else if (bothLegacy)
            {
                if (legacyTextRepair)
                {
                    existing.Text = incoming.Text ?? string.Empty;
                    existing.RichText = RichTextData.Clone(incoming.RichText);
                    existing.RichTextUpdatedUnixMs = Math.Max(existing.RichTextUpdatedUnixMs, incoming.RichTextUpdatedUnixMs);
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
                if (incoming.Pinned && !existing.Pinned)
                {
                    existing.Pinned = true;
                    changed = true;
                }
                if (incoming.IsTemplate && !existing.IsTemplate)
                {
                    existing.IsTemplate = true;
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
            }
            if (!string.IsNullOrWhiteSpace(incoming.SourceMachine) &&
                (incomingWins || incomingCreatedWins) &&
                !string.Equals(existing.SourceMachine ?? string.Empty, incoming.SourceMachine.Trim(), StringComparison.Ordinal))
            {
                existing.SourceMachine = incoming.SourceMachine.Trim();
                changed = true;
            }
            if (incoming.RichTextUpdatedUnixMs > existing.RichTextUpdatedUnixMs)
            {
                existing.RichText = RichTextData.Clone(incoming.RichText);
                existing.RichTextUpdatedUnixMs = incoming.RichTextUpdatedUnixMs;
                changed = true;
            }
            return changed;
        }

        public List<string> GetDevices()
        {
            lock (sync)
            {
                return CanonicalLabels(database.Entries, e => e.SourceMachine);
            }
        }

        private static List<string> CanonicalLabels(IEnumerable<ClipEntry> entries, Func<ClipEntry, string> selector)
        {
            return entries
                .Select(entry => new
                {
                    Entry = entry,
                    Label = (selector(entry) ?? string.Empty).Trim()
                })
                .Where(item => item.Label.Length > 0)
                .GroupBy(item => item.Label, StringComparer.CurrentCultureIgnoreCase)
                .Select(group => group
                    .GroupBy(item => item.Label, StringComparer.Ordinal)
                    .Select(spelling => new
                    {
                        Label = spelling.Key,
                        Count = spelling.Count(),
                        Latest = spelling.Max(item => Math.Max(item.Entry.ModifiedUnixMs,
                            Math.Max(item.Entry.LastUsedUnixMs, item.Entry.CreatedUnixMs)))
                    })
                    .OrderByDescending(item => item.Count)
                    .ThenByDescending(item => item.Latest)
                    .ThenBy(item => item.Label, StringComparer.Ordinal)
                    .First().Label)
                .OrderBy(label => label, StringComparer.CurrentCultureIgnoreCase)
                .ToList();
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
                var targetEntry = targetEntries.FirstOrDefault(e =>
                    !string.IsNullOrEmpty(e.Id) && string.Equals(e.Id, entry.Id, StringComparison.Ordinal));
                if (targetEntry == null && !targetEntries.Any(e =>
                    (!string.IsNullOrEmpty(e.Id) && string.Equals(e.Id, entry.Id, StringComparison.Ordinal)) ||
                    string.Equals(e.Text, entry.Text, StringComparison.Ordinal)))
                {
                    return true;
                }
                if (targetEntry != null && entry.ModifiedUnixMs > targetEntry.ModifiedUnixMs)
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
            if (!IsWatchedDatabaseFile(Path.GetFileName(DatabasePath), e == null ? null : e.Name)) return;
            if (reloadTimer != null) reloadTimer.Change(500, Timeout.Infinite);
        }

        /// <summary>
        /// Whether a container in the history folder is one this store reads: the history file
        /// itself, the sync rules document, or a sync channel.
        /// </summary>
        internal static bool IsWatchedDatabaseFile(string coreFileName, string changedFileName)
        {
            var name = (changedFileName ?? string.Empty).Trim();
            if (name.Length == 0) return false;
            name = Path.GetFileName(name);
            if (string.Equals(name, coreFileName, StringComparison.OrdinalIgnoreCase)) return true;
            return IsChannelOrRulesFileName(name);
        }

        private static bool IsChannelOrRulesFileName(string name)
        {
            if (string.IsNullOrEmpty(name)) return false;
            if (string.Equals(name, SyncRulesFileName, StringComparison.OrdinalIgnoreCase)) return true;
            return name.StartsWith(ChannelFilePrefix, StringComparison.OrdinalIgnoreCase) &&
                   name.EndsWith(ClipDatabaseFile.CompressedExtension, StringComparison.OrdinalIgnoreCase);
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

        public void ReloadExternalChangeAndSync()
        {
            ReloadExternalChange();
            SyncExternalChange();
        }

        public void ReloadExternalChange()
        {
            lock (sync)
            {
                LoadLocked();
            }

            OnChanged(false);
        }

        public void SyncExternalChange()
        {
            lock (sync)
            {
                if (RulesActiveLocked())
                {
                    SaveChannelsLocked(true);
                    return;
                }
                UploadToServerLocked();
            }
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
                ModifiedUnixMs = entry.ModifiedUnixMs,
                Pinned = entry.Pinned,
                IsTemplate = entry.IsTemplate,
                ManualOrder = entry.ManualOrder,
                RichText = RichTextData.Clone(entry.RichText),
                RichTextUpdatedUnixMs = entry.RichTextUpdatedUnixMs
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
            MergeDatabaseIntoLocked(database, existing);
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
            target.Entries.RemoveAll(e => IsDeleted(target, e));
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
            var entryChangedUnixMs = Math.Max(entry.CreatedUnixMs, entry.LastUsedUnixMs);
            return target.DeletedEntries.Any(d =>
                !string.IsNullOrWhiteSpace(d.TextHash) &&
                string.Equals(d.TextHash, textHash, StringComparison.Ordinal) &&
                (d.DeletedUnixMs <= 0 || entryChangedUnixMs <= d.DeletedUnixMs));
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

        // ---------------------------------------------------------------------------------------
        // Sync channels. Everything below runs only while a usable, enabled sync rules document is
        // in effect; sync-rules-spec.md sections 5 and 6 are the algorithm.
        // ---------------------------------------------------------------------------------------

        public SyncRulesDocument GetSyncRules()
        {
            lock (sync)
            {
                return SyncRuleEngine.Copy(syncRules);
            }
        }

        public bool SyncRulesReadOnly()
        {
            lock (sync)
            {
                return SyncRuleEngine.ReadOnly(syncRules);
            }
        }

        public List<string> GetSyncChannelKeys()
        {
            lock (sync)
            {
                return AllChannelKeysLocked();
            }
        }

        /// <summary>
        /// Publishes a new sync rules document and re-routes this device immediately (spec section
        /// 5, "Rules edits"). Returns null on success or a message describing why the edit was
        /// refused.
        /// </summary>
        public string SetSyncRules(SyncRulesDocument doc)
        {
            var error = SyncRuleEngine.Validate(doc);
            if (error != null) return error;

            lock (sync)
            {
                if (SyncRuleEngine.ReadOnly(syncRules))
                {
                    return "These sync rules were written by a newer version of Clipman, so this device can only apply them.";
                }

                var unsubscribedRemoval = RefusalForUnsubscribedRemovalLocked(doc);
                if (unsubscribedRemoval != null) return unsubscribedRemoval;

                var next = SyncRuleEngine.Copy(doc);
                next.Clipman = SyncRuleEngine.DocumentKind;
                if (next.Version < SyncRuleEngine.CurrentVersion) next.Version = SyncRuleEngine.CurrentVersion;
                next.UpdatedUnixMs = TimeUtil.NowUnixMs();
                next.UpdatedBy = CurrentMachineName();

                try
                {
                    RerouteChannelsLeavingDocumentLocked(next);
                }
                catch (Exception ex)
                {
                    if (!IsStorageAccessException(ex) && !IsRecoverableServerException(ex)) throw;
                    return "Clipman could not move the entries out of the channels being removed: " + ex.Message;
                }

                try
                {
                    PublishSyncRulesLocked(next);
                }
                catch (Exception ex)
                {
                    if (!IsStorageAccessException(ex) && !IsRecoverableServerException(ex)) throw;
                    return "Clipman could not save the sync rules: " + ex.Message;
                }

                selfRegistrationAttempted = false;
                LoadLocked();
                SaveLocked();
                ResetWatcherLocked();
            }

            OnChanged();
            return null;
        }

        /// <summary>
        /// Refuses an edit that removes or unroutes a channel this device does not subscribe to
        /// (spec section 5, "Rules edits": editors must be subscribed to every channel an edit
        /// affects). Mirrors the CLI's refusal. Compares against the currently-active document, not
        /// the candidate, since that is what this device can actually see right now. Returns null
        /// when the edit does not remove any channel this device is unsubscribed from.
        /// </summary>
        private string RefusalForUnsubscribedRemovalLocked(SyncRulesDocument next)
        {
            if (syncRules == null) return null;

            var currentKeys = AllChannelKeysLocked();
            if (currentKeys.Count == 0) return null;

            var survivingKeys = new HashSet<string>(StringComparer.Ordinal);
            foreach (var channel in (next == null ? null : next.Channels) ?? new List<SyncChannel>())
            {
                if (channel == null) continue;
                var key = SyncRuleEngine.ChannelKey(channel.Name);
                if (key.Length > 0) survivingKeys.Add(key);
            }

            var subscribed = SyncRuleEngine.SubscribedChannels(syncRules, CurrentMachineName());
            if (subscribed == null) return null;

            foreach (var key in currentKeys)
            {
                if (survivingKeys.Contains(key)) continue;
                if (!subscribed.Contains(key))
                {
                    return "This device is not subscribed to the " + ChannelDisplayNameLocked(key) +
                        " channel and cannot see its entries. Subscribe to it before removing it.";
                }
            }

            return null;
        }

        /// <summary>
        /// Spec section 5, "Channel deletion": the editing client re-routes a departing channel's
        /// entries and uploads the affected channels before the document forgets the channel. The
        /// re-route runs under a transitional document that keeps the old channel list - so this
        /// device stays subscribed and can still see those entries - while carrying the new routes,
        /// with a route that is disappearing neutralized so its entries fall through to whatever
        /// else matches, or to core. Only then is the real document published.
        /// </summary>
        private void RerouteChannelsLeavingDocumentLocked(SyncRulesDocument next)
        {
            if (!RulesActiveLocked() || channelSlots.Count == 0) return;

            var surviving = new Dictionary<string, SyncRoute>(StringComparer.Ordinal);
            foreach (var channel in (next == null ? null : next.Channels) ?? new List<SyncChannel>())
            {
                if (channel == null) continue;
                var key = SyncRuleEngine.ChannelKey(channel.Name);
                if (key.Length > 0 && !surviving.ContainsKey(key)) surviving[key] = channel.Route;
            }

            var leaving = false;
            var transitional = SyncRuleEngine.Copy(syncRules);
            foreach (var channel in transitional.Channels)
            {
                var key = SyncRuleEngine.ChannelKey(channel.Name);
                SyncRoute replacement;
                if (surviving.TryGetValue(key, out replacement))
                {
                    channel.Route = replacement == null ? new SyncRoute() : replacement;
                    continue;
                }
                // This channel is being removed: neutralizing its route re-routes its residents
                // through the remaining rules and empties the channel under gain-before-lose.
                channel.Route = new SyncRoute();
                leaving = true;
            }
            if (!leaving) return;

            var previous = syncRules;
            syncRules = transitional;
            try
            {
                SaveChannelsLocked(false);
            }
            finally
            {
                syncRules = previous;
            }
            if (storageUnavailable)
            {
                throw new IOException(string.IsNullOrEmpty(LastStorageError)
                    ? "The entries in the channels being removed could not be relocated."
                    : LastStorageError);
            }
        }

        /// <summary>
        /// The channels committed by the most recent save, in commit order. Relocations must list
        /// the gaining channel before the losing one (spec section 5, upload step 5).
        /// </summary>
        internal List<string> LastChannelWriteOrder()
        {
            lock (sync)
            {
                return new List<string>(channelWriteOrder);
            }
        }

        /// <summary>
        /// The one-shot notice for an entry delivered to a channel this device does not subscribe
        /// to (spec section 6). Empty once it has aged out.
        /// </summary>
        public string ChannelAnnouncement()
        {
            lock (sync)
            {
                if (channelAnnouncement.Length == 0) return string.Empty;
                if (TimeUtil.NowUnixMs() - channelAnnouncementUnixMs > ChannelAnnouncementLifetimeMs)
                {
                    channelAnnouncement = string.Empty;
                    return string.Empty;
                }
                return channelAnnouncement;
            }
        }

        private bool RulesActiveLocked()
        {
            return syncRules != null && syncRules.Enabled;
        }

        private void ClearChannelStateLocked()
        {
            channelSlots.Clear();
            residence = new Dictionary<string, string>(StringComparer.Ordinal);
            assembledMarkers = new Dictionary<string, DeletedClipEntry>(StringComparer.Ordinal);
        }

        private string DatabaseDirectoryLocked()
        {
            var directory = Path.GetDirectoryName(DatabasePath);
            return string.IsNullOrEmpty(directory) ? string.Empty : directory;
        }

        internal static string ChannelFileName(string channelKey)
        {
            return ChannelFilePrefix + SyncRuleEngine.ChannelStorageName(channelKey) + ClipDatabaseFile.CompressedExtension;
        }

        private string ChannelPathLocked(string channelKey)
        {
            if (string.IsNullOrEmpty(channelKey)) return DatabasePath;
            return Path.Combine(DatabaseDirectoryLocked(), ChannelFileName(channelKey));
        }

        private string SyncRulesPathLocked()
        {
            return Path.Combine(DatabaseDirectoryLocked(), SyncRulesFileName);
        }

        private string PendingWritesPathLocked()
        {
            return Path.Combine(DatabaseDirectoryLocked(), PendingWritesFileName);
        }

        private List<string> AllChannelKeysLocked()
        {
            var keys = new List<string>();
            if (syncRules == null) return keys;
            foreach (var channel in syncRules.Channels ?? new List<SyncChannel>())
            {
                if (channel == null) continue;
                var key = SyncRuleEngine.ChannelKey(channel.Name);
                if (key.Length > 0 && !keys.Contains(key)) keys.Add(key);
            }
            return keys;
        }

        /// <summary>
        /// The channels this device downloads besides core, in rules-document order. A device that
        /// is not listed in the document subscribes to everything (spec section 4).
        /// </summary>
        private List<string> SubscribedChannelKeysLocked()
        {
            var keys = new List<string>();
            if (!RulesActiveLocked()) return keys;

            var subscribed = SyncRuleEngine.SubscribedChannels(syncRules, CurrentMachineName());
            foreach (var key in AllChannelKeysLocked())
            {
                if (subscribed != null && !subscribed.Contains(key)) continue;
                keys.Add(key);
            }
            return keys;
        }

        private string ChannelDisplayNameLocked(string channelKey)
        {
            if (string.IsNullOrEmpty(channelKey)) return "the main history";
            if (syncRules != null)
            {
                foreach (var channel in syncRules.Channels ?? new List<SyncChannel>())
                {
                    if (channel == null) continue;
                    if (string.Equals(SyncRuleEngine.ChannelKey(channel.Name), channelKey, StringComparison.Ordinal))
                    {
                        return (channel.Name ?? string.Empty).Trim().Length == 0 ? channelKey : channel.Name.Trim();
                    }
                }
            }
            return channelKey;
        }

        private void AnnounceChannelWriteLocked(string channelKey)
        {
            channelAnnouncement = "Added to " + ChannelDisplayNameLocked(channelKey) + " for your other devices.";
            channelAnnouncementUnixMs = TimeUtil.NowUnixMs();
        }

        private void LoadSyncRulesFromDiskLocked(string password)
        {
            syncRules = null;
            var path = SyncRulesPathLocked();
            if (!File.Exists(path)) return;
            try
            {
                var document = ClipDatabaseFile.Load<SyncRulesDocument>(path, password);
                if (SyncRuleEngine.IsUsable(document)) syncRules = document;
            }
            catch (Exception)
            {
                // A damaged or unreadable rules document must never stop history from syncing;
                // the client simply behaves as one without the feature.
                syncRules = null;
            }
        }

        private void PersistSyncRulesCacheLocked()
        {
            if (syncRules == null) return;
            try
            {
                ClipDatabaseFile.SaveAtomic(SyncRulesPathLocked(), syncRules, CurrentPassword(), DatabasePath);
            }
            catch (Exception ex)
            {
                if (!IsStorageAccessException(ex)) throw;
            }
        }

        /// <summary>
        /// Resolves cloud-storage conflict copies of the rules document by whole-document
        /// last-writer-wins (spec section 4). The history merger must never be used here: it would
        /// rewrite the rules file as an empty history database.
        /// </summary>
        private void ResolveSyncRulesConflictsLocked(string password)
        {
            try
            {
                var path = SyncRulesPathLocked();
                var conflicts = SyncConflictResolver.FindConflictSiblings(path).ToList();
                if (conflicts.Count == 0) return;

                SyncRulesDocument winner = null;
                if (File.Exists(path))
                {
                    var current = ClipDatabaseFile.Load<SyncRulesDocument>(path, password);
                    if (SyncRuleEngine.IsUsable(current)) winner = current;
                }

                // Only copies that were actually understood and folded into the winner are removed.
                // Deleting one that could not be read - a different password, a truncated download -
                // would throw away the only copy of an edit made on another device.
                var consumed = new List<string>();
                var replaced = false;
                foreach (var conflict in conflicts)
                {
                    SyncRulesDocument candidate;
                    try
                    {
                        candidate = ClipDatabaseFile.Load<SyncRulesDocument>(conflict, password);
                    }
                    catch (Exception)
                    {
                        continue;
                    }
                    if (!SyncRuleEngine.IsUsable(candidate)) continue;
                    var merged = SyncRuleEngine.MergeDocuments(winner, candidate);
                    if (!ReferenceEquals(merged, winner)) replaced = true;
                    winner = merged;
                    consumed.Add(conflict);
                }

                if (winner != null && replaced)
                {
                    ClipDatabaseFile.SaveAtomic(path, winner, password, DatabasePath);
                }
                foreach (var conflict in consumed)
                {
                    TryDelete(conflict);
                }
            }
            catch (Exception)
            {
            }
        }

        /// <summary>
        /// Resolves cloud-storage conflict copies of one channel file. Every sibling the conflict
        /// scanner yields starts with this channel's own stem, so shape alone cannot tell a
        /// conflict copy from a second channel whose key extends this one ("work" and "work-pc").
        /// The discriminator is the rules document: a sibling that is a container this store owns -
        /// another declared channel, or the rules document itself - is never a conflict copy, and
        /// its presence makes the whole resolution unsafe to run.
        /// </summary>
        private void ResolveChannelConflictsLocked(string path, string password)
        {
            var owned = OwnedContainerFileNamesLocked();
            foreach (var sibling in SyncConflictResolver.FindConflictSiblings(path))
            {
                if (owned.Contains(Path.GetFileName(sibling))) return;
            }
            SyncConflictResolver.ResolveDatabaseConflicts(path, password);
        }

        private HashSet<string> OwnedContainerFileNamesLocked()
        {
            var owned = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            owned.Add(SyncRulesFileName);
            owned.Add(Path.GetFileName(DatabasePath));
            foreach (var key in AllChannelKeysLocked())
            {
                owned.Add(ChannelFileName(key));
            }
            return owned;
        }

        private void LoadChannelsFromDiskLocked(string password)
        {
            channelSlots.Clear();

            // Exists tracks the server bucket, which a local load knows nothing about. It starts
            // true so an upload before the first poll behaves exactly as it does today; a 404
            // during a poll corrects it and the next upload then creates the bucket conditionally.
            var core = new ChannelSlot();
            core.CacheFilePath = DatabasePath;
            core.Database = LoadChannelDatabase(DatabasePath, password);
            core.Exists = true;
            core.PlainHash = PlainHash(core.Database);
            channelSlots.Add(core);

            foreach (var key in SubscribedChannelKeysLocked())
            {
                var path = ChannelPathLocked(key);
                ResolveChannelConflictsLocked(path, password);
                var slot = new ChannelSlot();
                slot.Key = key;
                slot.CacheFilePath = path;
                slot.Database = LoadChannelDatabase(path, password);
                slot.Exists = true;
                slot.PlainHash = PlainHash(slot.Database);
                channelSlots.Add(slot);
            }

            ConfigureChannelClientsLocked();
            AssembleViewLocked();
        }

        private static ClipDatabase LoadChannelDatabase(string path, string password)
        {
            var loaded = ClipDatabaseFile.Load(path, password);
            NormalizeChannelDatabase(loaded);
            return loaded;
        }

        private static void NormalizeChannelDatabase(ClipDatabase target)
        {
            if (target == null) return;
            if (target.Entries == null) target.Entries = new List<ClipEntry>();
            if (target.Version < 1) target.Version = 1;
            NormalizeDeletedEntries(target);
            ApplyDeletedEntries(target);
        }

        private void ConfigureChannelClientsLocked()
        {
            foreach (var slot in channelSlots)
            {
                slot.Client = slot.Key.Length == 0 ? serverClient : ChannelClientLocked(slot.Key);
            }
        }

        private ServerStorageClient ChannelClientLocked(string channelKey)
        {
            // Core is never addressed as a channel; deriving a channel id for the empty key would
            // point at a bucket that is nobody's history.
            if (string.IsNullOrEmpty(channelKey)) return null;
            if (serverClient == null || !serverClient.IsConfigured) return null;
            var databaseId = ServerDatabaseIdentity.ChannelFromTokenAndPassword(serverToken, CurrentPassword(), channelKey);
            if (databaseId.Length == 0) return null;
            return new ServerStorageClient(serverUrl, serverToken, CurrentPassword(), serverCaCertPem, serverCaHost, databaseId);
        }

        private void EnsureSyncRulesClientLocked()
        {
            if (syncRulesClient != null) return;
            if (serverClient == null || !serverClient.IsConfigured) return;
            var databaseId = ServerDatabaseIdentity.SyncRulesFromTokenAndPassword(serverToken, CurrentPassword());
            if (databaseId.Length == 0) return;
            syncRulesClient = new ServerStorageClient(serverUrl, serverToken, CurrentPassword(), serverCaCertPem, serverCaHost, databaseId);
        }

        /// <summary>
        /// Merges every subscribed channel into the single view the user sees and records which
        /// channel each surviving entry came from (spec section 5, download steps 3 and 4).
        /// </summary>
        private void AssembleViewLocked()
        {
            var now = TimeUtil.NowUnixMs();
            var view = new ClipDatabase();
            view.Version = 1;
            view.UpdatedUnixMs = now;
            var owners = new List<string>();
            var indexById = new Dictionary<string, int>(StringComparer.Ordinal);

            foreach (var slot in channelSlots)
            {
                if (slot.Database == null || slot.Database.Entries == null) continue;
                if (slot.Database.Version > view.Version) view.Version = slot.Database.Version;
                foreach (var entry in slot.Database.Entries)
                {
                    if (entry == null) continue;
                    var identifier = ComparableId(entry.Id);
                    int index;
                    if (identifier.Length > 0 && indexById.TryGetValue(identifier, out index))
                    {
                        // The same id in two channels is a move race: the copy with the higher
                        // ModifiedUnixMs wins wholesale, and a tie keeps the earlier channel.
                        if (entry.ModifiedUnixMs > view.Entries[index].ModifiedUnixMs)
                        {
                            view.Entries[index] = Clone(entry);
                            owners[index] = slot.Key;
                        }
                        continue;
                    }
                    view.Entries.Add(Clone(entry));
                    owners.Add(slot.Key);
                    if (identifier.Length > 0) indexById[identifier] = view.Entries.Count - 1;
                }
            }

            // Tombstones apply within their own channel only, with one exception: a marker with a
            // non-empty TextHash also suppresses matching text in other channels. A relocation
            // marker has an empty TextHash and never reaches across.
            var suppressed = new bool[view.Entries.Count];
            foreach (var slot in channelSlots)
            {
                if (slot.Database == null || slot.Database.DeletedEntries == null) continue;
                foreach (var marker in slot.Database.DeletedEntries)
                {
                    if (marker == null || string.IsNullOrEmpty(marker.TextHash)) continue;
                    for (var index = 0; index < view.Entries.Count; index++)
                    {
                        if (suppressed[index]) continue;
                        if (string.Equals(owners[index], slot.Key, StringComparison.Ordinal)) continue;
                        if (TextMarkerSuppresses(marker, view.Entries[index])) suppressed[index] = true;
                    }
                }
            }

            var kept = new List<ClipEntry>();
            var keptOwners = new List<string>();
            var live = new HashSet<string>(StringComparer.Ordinal);
            for (var index = 0; index < view.Entries.Count; index++)
            {
                if (suppressed[index]) continue;
                kept.Add(view.Entries[index]);
                keptOwners.Add(owners[index]);
                live.Add(ComparableId(view.Entries[index].Id));
            }
            view.Entries = kept;

            // The view carries every channel's markers except those contradicted by a live entry
            // elsewhere: applying a relocation marker to the view would delete the entry it only
            // meant to move.
            foreach (var slot in channelSlots)
            {
                if (slot.Database == null || slot.Database.DeletedEntries == null) continue;
                foreach (var marker in slot.Database.DeletedEntries)
                {
                    if (marker == null) continue;
                    if (live.Contains(ComparableId(marker.Id))) continue;
                    view.DeletedEntries.Add(CloneMarker(marker));
                }
            }

            database = view;
            NormalizeDeletedEntriesLocked();
            NormalizeManualOrderLocked();

            residence = new Dictionary<string, string>(StringComparer.Ordinal);
            for (var index = 0; index < kept.Count; index++)
            {
                residence[kept[index].Id ?? string.Empty] = keptOwners[index];
            }
            assembledMarkers = MarkersById(database.DeletedEntries);
        }

        private static bool TextMarkerSuppresses(DeletedClipEntry marker, ClipEntry entry)
        {
            if (marker == null || entry == null) return false;
            if (string.IsNullOrEmpty(marker.TextHash) || string.IsNullOrEmpty(entry.Text)) return false;
            if (!string.Equals(marker.TextHash, ComputeTextHash(entry.Text), StringComparison.OrdinalIgnoreCase)) return false;
            var entryChangedUnixMs = Math.Max(entry.CreatedUnixMs, entry.LastUsedUnixMs);
            return marker.DeletedUnixMs <= 0 || entryChangedUnixMs <= marker.DeletedUnixMs;
        }

        private static string ComparableId(string value)
        {
            return (value ?? string.Empty).Trim().ToLowerInvariant();
        }

        private static DeletedClipEntry CloneMarker(DeletedClipEntry marker)
        {
            return new DeletedClipEntry
            {
                Id = marker.Id ?? string.Empty,
                TextHash = marker.TextHash ?? string.Empty,
                DeletedUnixMs = marker.DeletedUnixMs,
                SourceMachine = marker.SourceMachine ?? string.Empty
            };
        }

        private static Dictionary<string, DeletedClipEntry> MarkersById(List<DeletedClipEntry> markers)
        {
            var byId = new Dictionary<string, DeletedClipEntry>(StringComparer.Ordinal);
            foreach (var marker in markers ?? new List<DeletedClipEntry>())
            {
                if (marker == null) continue;
                byId[ComparableId(marker.Id)] = CloneMarker(marker);
            }
            return byId;
        }

        /// <summary>
        /// The dirty-detection hash of spec section 5, upload step 4: SHA-256 over the deterministic
        /// plaintext with the database-level UpdatedUnixMs zeroed, which is what makes the hash
        /// durable across poll cycles that restamp that field.
        /// </summary>
        private static string PlainHash(ClipDatabase target)
        {
            if (target == null) return string.Empty;
            var stamp = target.UpdatedUnixMs;
            target.UpdatedUnixMs = 0;
            try
            {
                using (var sha = SHA256.Create())
                {
                    return BitConverter
                        .ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(JsonUtil.SerializePretty(target))))
                        .Replace("-", string.Empty);
                }
            }
            finally
            {
                target.UpdatedUnixMs = stamp;
            }
        }

        private static List<TValue> ListFor<TValue>(Dictionary<string, List<TValue>> map, string key)
        {
            List<TValue> list;
            if (!map.TryGetValue(key ?? string.Empty, out list))
            {
                list = new List<TValue>();
                map[key ?? string.Empty] = list;
            }
            return list;
        }

        private static List<TValue> ListOrEmpty<TValue>(Dictionary<string, List<TValue>> map, string key)
        {
            List<TValue> list;
            return map.TryGetValue(key ?? string.Empty, out list) ? list : new List<TValue>();
        }

        private void SaveChannelsLocked(bool forceServerUpload)
        {
            if (channelSlots.Count == 0)
            {
                // Rules are in effect but the channel state could not be loaded, which a storage
                // failure during the last load can leave behind. Routing against no channels at all
                // would treat even core as unsubscribed and write the whole history through to a
                // phantom bucket, so the view is persisted whole to the history file instead and
                // the next successful load re-partitions it.
                SaveSingleDatabaseLocked();
                return;
            }

            database.UpdatedUnixMs = TimeUtil.NowUnixMs();
            channelWriteOrder = new List<string>();
            channelsAdoptedRemoteState = false;
            try
            {
                if (storageUnavailable)
                {
                    MergeExistingChannelsIfAvailableLocked();
                }

                NormalizeDeletedEntriesLocked();
                ApplyDeletedEntriesLocked();
                NormalizeManualOrderLocked();
                CommitRoutedChannelsLocked(TimeUtil.NowUnixMs(), forceServerUpload);

                storageUnavailable = false;
                LastStorageError = string.Empty;
                if (watcher == null)
                {
                    ResetWatcherLocked();
                }
            }
            catch (Exception ex)
            {
                if (!IsStorageAccessException(ex) && !IsRecoverableServerException(ex)) throw;
                storageUnavailable = true;
                LastStorageError = ex.Message;
            }
        }

        private void MergeExistingChannelsIfAvailableLocked()
        {
            var password = CurrentPassword();
            foreach (var slot in channelSlots)
            {
                if (!File.Exists(slot.CacheFilePath)) continue;
                var existing = ClipDatabaseFile.Load(slot.CacheFilePath, password);
                if (existing == null || existing.Entries == null || existing.Entries.Count == 0) continue;
                MergeDatabaseIntoLocked(database, existing);
            }
            NormalizeManualOrderLocked();
        }

        /// <summary>
        /// The upload half of spec section 5: route every entry, rebuild one database per channel,
        /// write entries bound for unsubscribed channels straight through, and commit only the
        /// channels whose plaintext actually changed, in the add-then-remove two-phase order.
        /// </summary>
        private void CommitRoutedChannelsLocked(long now, bool forceServerUpload)
        {
            var subscribed = new HashSet<string>(StringComparer.Ordinal);
            foreach (var slot in channelSlots) subscribed.Add(slot.Key);

            var fetched = FetchedEntriesByChannelLocked();
            var previousMarkers = assembledMarkers;

            var routed = new Dictionary<string, List<ClipEntry>>(StringComparer.Ordinal);
            var departures = new Dictionary<string, List<ClipEntry>>(StringComparer.Ordinal);
            var relocations = new Dictionary<string, List<DeletedClipEntry>>(StringComparer.Ordinal);
            var pending = new Dictionary<string, List<ClipEntry>>(StringComparer.Ordinal);
            var pendingKeys = new List<string>();

            // A future-version document is read-only: this client cannot fully evaluate its rules,
            // so it must not fight better-informed clients over placement. Every entry that already
            // lives somewhere stays there - no relocation markers, no migration - and only new
            // captures are routed (spec section 4).
            var readOnlyRules = SyncRuleEngine.ReadOnly(syncRules);

            foreach (var entry in database.Entries)
            {
                if (entry == null) continue;
                var target = SyncRuleEngine.RouteEntry(syncRules, entry);
                string source;
                var resident = residence.TryGetValue(entry.Id ?? string.Empty, out source);
                if (readOnlyRules && resident) target = source;
                if (resident && !string.Equals(source, target, StringComparison.Ordinal))
                {
                    // Leaving a channel leaves a relocation marker behind: an empty TextHash
                    // distinguishes "moved" from "deleted" (spec section 5, upload step 3).
                    ListFor(departures, source).Add(entry);
                    ListFor(relocations, source).Add(new DeletedClipEntry
                    {
                        Id = entry.Id,
                        TextHash = string.Empty,
                        DeletedUnixMs = now,
                        SourceMachine = CurrentMachineName()
                    });
                }

                if (subscribed.Contains(target))
                {
                    ListFor(routed, target).Add(entry);
                    continue;
                }
                if (!pending.ContainsKey(target)) pendingKeys.Add(target);
                ListFor(pending, target).Add(entry);
            }

            // First save: create the core container before anything else so every container beside
            // it copies its salt and one key derivation serves them all.
            if (!File.Exists(DatabasePath))
            {
                var initial = BuildChannelDatabasesLocked(
                    WithDepartures(routed, departures, fetched),
                    AssembleMarkersLocked(previousMarkers, subscribed, null),
                    now);
                var writes = pendingKeys.Count > 0;
                for (var index = 0; index < channelSlots.Count && !writes; index++)
                {
                    if (!string.Equals(PlainHash(initial[index]), channelSlots[index].PlainHash, StringComparison.Ordinal))
                    {
                        writes = true;
                    }
                }
                if (writes)
                {
                    CommitChannelLocked(channelSlots[0], initial[0], now, true);
                }
            }

            // Write-through (spec section 6) is committed first: its targets gain entries that
            // their source channels are about to lose. When one fails the entry is not taken away
            // from where it already lives - the departure and its marker are cancelled - and the
            // entry is parked for retry after the next successful poll.
            pendingKeys.Sort(StringComparer.Ordinal);
            var delivered = new List<string>();
            foreach (var channelKey in pendingKeys)
            {
                if (WriteThroughLocked(channelKey, pending[channelKey], now))
                {
                    AnnounceChannelWriteLocked(channelKey);
                    foreach (var entry in pending[channelKey])
                    {
                        delivered.Add(entry.Id ?? string.Empty);
                    }
                    continue;
                }

                ParkPendingWritesLocked(channelKey, pending[channelKey]);
                foreach (var entry in pending[channelKey])
                {
                    string source;
                    if (!residence.TryGetValue(entry.Id ?? string.Empty, out source)) continue;
                    ListFor(routed, source).Add(entry);
                    RemoveEntryById(ListFor(departures, source), entry.Id);
                    RemoveMarkerById(ListFor(relocations, source), entry.Id);
                }
            }

            // Phase 1: every channel keeps the entries it is about to lose and withholds its new
            // relocation markers, so this pass only ever adds. A departing entry is carried in the
            // copy the channel was fetched with, so the target's higher ModifiedUnixMs wins view
            // assembly for the window in which both channels hold the id.
            var phaseOne = BuildChannelDatabasesLocked(
                WithDepartures(routed, departures, fetched),
                AssembleMarkersLocked(previousMarkers, subscribed, null),
                now);
            for (var index = 0; index < channelSlots.Count; index++)
            {
                var slot = channelSlots[index];
                var dirty = !string.Equals(PlainHash(phaseOne[index]), slot.PlainHash, StringComparison.Ordinal);
                if (!dirty && !forceServerUpload && !slot.NeedsUpload) continue;
                CommitChannelLocked(slot, phaseOne[index], now, dirty);
            }

            // Phase 2: with every addition committed, the losing channels drop their departures and
            // gain their relocation markers. A failure here is safe: the entry exists in both
            // channels and view assembly resolves the duplicate until the next save repairs it.
            var phaseTwo = BuildChannelDatabasesLocked(
                routed,
                AssembleMarkersLocked(previousMarkers, subscribed, relocations),
                now);
            for (var index = 0; index < channelSlots.Count; index++)
            {
                var slot = channelSlots[index];
                if (ListOrEmpty(departures, slot.Key).Count == 0) continue;
                if (string.Equals(PlainHash(phaseTwo[index]), slot.PlainHash, StringComparison.Ordinal)) continue;
                CommitChannelLocked(slot, phaseTwo[index], now, true);
            }

            // Entries handed to an unsubscribed channel do not appear in the local view.
            if (delivered.Count > 0)
            {
                var deliveredIds = new HashSet<string>(delivered, StringComparer.Ordinal);
                database.Entries.RemoveAll(entry => entry != null && deliveredIds.Contains(entry.Id ?? string.Empty));
                foreach (var id in delivered) residence.Remove(id);
            }

            if (channelsAdoptedRemoteState)
            {
                // A conflict or read-before-mutate merged entries another device had added into a
                // channel. They are committed but absent from the view, and rebuilding that channel
                // from the view on the next save would delete them again, so the view is re-derived
                // from the channel state that actually committed.
                AssembleViewLocked();
                return;
            }

            foreach (var slot in channelSlots)
            {
                foreach (var entry in ListOrEmpty(routed, slot.Key))
                {
                    residence[entry.Id ?? string.Empty] = slot.Key;
                }
            }
            assembledMarkers = MarkersById(database.DeletedEntries);
        }

        private Dictionary<string, Dictionary<string, ClipEntry>> FetchedEntriesByChannelLocked()
        {
            var byChannel = new Dictionary<string, Dictionary<string, ClipEntry>>(StringComparer.Ordinal);
            foreach (var slot in channelSlots)
            {
                var entries = new Dictionary<string, ClipEntry>(StringComparer.Ordinal);
                if (slot.Database != null && slot.Database.Entries != null)
                {
                    foreach (var entry in slot.Database.Entries)
                    {
                        if (entry != null) entries[ComparableId(entry.Id)] = entry;
                    }
                }
                byChannel[slot.Key] = entries;
            }
            return byChannel;
        }

        private static Dictionary<string, List<ClipEntry>> WithDepartures(
            Dictionary<string, List<ClipEntry>> routed,
            Dictionary<string, List<ClipEntry>> departures,
            Dictionary<string, Dictionary<string, ClipEntry>> fetched)
        {
            if (departures.Count == 0) return routed;

            var combined = new Dictionary<string, List<ClipEntry>>(StringComparer.Ordinal);
            foreach (var pair in routed) combined[pair.Key] = new List<ClipEntry>(pair.Value);
            foreach (var pair in departures)
            {
                if (pair.Value.Count == 0) continue;
                var staying = ListFor(combined, pair.Key);
                foreach (var entry in pair.Value)
                {
                    Dictionary<string, ClipEntry> byId;
                    ClipEntry before;
                    if (fetched.TryGetValue(pair.Key, out byId) &&
                        byId.TryGetValue(ComparableId(entry.Id), out before))
                    {
                        staying.Add(before);
                        continue;
                    }
                    staying.Add(entry);
                }
            }
            return combined;
        }

        private static void RemoveEntryById(List<ClipEntry> entries, string id)
        {
            entries.RemoveAll(entry => entry != null && string.Equals(ComparableId(entry.Id), ComparableId(id), StringComparison.Ordinal));
        }

        private static void RemoveMarkerById(List<DeletedClipEntry> markers, string id)
        {
            markers.RemoveAll(marker => marker != null && string.Equals(ComparableId(marker.Id), ComparableId(id), StringComparison.Ordinal));
        }

        /// <summary>
        /// Files tombstones per channel: each channel keeps the markers it already carried, markers
        /// this mutation created or refreshed go to the channel their entry lived in, and relocation
        /// markers are added last for the channels their entries left.
        /// </summary>
        private Dictionary<string, List<DeletedClipEntry>> AssembleMarkersLocked(
            Dictionary<string, DeletedClipEntry> previousMarkers,
            HashSet<string> subscribed,
            Dictionary<string, List<DeletedClipEntry>> relocations)
        {
            var markers = new Dictionary<string, List<DeletedClipEntry>>(StringComparer.Ordinal);
            foreach (var slot in channelSlots)
            {
                var carried = new List<DeletedClipEntry>();
                if (slot.Database != null && slot.Database.DeletedEntries != null)
                {
                    foreach (var marker in slot.Database.DeletedEntries)
                    {
                        if (marker != null) carried.Add(CloneMarker(marker));
                    }
                }
                markers[slot.Key] = carried;
            }

            foreach (var marker in database.DeletedEntries ?? new List<DeletedClipEntry>())
            {
                if (marker == null) continue;
                DeletedClipEntry before;
                if (previousMarkers.TryGetValue(ComparableId(marker.Id), out before) &&
                    before.DeletedUnixMs == marker.DeletedUnixMs &&
                    string.Equals(before.TextHash ?? string.Empty, marker.TextHash ?? string.Empty, StringComparison.Ordinal))
                {
                    continue;
                }

                string home;
                if (!residence.TryGetValue(marker.Id ?? string.Empty, out home) || !subscribed.Contains(home))
                {
                    home = string.Empty;
                }
                ListFor(markers, home).Add(CloneMarker(marker));
            }

            if (relocations != null)
            {
                foreach (var pair in relocations)
                {
                    if (!subscribed.Contains(pair.Key)) continue;
                    foreach (var marker in pair.Value) ListFor(markers, pair.Key).Add(CloneMarker(marker));
                }
            }
            return markers;
        }

        private List<ClipDatabase> BuildChannelDatabasesLocked(
            Dictionary<string, List<ClipEntry>> routed,
            Dictionary<string, List<DeletedClipEntry>> markers,
            long now)
        {
            var databases = new List<ClipDatabase>();
            foreach (var slot in channelSlots)
            {
                var entries = ListOrEmpty(routed, slot.Key);
                var built = new ClipDatabase();
                built.Version = slot.Database == null || slot.Database.Version < 1 ? 1 : slot.Database.Version;
                built.UpdatedUnixMs = now;
                built.Entries = new List<ClipEntry>();
                foreach (var entry in entries) built.Entries.Add(Clone(entry));
                built.DeletedEntries = DropMarkersForEntries(ListOrEmpty(markers, slot.Key), entries);
                NormalizeDeletedEntries(built);
                NormalizeChannelManualOrder(built);
                databases.Add(built);
            }
            return databases;
        }

        /// <summary>
        /// Numbers manual order within one channel database. Each channel is normalized on its own,
        /// so two devices subscribed to different sets of channels write the same bytes for a shared
        /// channel instead of stamping it with their own whole-view numbering and fighting over it
        /// on every poll.
        /// </summary>
        private static void NormalizeChannelManualOrder(ClipDatabase target)
        {
            var next = 1L;
            foreach (var entry in target.Entries
                .OrderBy(e => e.ManualOrder <= 0 ? long.MaxValue : e.ManualOrder)
                .ThenBy(e => e.CreatedUnixMs))
            {
                if (entry.CreatedUnixMs == 0) entry.CreatedUnixMs = TimeUtil.NowUnixMs();
                if (entry.LastUsedUnixMs == 0) entry.LastUsedUnixMs = entry.CreatedUnixMs;
                if (entry.Name == null) entry.Name = string.Empty;
                if (entry.Group == null) entry.Group = string.Empty;
                if (entry.SourceMachine == null) entry.SourceMachine = string.Empty;
                entry.ManualOrder = next++;
            }
        }

        /// <summary>
        /// Drops markers naming an entry being written into the same channel, so a relocation marker
        /// left by an earlier move cannot delete the entry again when a rule change moves it back.
        /// </summary>
        private static List<DeletedClipEntry> DropMarkersForEntries(List<DeletedClipEntry> markers, List<ClipEntry> entries)
        {
            if (markers.Count == 0 || entries.Count == 0) return markers;
            var resident = new HashSet<string>(StringComparer.Ordinal);
            foreach (var entry in entries)
            {
                if (entry != null) resident.Add(ComparableId(entry.Id));
            }
            var kept = new List<DeletedClipEntry>();
            foreach (var marker in markers)
            {
                if (marker == null || resident.Contains(ComparableId(marker.Id))) continue;
                kept.Add(marker);
            }
            return kept;
        }

        private void CommitChannelLocked(ChannelSlot slot, ClipDatabase built, long now, bool writeFile)
        {
            var password = CurrentPassword();
            if (writeFile || !File.Exists(slot.CacheFilePath))
            {
                ClipDatabaseFile.SaveAtomic(slot.CacheFilePath, built, password, DatabasePath);
            }
            channelWriteOrder.Add(slot.Key);

            var committed = built;
            if (slot.Client != null && slot.Client.IsConfigured)
            {
                committed = UploadChannelLocked(slot, built, now);
            }

            slot.Database = committed;
            slot.PlainHash = PlainHash(committed);
            slot.Exists = true;
            slot.NeedsUpload = false;
            if (slot.Key.Length == 0) serverRevision = slot.Revision;
        }

        /// <summary>
        /// Uploads one channel with its own If-Match, re-reading and merging that channel alone on a
        /// conflict (spec section 5, upload step 5). Returns the database that actually committed.
        /// </summary>
        private ClipDatabase UploadChannelLocked(ChannelSlot slot, ClipDatabase built, long now)
        {
            var password = CurrentPassword();
            var target = built;

            // Read before mutate: a slot whose revision is unknown - a fresh start, or a channel
            // whose last transfer failed - would otherwise PUT unconditionally and overwrite
            // whatever another device wrote in the meantime.
            if (slot.Exists && string.IsNullOrWhiteSpace(slot.Revision))
            {
                target = AdoptRemoteChannelLocked(slot, target, password, now);
            }

            for (var attempt = 0; ; attempt++)
            {
                try
                {
                    // A bucket that does not exist yet is created with If-None-Match, so a channel
                    // two devices reach for at the same time is never silently overwritten.
                    var metadata = slot.Client.Upload(File.ReadAllBytes(slot.CacheFilePath), slot.Revision, !slot.Exists);
                    slot.Revision = metadata == null ? string.Empty : metadata.Revision;
                    slot.Exists = true;
                    MarkServerSuccessLocked(true);
                    return target;
                }
                catch (WebException ex)
                {
                    if (!slot.Client.IsConflict(ex) || attempt >= 3)
                    {
                        slot.Revision = string.Empty;
                        MarkServerFailureLocked();
                        throw;
                    }
                }

                target = AdoptRemoteChannelLocked(slot, target, password, now);
            }
        }

        /// <summary>
        /// Re-reads one channel and merges the build about to be uploaded into the server's copy.
        /// Entries the merge brings back are not in the view yet, so the caller must reassemble
        /// before the next save rebuilds this channel and PUTs them away again.
        /// </summary>
        private ClipDatabase AdoptRemoteChannelLocked(ChannelSlot slot, ClipDatabase built, string password, long now)
        {
            string revision;
            bool exists;
            var remote = DownloadChannelLocked(slot.Client, slot.CacheFilePath, password, out revision, out exists);
            slot.Revision = revision;
            slot.Exists = exists;
            if (!exists) return built;

            MergeDatabaseIntoLocked(remote, built);
            NormalizeChannelDatabase(remote);
            remote.UpdatedUnixMs = now;
            channelsAdoptedRemoteState = true;
            ClipDatabaseFile.SaveAtomic(slot.CacheFilePath, remote, password, DatabasePath);
            return remote;
        }

        private ClipDatabase DownloadChannelLocked(
            ServerStorageClient client,
            string nearbyPath,
            string password,
            out string revision,
            out bool exists)
        {
            revision = string.Empty;
            exists = false;
            ServerDatabaseDownload download;
            try
            {
                download = client.Download();
            }
            catch (WebException ex)
            {
                if (client.IsNotFound(ex)) return new ClipDatabase();
                throw;
            }

            if (download.Data == null || download.Data.Length == 0) return new ClipDatabase();
            var tempPath = nearbyPath + ".server-download.tmp";
            WriteBytesAtomic(tempPath, download.Data);
            var downloaded = ClipDatabaseFile.Load(tempPath, password);
            TryDelete(tempPath);
            NormalizeChannelDatabase(downloaded);
            revision = download.Metadata == null ? string.Empty : download.Metadata.Revision;
            exists = true;
            return downloaded;
        }

        /// <summary>
        /// The one-shot fetch-merge-put of spec section 6 for a channel this device does not
        /// subscribe to. The channel is discarded again afterwards, so it never reaches the view.
        /// </summary>
        private bool WriteThroughLocked(string channelKey, List<ClipEntry> entries, long now)
        {
            if (entries == null || entries.Count == 0) return true;
            // Core is always subscribed, so it is never a write-through target. Treating it as one
            // would send the whole history to a bucket derived as if core were a channel.
            if (string.IsNullOrEmpty(channelKey)) return false;

            var password = CurrentPassword();
            var channelPath = ChannelPathLocked(channelKey);
            var client = ChannelClientLocked(channelKey);
            var throughServer = client != null && client.IsConfigured;
            var scratchPath = throughServer
                ? Path.Combine(DatabaseDirectoryLocked(), "writethrough-" + SyncRuleEngine.ChannelStorageName(channelKey) + ClipDatabaseFile.CompressedExtension)
                : channelPath;

            try
            {
                var slot = new ChannelSlot();
                slot.Key = channelKey;
                slot.CacheFilePath = scratchPath;
                slot.Client = client;

                ClipDatabase target;
                if (throughServer)
                {
                    string revision;
                    bool exists;
                    target = DownloadChannelLocked(client, scratchPath, password, out revision, out exists);
                    slot.Revision = revision;
                    slot.Exists = exists;
                }
                else
                {
                    ResolveChannelConflictsLocked(channelPath, password);
                    target = LoadChannelDatabase(channelPath, password);
                }

                var source = new ClipDatabase();
                source.UpdatedUnixMs = now;
                foreach (var entry in entries)
                {
                    if (entry != null) source.Entries.Add(Clone(entry));
                }
                target.DeletedEntries = DropMarkersForEntries(
                    target.DeletedEntries ?? new List<DeletedClipEntry>(),
                    source.Entries);
                MergeDatabaseIntoLocked(target, source);
                target.UpdatedUnixMs = now;

                ClipDatabaseFile.SaveAtomic(scratchPath, target, password, DatabasePath);
                if (throughServer)
                {
                    UploadChannelLocked(slot, target, now);
                }
                return true;
            }
            catch (Exception ex)
            {
                if (!IsStorageAccessException(ex) && !IsRecoverableServerException(ex)) throw;
                return false;
            }
            finally
            {
                if (throughServer) TryDelete(scratchPath);
            }
        }

        private void ParkPendingWritesLocked(string channelKey, List<ClipEntry> entries)
        {
            try
            {
                var path = PendingWritesPathLocked();
                var store = JsonUtil.Load<PendingChannelWrites>(path);
                if (store.Channels == null) store.Channels = new List<PendingChannelWrite>();

                PendingChannelWrite bucket = null;
                foreach (var candidate in store.Channels)
                {
                    if (candidate == null) continue;
                    if (string.Equals(candidate.ChannelKey, channelKey, StringComparison.Ordinal))
                    {
                        bucket = candidate;
                        break;
                    }
                }
                if (bucket == null)
                {
                    bucket = new PendingChannelWrite { ChannelKey = channelKey };
                    store.Channels.Add(bucket);
                }
                if (bucket.Entries == null) bucket.Entries = new List<ClipEntry>();

                foreach (var entry in entries)
                {
                    if (entry == null) continue;
                    var known = false;
                    foreach (var existing in bucket.Entries)
                    {
                        if (existing != null && string.Equals(ComparableId(existing.Id), ComparableId(entry.Id), StringComparison.Ordinal))
                        {
                            known = true;
                            break;
                        }
                    }
                    if (!known) bucket.Entries.Add(Clone(entry));
                }
                JsonUtil.SaveAtomic(path, store);
            }
            catch (Exception)
            {
            }
        }

        /// <summary>
        /// Retries the entries parked by a failed write-through (spec section 6). A parked entry was
        /// left in the channel it already lived in, so a successful delivery leaves it in two
        /// places: it is dropped from the view here and its source channel is marked for the repair
        /// save, which rebuilds that channel without it. Returns whether the view changed.
        /// </summary>
        private bool RetryPendingWritesLocked(long now)
        {
            var path = PendingWritesPathLocked();
            if (!File.Exists(path)) return false;

            PendingChannelWrites store;
            try
            {
                store = JsonUtil.Load<PendingChannelWrites>(path);
            }
            catch (Exception)
            {
                return false;
            }
            if (store.Channels == null || store.Channels.Count == 0)
            {
                TryDelete(path);
                return false;
            }

            var remaining = new List<PendingChannelWrite>();
            var deliveredIds = new List<string>();
            foreach (var bucket in store.Channels)
            {
                if (bucket == null || bucket.Entries == null || bucket.Entries.Count == 0) continue;
                if (WriteThroughLocked(bucket.ChannelKey, bucket.Entries, now))
                {
                    AnnounceChannelWriteLocked(bucket.ChannelKey);
                    foreach (var entry in bucket.Entries)
                    {
                        if (entry != null) deliveredIds.Add(entry.Id ?? string.Empty);
                    }
                    continue;
                }
                remaining.Add(bucket);
            }
            if (deliveredIds.Count == 0) return false;

            try
            {
                if (remaining.Count == 0)
                {
                    TryDelete(path);
                }
                else
                {
                    JsonUtil.SaveAtomic(path, new PendingChannelWrites { Channels = remaining });
                }
            }
            catch (Exception)
            {
            }

            var changed = false;
            foreach (var id in deliveredIds)
            {
                string source;
                if (residence.TryGetValue(id, out source))
                {
                    var slot = FindChannelSlotLocked(source);
                    if (slot != null) slot.NeedsUpload = true;
                    residence.Remove(id);
                }
            }
            var removedIds = new HashSet<string>(deliveredIds, StringComparer.Ordinal);
            if (database.Entries.RemoveAll(entry => entry != null && removedIds.Contains(entry.Id ?? string.Empty)) > 0)
            {
                changed = true;
            }
            return changed;
        }

        private ChannelSlot FindChannelSlotLocked(string channelKey)
        {
            foreach (var slot in channelSlots)
            {
                if (string.Equals(slot.Key, channelKey ?? string.Empty, StringComparison.Ordinal)) return slot;
            }
            return null;
        }

        private bool AnyChannelNeedsUploadLocked()
        {
            foreach (var slot in channelSlots)
            {
                if (slot.NeedsUpload) return true;
            }
            return false;
        }

        /// <summary>
        /// Download half of the poll for a channel-partitioned history: HEAD every subscribed
        /// channel, GET only the ones whose revision changed, merge each into its own channel, and
        /// reassemble the view (spec section 5, download steps 1-3).
        /// </summary>
        private bool SyncChannelsFromServerLocked(bool uploadLocalWhenMissing)
        {
            if (serverClient == null || !serverClient.IsConfigured) return false;
            if (serverSyncInProgress) return false;

            serverSyncInProgress = true;
            try
            {
                var password = CurrentPassword();
                var changed = false;
                try
                {
                    DownloadChannelsLocked(password, uploadLocalWhenMissing, ref changed);
                }
                finally
                {
                    // A channel that failed part way through must not leave the view describing
                    // channels that have already moved on. The notification is latched because the
                    // failure propagates past the caller's own return value.
                    serverRevision = channelSlots.Count == 0 ? string.Empty : channelSlots[0].Revision;
                    if (changed)
                    {
                        AssembleViewLocked();
                        viewChangedNotificationPending = true;
                    }
                }

                storageUnavailable = false;
                LastStorageError = string.Empty;
                MarkServerSuccessLocked(false);
                return changed;
            }
            finally
            {
                serverSyncInProgress = false;
            }
        }

        /// <summary>
        /// HEADs every subscribed channel and GETs only the ones whose revision changed, merging
        /// each into its own channel. <paramref name="changed"/> is written through as the pass
        /// proceeds so a failure part way still tells the caller the view needs reassembling.
        /// </summary>
        private void DownloadChannelsLocked(string password, bool uploadLocalWhenMissing, ref bool changed)
        {
            foreach (var slot in channelSlots)
            {
                if (slot.Client == null || !slot.Client.IsConfigured) continue;

                try
                {
                    var head = slot.Client.GetMetadata();
                    if (!string.IsNullOrWhiteSpace(head.Revision) &&
                        string.Equals(head.Revision, slot.Revision, StringComparison.Ordinal))
                    {
                        continue;
                    }
                }
                catch (WebException ex)
                {
                    if (!slot.Client.IsNotFound(ex)) throw;
                    MarkChannelBucketMissingLocked(slot, uploadLocalWhenMissing);
                    continue;
                }

                string revision;
                bool exists;
                var remote = DownloadChannelLocked(slot.Client, slot.CacheFilePath, password, out revision, out exists);
                if (!exists)
                {
                    MarkChannelBucketMissingLocked(slot, uploadLocalWhenMissing);
                    continue;
                }

                if (HasLocalStateMissingFromServer(remote, slot.Database)) slot.NeedsUpload = true;
                if (MergeDatabaseIntoLocked(slot.Database, remote)) changed = true;
                NormalizeChannelDatabase(slot.Database);
                slot.Revision = revision;
                slot.Exists = true;
                ClipDatabaseFile.SaveAtomic(slot.CacheFilePath, slot.Database, password, DatabasePath);
                slot.PlainHash = PlainHash(slot.Database);
            }
        }

        private static void MarkChannelBucketMissingLocked(ChannelSlot slot, bool uploadLocalWhenMissing)
        {
            slot.Revision = string.Empty;
            slot.Exists = false;
            if (uploadLocalWhenMissing && slot.Database != null && slot.Database.Entries.Count > 0)
            {
                slot.NeedsUpload = true;
            }
        }

        /// <summary>
        /// Spec section 5, download step 1. A missing bucket falls back to the local cache and
        /// re-uploads it create-only; a damaged document leaves rules untouched rather than
        /// stopping history from syncing.
        /// </summary>
        private bool RefreshSyncRulesFromServerLocked()
        {
            if (serverClient == null || !serverClient.IsConfigured) return false;
            var now = TimeUtil.NowUnixMs();
            if (syncRulesNextCheckUnixMs > now) return false;

            EnsureSyncRulesClientLocked();
            if (syncRulesClient == null || !syncRulesClient.IsConfigured) return false;

            try
            {
                var head = syncRulesClient.GetMetadata();
                syncRulesNextCheckUnixMs = 0;
                if (syncRules != null &&
                    !string.IsNullOrWhiteSpace(head.Revision) &&
                    string.Equals(head.Revision, syncRulesRevision, StringComparison.Ordinal))
                {
                    return false;
                }

                var download = syncRulesClient.Download();
                var tempPath = SyncRulesPathLocked() + ".server-download.tmp";
                WriteBytesAtomic(tempPath, download.Data);
                var remote = ClipDatabaseFile.Load<SyncRulesDocument>(tempPath, CurrentPassword());
                TryDelete(tempPath);
                if (!SyncRuleEngine.IsUsable(remote)) return false;

                var merged = SyncRuleEngine.MergeDocuments(syncRules, remote);
                // When the cache wins the merge the effective document is not the one the server
                // holds, so no revision is recorded: an If-Match against it would claim an edit was
                // based on a document it never saw.
                syncRulesRevision = ReferenceEquals(merged, remote)
                    ? (download.Metadata == null ? string.Empty : download.Metadata.Revision)
                    : string.Empty;
                var changed = !SameSyncRules(syncRules, merged);
                syncRules = merged;
                return changed;
            }
            catch (WebException ex)
            {
                syncRulesNextCheckUnixMs = now + SyncRulesAbsentRecheckMs;
                // A future-version document is display-only: this client applies what it understands
                // but must never write its own interpretation back, restore included.
                if (syncRulesClient.IsNotFound(ex) && syncRules != null && !SyncRuleEngine.ReadOnly(syncRules))
                {
                    UploadCachedSyncRulesLocked();
                }
                return false;
            }
            catch (Exception)
            {
                syncRulesNextCheckUnixMs = now + SyncRulesAbsentRecheckMs;
                return false;
            }
        }

        private static bool SameSyncRules(SyncRulesDocument left, SyncRulesDocument right)
        {
            if (ReferenceEquals(left, right)) return true;
            if (left == null || right == null) return false;
            return string.Equals(JsonUtil.SerializePretty(left), JsonUtil.SerializePretty(right), StringComparison.Ordinal);
        }

        private void UploadCachedSyncRulesLocked()
        {
            // The caller checks this too; keeping it here makes "a read-only document is never
            // written back" a property of the only method that writes the cache to the bucket.
            if (syncRules == null || SyncRuleEngine.ReadOnly(syncRules)) return;
            try
            {
                var path = SyncRulesPathLocked();
                ClipDatabaseFile.SaveAtomic(path, syncRules, CurrentPassword(), DatabasePath);
                var metadata = syncRulesClient.Upload(File.ReadAllBytes(path), string.Empty, true);
                syncRulesRevision = metadata == null ? string.Empty : metadata.Revision;
            }
            catch (Exception)
            {
            }
        }

        private void PublishSyncRulesLocked(SyncRulesDocument document)
        {
            var path = SyncRulesPathLocked();
            var published = document;
            ClipDatabaseFile.SaveAtomic(path, published, CurrentPassword(), DatabasePath);

            EnsureSyncRulesClientLocked();
            if (syncRulesClient == null || !syncRulesClient.IsConfigured)
            {
                syncRules = published;
                return;
            }

            for (var attempt = 0; ; attempt++)
            {
                try
                {
                    var metadata = syncRulesClient.Upload(File.ReadAllBytes(path), syncRulesRevision);
                    syncRulesRevision = metadata == null ? string.Empty : metadata.Revision;
                    break;
                }
                catch (WebException ex)
                {
                    if (!syncRulesClient.IsConflict(ex) || attempt >= 2) throw;

                    var download = syncRulesClient.Download();
                    var tempPath = path + ".server-download.tmp";
                    WriteBytesAtomic(tempPath, download.Data);
                    var remote = ClipDatabaseFile.Load<SyncRulesDocument>(tempPath, CurrentPassword());
                    TryDelete(tempPath);
                    syncRulesRevision = download.Metadata == null ? string.Empty : download.Metadata.Revision;
                    if (SyncRuleEngine.IsUsable(remote) &&
                        ReferenceEquals(SyncRuleEngine.MergeDocuments(published, remote), remote))
                    {
                        // The concurrent edit is newer, so it wins the whole document.
                        published = remote;
                        ClipDatabaseFile.SaveAtomic(path, published, CurrentPassword(), DatabasePath);
                        break;
                    }
                }
            }

            syncRules = published;
        }

        /// <summary>
        /// Spec section 4, Registry behavior: an updated client whose device name is missing from
        /// Devices adds itself with all channels on its next successful sync. One best-effort
        /// attempt per configuration.
        /// </summary>
        private void SelfRegisterDeviceLocked()
        {
            if (selfRegistrationAttempted) return;
            if (!RulesActiveLocked() || SyncRuleEngine.ReadOnly(syncRules)) return;

            var deviceName = CurrentMachineName();
            var normalized = deviceName.Trim().ToLowerInvariant();
            foreach (var device in syncRules.Devices ?? new List<SyncDevice>())
            {
                if (device == null) continue;
                if (string.Equals((device.Name ?? string.Empty).Trim().ToLowerInvariant(), normalized, StringComparison.Ordinal))
                {
                    selfRegistrationAttempted = true;
                    return;
                }
            }

            selfRegistrationAttempted = true;
            var updated = SyncRuleEngine.Copy(syncRules);
            updated.Devices.Add(new SyncDevice { Name = deviceName, Channels = new List<string> { "*" } });
            updated.UpdatedUnixMs = TimeUtil.NowUnixMs();
            updated.UpdatedBy = deviceName;
            if (SyncRuleEngine.Validate(updated) != null) return;

            try
            {
                PublishSyncRulesLocked(updated);
            }
            catch (Exception)
            {
            }
        }

        private void ReconfigureChannelsLocked()
        {
            PersistSyncRulesCacheLocked();
            selfRegistrationAttempted = false;
            LoadLocked();
            ResetWatcherLocked();
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

        private string CurrentMachineName()
        {
            return machineName;
        }

        private static string NormalizeMachineName(string value)
        {
            var normalized = (value ?? string.Empty).Trim();
            return normalized.Length == 0 ? (Environment.MachineName ?? string.Empty).Trim() : normalized;
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
            lock (sync)
            {
                serverPollGeneration++;
                if (serverPollTimer != null) serverPollTimer.Dispose();
                serverPollTimer = null;
            }
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
