using System;
using System.Collections.Generic;
using System.Linq;
using System.Web.Script.Serialization;
using System.Windows.Forms;

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
        public bool IsTemplate { get; set; }
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
        public List<DeletedClipEntry> DeletedEntries { get; set; }

        public ClipDatabase()
        {
            Version = 1;
            UpdatedUnixMs = TimeUtil.NowUnixMs();
            Entries = new List<ClipEntry>();
            DeletedEntries = new List<DeletedClipEntry>();
        }
    }

    public sealed class SecretEntry
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public string Value { get; set; }
        public string Hotkey { get; set; }
        public long CreatedUnixMs { get; set; }
        public long UpdatedUnixMs { get; set; }

        public SecretEntry()
        {
            Id = Guid.NewGuid().ToString("N");
            Name = string.Empty;
            Value = string.Empty;
            Hotkey = string.Empty;
            CreatedUnixMs = TimeUtil.NowUnixMs();
            UpdatedUnixMs = CreatedUnixMs;
        }
    }

    public sealed class SecretDatabase
    {
        public int Version { get; set; }
        public long UpdatedUnixMs { get; set; }
        public List<SecretEntry> Entries { get; set; }

        public SecretDatabase()
        {
            Version = 1;
            UpdatedUnixMs = TimeUtil.NowUnixMs();
            Entries = new List<SecretEntry>();
        }
    }

    public sealed class DeletedClipEntry
    {
        public string Id { get; set; }
        public string TextHash { get; set; }
        public long DeletedUnixMs { get; set; }
        public string SourceMachine { get; set; }

        public DeletedClipEntry()
        {
            Id = string.Empty;
            TextHash = string.Empty;
            DeletedUnixMs = TimeUtil.NowUnixMs();
            SourceMachine = string.Empty;
        }
    }

    public sealed class ServerSyncStatus
    {
        public bool Enabled { get; set; }
        public bool Configured { get; set; }
        public string Revision { get; set; }
        public long LastPollUnixMs { get; set; }
        public long LastSuccessUnixMs { get; set; }
        public long LastUploadUnixMs { get; set; }
        public long NextPollUnixMs { get; set; }
        public int ConsecutiveFailures { get; set; }
        public string LastError { get; set; }

        public ServerSyncStatus()
        {
            Revision = string.Empty;
            LastError = string.Empty;
        }
    }

    public sealed class ShortcutButton : Button
    {
        public string ShortcutText { get; set; }
        public Keys ShortcutKeys { get; set; }

        public ShortcutButton()
        {
            AccessibleRole = AccessibleRole.PushButton;
        }

        protected override AccessibleObject CreateAccessibilityInstance()
        {
            return new ShortcutButtonAccessibleObject(this);
        }

        private sealed class ShortcutButtonAccessibleObject : Control.ControlAccessibleObject
        {
            private readonly ShortcutButton owner;

            public ShortcutButtonAccessibleObject(ShortcutButton owner)
                : base(owner)
            {
                this.owner = owner;
            }

            public override string KeyboardShortcut
            {
                get
                {
                    return string.IsNullOrWhiteSpace(owner.ShortcutText)
                        ? base.KeyboardShortcut
                        : owner.ShortcutText;
                }
            }
        }
    }

    public sealed class FileClipboardDatabase
    {
        public int Version { get; set; }
        public long UpdatedUnixMs { get; set; }
        public List<ClipboardEventSummary> Events { get; set; }

        public FileClipboardDatabase()
        {
            Version = 1;
            UpdatedUnixMs = TimeUtil.NowUnixMs();
            Events = new List<ClipboardEventSummary>();
        }
    }

    public sealed class AppSettings
    {
        public string ShowHistoryHotkey { get; set; }
        public string ToggleActiveHotkey { get; set; }
        public List<QuickCopyBinding> QuickCopyHotkeys { get; set; }
        public bool AutoCopyLatestRemoteText { get; set; }
        public bool PasteAfterEnter { get; set; }
        public bool DynamicHistoryMode { get; set; }
        public bool RemoveDuplicates { get; set; }
        public bool SoundsEnabled { get; set; }
        public bool SaveListPosition { get; set; }
        public bool LinksHistoryEnabled { get; set; }
        public bool Active { get; set; }
        public string DatabasePath { get; set; }
        public bool UseDefaultDatabasePath { get; set; }
        public string StorageMode { get; set; }
        public string ServerUrl { get; set; }
        [ScriptIgnore]
        public string ServerToken { get; set; }
        public string ProtectedServerToken { get; set; }
        public int LastSelectedIndex { get; set; }
        public int LastSelectedTab { get; set; }
        public string LastSelectedHistoryTab { get; set; }
        public int LastPreferencesTab { get; set; }
        public int MaxHistoryEntries { get; set; }
        public int MaxHistoryDays { get; set; }
        public List<string> IgnoredProcesses { get; set; }
        public string SortMode { get; set; }
        public bool SortDescending { get; set; }
        public string FileHistorySortMode { get; set; }
        public bool FileHistorySortDescending { get; set; }
        public bool SendToEnabled { get; set; }
        public bool ShowHistoryAfterSendTo { get; set; }
        public string GroupFilter { get; set; }
        public string DuplicateMode { get; set; }
        public bool AutoGroupByApp { get; set; }
        public bool AutoRemoveUrlTracking { get; set; }
        public bool RunAtStartup { get; set; }
        public bool CaptureClipboardOnStartup { get; set; }
        public string UpdateCheckFrequency { get; set; }
        public bool InstallUpdatesSilently { get; set; }
        public bool DatabaseEncryptionEnabled { get; set; }
        public bool RememberDatabasePassword { get; set; }
        public string ProtectedDatabasePassword { get; set; }
        [ScriptIgnore]
        public string PlainDatabasePassword { get; set; }
        [ScriptIgnore]
        public bool PasswordClearRequested { get; set; }
        public bool AutoRemoveUnavailableFileHistoryEvents { get; set; }
        public int DiagnosticsFileHistoryLimit { get; set; }
        public string SensitiveDataMode { get; set; }
        public List<string> SensitiveDataPresetIds { get; set; }

        public AppSettings()
        {
            ShowHistoryHotkey = "Ctrl+Alt+\\";
            ToggleActiveHotkey = "Ctrl+Alt+`";
            QuickCopyHotkeys = new List<QuickCopyBinding>();
            AutoCopyLatestRemoteText = false;
            PasteAfterEnter = false;
            DynamicHistoryMode = false;
            RemoveDuplicates = true;
            SoundsEnabled = true;
            SaveListPosition = true;
            LinksHistoryEnabled = false;
            Active = true;
            DatabasePath = string.Empty;
            UseDefaultDatabasePath = true;
            StorageMode = "File";
            ServerUrl = string.Empty;
            ServerToken = string.Empty;
            ProtectedServerToken = string.Empty;
            LastSelectedIndex = -1;
            LastSelectedTab = 0;
            LastSelectedHistoryTab = HistoryTabs.Text;
            LastPreferencesTab = 0;
            MaxHistoryEntries = 1000;
            MaxHistoryDays = 0;
            IgnoredProcesses = new List<string>();
            SortMode = "LastUsed";
            SortDescending = true;
            FileHistorySortMode = "Manual";
            FileHistorySortDescending = false;
            SendToEnabled = false;
            ShowHistoryAfterSendTo = true;
            GroupFilter = "All";
            DuplicateMode = "MoveToTop";
            AutoGroupByApp = true;
            AutoRemoveUrlTracking = false;
            RunAtStartup = false;
            CaptureClipboardOnStartup = false;
            UpdateCheckFrequency = "Never";
            InstallUpdatesSilently = false;
            DatabaseEncryptionEnabled = false;
            RememberDatabasePassword = false;
            ProtectedDatabasePassword = string.Empty;
            PlainDatabasePassword = string.Empty;
            AutoRemoveUnavailableFileHistoryEvents = false;
            DiagnosticsFileHistoryLimit = 20;
            SensitiveDataMode = "Off";
            SensitiveDataPresetIds = new List<string>();
        }
    }

    public sealed class QuickCopyBinding
    {
        public string EntryId { get; set; }
        public string Hotkey { get; set; }
        public string Mode { get; set; }

        public QuickCopyBinding()
        {
            EntryId = string.Empty;
            Hotkey = string.Empty;
            Mode = QuickPasteModes.PasteRestore;
        }
    }

    public static class QuickPasteModes
    {
        public const string PasteRestore = "PasteRestore";
        public const string PasteKeep = "PasteKeep";
        public const string CopyOnly = "CopyOnly";

        public static string Normalize(string mode)
        {
            if (string.Equals(mode, PasteKeep, StringComparison.OrdinalIgnoreCase)) return PasteKeep;
            if (string.Equals(mode, CopyOnly, StringComparison.OrdinalIgnoreCase)) return CopyOnly;
            return PasteRestore;
        }
    }

    public sealed class ClipboardEventSummary
    {
        public string Id { get; set; }
        public DateTime CapturedAt { get; set; }
        public string Source { get; set; }
        public string Operation { get; set; }
        public string SourceMachine { get; set; }
        public bool ContainsText { get; set; }
        public int FileCount { get; set; }
        public List<string> Files { get; set; }
        public List<string> Formats { get; set; }
        public bool Pinned { get; set; }
        public long ManualOrder { get; set; }

        public ClipboardEventSummary()
        {
            Id = Guid.NewGuid().ToString("N");
            Source = string.Empty;
            Operation = string.Empty;
            SourceMachine = string.Empty;
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
                    IsTemplate = e.IsTemplate,
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
