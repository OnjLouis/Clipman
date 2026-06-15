using System;
using System.Collections.Generic;
using System.Linq;
using System.Web.Script.Serialization;

namespace Clipman
{
    public sealed class ClipEntry
    {
        public string Id { get; set; }
        public string Text { get; set; }
        public string Name { get; set; }
        public string Group { get; set; }
        public string SourceMachine { get; set; }
        public long CreatedUnixMs { get; set; }
        public long LastUsedUnixMs { get; set; }
        public bool Pinned { get; set; }
        public long ManualOrder { get; set; }

        public ClipEntry()
        {
            Id = Guid.NewGuid().ToString("N");
            Text = string.Empty;
            Name = string.Empty;
            Group = string.Empty;
            SourceMachine = string.Empty;
            CreatedUnixMs = TimeUtil.NowUnixMs();
            LastUsedUnixMs = CreatedUnixMs;
        }
    }

    public sealed class ClipDatabase
    {
        public int Version { get; set; }
        public long UpdatedUnixMs { get; set; }
        public List<ClipEntry> Entries { get; set; }

        public ClipDatabase()
        {
            Version = 1;
            UpdatedUnixMs = TimeUtil.NowUnixMs();
            Entries = new List<ClipEntry>();
        }
    }

    public sealed class AppSettings
    {
        public string ShowHistoryHotkey { get; set; }
        public string ToggleActiveHotkey { get; set; }
        public bool RemoveDuplicates { get; set; }
        public bool SoundsEnabled { get; set; }
        public bool SaveListPosition { get; set; }
        public bool Active { get; set; }
        public string DatabasePath { get; set; }
        public int LastSelectedIndex { get; set; }
        public int LastSelectedTab { get; set; }
        public int LastPreferencesTab { get; set; }
        public int MaxHistoryEntries { get; set; }
        public int MaxHistoryDays { get; set; }
        public List<string> IgnoredProcesses { get; set; }
        public string SortMode { get; set; }
        public bool SortDescending { get; set; }
        public bool SendToEnabled { get; set; }
        public bool ShowHistoryAfterSendTo { get; set; }
        public string GroupFilter { get; set; }
        public string DuplicateMode { get; set; }
        public bool AutoGroupByApp { get; set; }
        public bool AutoRemoveUrlTracking { get; set; }
        public bool RunAtStartup { get; set; }
        public string UpdateCheckFrequency { get; set; }
        public bool InstallUpdatesSilently { get; set; }
        public bool DatabaseEncryptionEnabled { get; set; }
        public string ProtectedDatabasePassword { get; set; }

        public AppSettings()
        {
            ShowHistoryHotkey = "Ctrl+Alt+\\";
            ToggleActiveHotkey = "Ctrl+Alt+`";
            RemoveDuplicates = true;
            SoundsEnabled = true;
            SaveListPosition = true;
            Active = true;
            DatabasePath = string.Empty;
            LastSelectedIndex = -1;
            LastSelectedTab = 0;
            LastPreferencesTab = 0;
            MaxHistoryEntries = 1000;
            MaxHistoryDays = 0;
            IgnoredProcesses = new List<string>();
            SortMode = "LastUsed";
            SortDescending = true;
            SendToEnabled = false;
            ShowHistoryAfterSendTo = true;
            GroupFilter = "All";
            DuplicateMode = "MoveToTop";
            AutoGroupByApp = true;
            AutoRemoveUrlTracking = false;
            RunAtStartup = false;
            UpdateCheckFrequency = "Never";
            InstallUpdatesSilently = false;
            DatabaseEncryptionEnabled = false;
            ProtectedDatabasePassword = string.Empty;
        }
    }

    public sealed class ClipboardEventSummary
    {
        public DateTime CapturedAt { get; set; }
        public string Source { get; set; }
        public string Operation { get; set; }
        public bool ContainsText { get; set; }
        public int FileCount { get; set; }
        public List<string> Files { get; set; }
        public List<string> Formats { get; set; }

        public ClipboardEventSummary()
        {
            Source = string.Empty;
            Operation = string.Empty;
            Files = new List<string>();
            Formats = new List<string>();
        }
    }

    internal static class TimeUtil
    {
        private static readonly DateTime UnixEpoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);

        public static long NowUnixMs()
        {
            return ToUnixMs(DateTime.UtcNow);
        }

        public static long ToUnixMs(DateTime value)
        {
            return (long)(value.ToUniversalTime() - UnixEpoch).TotalMilliseconds;
        }

        public static DateTime FromUnixMs(long value)
        {
            return UnixEpoch.AddMilliseconds(value).ToLocalTime();
        }
    }

    internal static class ClipmanClipboardData
    {
        public const string EntriesFormat = "Clipman.Entries.Json";
        private static readonly JavaScriptSerializer Serializer = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };

        public static string SerializeEntries(IEnumerable<ClipEntry> entries)
        {
            var safeEntries = (entries ?? Enumerable.Empty<ClipEntry>())
                .Where(e => e != null && !string.IsNullOrEmpty(e.Text))
                .Select(e => new ClipEntry
                {
                    Id = e.Id,
                    Text = e.Text,
                    Name = e.Name,
                    Group = e.Group,
                    SourceMachine = e.SourceMachine,
                    CreatedUnixMs = e.CreatedUnixMs,
                    LastUsedUnixMs = e.LastUsedUnixMs,
                    Pinned = e.Pinned,
                    ManualOrder = e.ManualOrder
                })
                .ToList();
            return Serializer.Serialize(safeEntries);
        }

        public static List<ClipEntry> DeserializeEntries(object value)
        {
            var text = value as string;
            if (string.IsNullOrEmpty(text)) return new List<ClipEntry>();
            try
            {
                return Serializer.Deserialize<List<ClipEntry>>(text) ?? new List<ClipEntry>();
            }
            catch
            {
                return new List<ClipEntry>();
            }
        }
    }
}
