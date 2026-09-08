using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace Clipman
{
    public sealed class SyncRulesDocument
    {
        public string Clipman { get; set; }
        public int Version { get; set; }
        public bool Enabled { get; set; }
        public long UpdatedUnixMs { get; set; }
        public string UpdatedBy { get; set; }
        public List<SyncChannel> Channels { get; set; }
        public List<SyncDevice> Devices { get; set; }

        public SyncRulesDocument()
        {
            Clipman = "sync-rules";
            Version = 1;
            UpdatedBy = string.Empty;
            Channels = new List<SyncChannel>();
            Devices = new List<SyncDevice>();
        }
    }

    public sealed class SyncChannel
    {
        public string Name { get; set; }
        public SyncRoute Route { get; set; }

        public SyncChannel()
        {
            Name = string.Empty;
            Route = new SyncRoute();
        }
    }

    public sealed class SyncRoute
    {
        public List<string> Groups { get; set; }
        public List<string> SourceDevices { get; set; }
        public string Kind { get; set; }

        public SyncRoute()
        {
            Groups = new List<string>();
            SourceDevices = new List<string>();
            Kind = string.Empty;
        }
    }

    public sealed class SyncDevice
    {
        public string Name { get; set; }
        public List<string> Channels { get; set; }

        public SyncDevice()
        {
            Name = string.Empty;
            Channels = new List<string>();
        }
    }

    /// <summary>
    /// Entries captured on this device that route to a channel it does not subscribe to and whose
    /// write-through failed (spec section 6). They are kept here and retried after the next
    /// successful poll; they never appear in the local view.
    /// </summary>
    public sealed class PendingChannelWrites
    {
        public List<PendingChannelWrite> Channels { get; set; }

        public PendingChannelWrites()
        {
            Channels = new List<PendingChannelWrite>();
        }
    }

    public sealed class PendingChannelWrite
    {
        public string ChannelKey { get; set; }
        public List<ClipEntry> Entries { get; set; }

        public PendingChannelWrite()
        {
            ChannelKey = string.Empty;
            Entries = new List<ClipEntry>();
        }
    }

    public static class SyncRuleEngine
    {
        public const string DocumentKind = "sync-rules";
        public const int CurrentVersion = 1;

        private const string RichTextImagesKind = "RichTextImages";
        private const string DataImagePrefix = "data:image/";

        private static readonly Regex ChannelKeyPattern = new Regex("^[a-z0-9]([a-z0-9 _-]{0,30}[a-z0-9])?$");

        private static readonly HashSet<string> ReservedChannelKeys = new HashSet<string>
        {
            "core", "all", "pinned", "sync-rules"
        };

        public static string ChannelKey(string name)
        {
            var key = (name ?? string.Empty).Trim().ToLowerInvariant();
            return ChannelKeyPattern.IsMatch(key) ? key : string.Empty;
        }

        /// <summary>
        /// The channel key as it appears in shared-folder file names, where spaces become dashes
        /// (sync-rules-spec.md section 2). Two distinct keys that fold to the same storage name
        /// would share one file, so <see cref="Validate"/> rejects such a document.
        /// </summary>
        public static string ChannelStorageName(string channelKey)
        {
            return (channelKey ?? string.Empty).Replace(' ', '-');
        }

        /// <summary>
        /// A document written by a future format version is applied but never rewritten by this
        /// client (spec section 4, Version).
        /// </summary>
        public static bool ReadOnly(SyncRulesDocument doc)
        {
            return doc != null && doc.Version > CurrentVersion;
        }

        /// <summary>
        /// Whether a document read from storage may be applied. A future-version document is
        /// accepted leniently - a client must never fail entirely on a document it only partly
        /// understands - while a current-version document must still pass strict validation.
        /// Channels whose name yields no valid key stay in the document but never route.
        /// </summary>
        public static bool IsUsable(SyncRulesDocument doc)
        {
            if (doc == null) return false;
            if (doc.Clipman != DocumentKind) return false;
            if (ReadOnly(doc)) return true;
            return Validate(doc) == null;
        }

        public static SyncRulesDocument Copy(SyncRulesDocument doc)
        {
            if (doc == null) return null;

            var copy = new SyncRulesDocument
            {
                Clipman = doc.Clipman,
                Version = doc.Version,
                Enabled = doc.Enabled,
                UpdatedUnixMs = doc.UpdatedUnixMs,
                UpdatedBy = doc.UpdatedBy ?? string.Empty
            };

            foreach (var channel in doc.Channels ?? new List<SyncChannel>())
            {
                if (channel == null) continue;
                var route = channel.Route ?? new SyncRoute();
                copy.Channels.Add(new SyncChannel
                {
                    Name = channel.Name ?? string.Empty,
                    Route = new SyncRoute
                    {
                        Groups = new List<string>(route.Groups ?? new List<string>()),
                        SourceDevices = new List<string>(route.SourceDevices ?? new List<string>()),
                        Kind = route.Kind ?? string.Empty
                    }
                });
            }

            foreach (var device in doc.Devices ?? new List<SyncDevice>())
            {
                if (device == null) continue;
                copy.Devices.Add(new SyncDevice
                {
                    Name = device.Name ?? string.Empty,
                    Channels = new List<string>(device.Channels ?? new List<string>())
                });
            }

            return copy;
        }

        public static string Validate(SyncRulesDocument doc)
        {
            if (doc == null) return "The sync rules document is missing.";
            if (doc.Clipman != DocumentKind) return "The sync rules document has an unrecognized format.";

            var channels = doc.Channels ?? new List<SyncChannel>();
            var knownKeys = new HashSet<string>();
            var storageNames = new HashSet<string>();
            foreach (var channel in channels)
            {
                if (channel == null) return "A sync channel entry is missing.";

                var key = ChannelKey(channel.Name);
                if (key.Length == 0) return "Channel name \"" + (channel.Name ?? string.Empty) + "\" is not valid.";
                if (ReservedChannelKeys.Contains(key)) return "Channel name \"" + channel.Name + "\" is reserved.";
                if (!knownKeys.Add(key)) return "Channel name \"" + channel.Name + "\" is not unique.";
                if (!storageNames.Add(ChannelStorageName(key)))
                {
                    return "Channel name \"" + channel.Name + "\" would share a storage file with another channel.";
                }

                var route = channel.Route;
                var hasGroups = route != null && route.Groups != null && route.Groups.Count > 0;
                var hasSourceDevices = route != null && route.SourceDevices != null && route.SourceDevices.Count > 0;
                var kind = route != null ? (route.Kind ?? string.Empty) : string.Empty;
                if (!hasGroups && !hasSourceDevices && kind.Length == 0)
                {
                    return "Channel \"" + channel.Name + "\" has no routing condition.";
                }
                if (kind.Length > 0 && kind != RichTextImagesKind)
                {
                    return "Channel \"" + channel.Name + "\" has an unrecognized route kind.";
                }
            }

            var devices = doc.Devices ?? new List<SyncDevice>();
            foreach (var device in devices)
            {
                if (device == null) return "A device entry is missing.";

                var channelList = device.Channels ?? new List<string>();
                if (channelList.Count == 1 && (channelList[0] ?? string.Empty).Trim() == "*") continue;

                foreach (var channelKey in channelList)
                {
                    var normalized = (channelKey ?? string.Empty).Trim().ToLowerInvariant();
                    if (!knownKeys.Contains(normalized))
                    {
                        return "Device \"" + device.Name + "\" references unknown channel \"" + channelKey + "\".";
                    }
                }
            }

            return null;
        }

        public static string RouteEntry(SyncRulesDocument doc, ClipEntry entry)
        {
            if (doc == null || !doc.Enabled || entry == null) return string.Empty;

            var channels = doc.Channels ?? new List<SyncChannel>();
            foreach (var channel in channels)
            {
                if (channel == null) continue;
                var key = ChannelKey(channel.Name);
                if (key.Length == 0) continue;
                if (RouteMatches(channel.Route, entry)) return key;
            }

            return string.Empty;
        }

        public static List<string> SubscribedChannels(SyncRulesDocument doc, string deviceName)
        {
            if (doc == null || !doc.Enabled) return null;

            var normalizedName = (deviceName ?? string.Empty).Trim().ToLowerInvariant();
            SyncDevice match = null;
            var devices = doc.Devices ?? new List<SyncDevice>();
            foreach (var device in devices)
            {
                if (device == null) continue;
                if ((device.Name ?? string.Empty).Trim().ToLowerInvariant() == normalizedName)
                {
                    match = device;
                    break;
                }
            }
            if (match == null) return null;

            var allKeys = AllChannelKeys(doc);
            var channelList = match.Channels ?? new List<string>();
            if (channelList.Count == 1 && (channelList[0] ?? string.Empty).Trim() == "*")
            {
                return allKeys;
            }

            var result = new List<string>();
            foreach (var channelKey in channelList)
            {
                var normalized = (channelKey ?? string.Empty).Trim().ToLowerInvariant();
                if (allKeys.Contains(normalized) && !result.Contains(normalized)) result.Add(normalized);
            }
            return result;
        }

        public static SyncRulesDocument MergeDocuments(SyncRulesDocument local, SyncRulesDocument remote)
        {
            if (local == null) return remote;
            if (remote == null) return local;
            if (remote.UpdatedUnixMs > local.UpdatedUnixMs) return remote;
            if (remote.UpdatedUnixMs < local.UpdatedUnixMs) return local;

            var comparison = string.CompareOrdinal(remote.UpdatedBy ?? string.Empty, local.UpdatedBy ?? string.Empty);
            return comparison > 0 ? remote : local;
        }

        private static bool RouteMatches(SyncRoute route, ClipEntry entry)
        {
            if (route == null) return false;

            var hasCondition = false;

            if (route.Groups != null && route.Groups.Count > 0)
            {
                hasCondition = true;
                if (!ContainsNormalized(route.Groups, entry.Group)) return false;
            }

            if (route.SourceDevices != null && route.SourceDevices.Count > 0)
            {
                hasCondition = true;
                if (!ContainsNormalized(route.SourceDevices, entry.SourceMachine)) return false;
            }

            var kind = route.Kind ?? string.Empty;
            if (kind.Length > 0)
            {
                hasCondition = true;
                if (!MatchesKind(kind, entry)) return false;
            }

            return hasCondition;
        }

        private static bool MatchesKind(string kind, ClipEntry entry)
        {
            if (kind != RichTextImagesKind) return false;

            var richText = entry.RichText;
            if (richText == null) return false;

            var html = richText.HtmlFragment;
            if (string.IsNullOrWhiteSpace(html)) return false;

            return html.IndexOf(DataImagePrefix, StringComparison.Ordinal) >= 0;
        }

        private static bool ContainsNormalized(List<string> values, string candidate)
        {
            var normalizedCandidate = (candidate ?? string.Empty).Trim().ToLowerInvariant();
            foreach (var value in values)
            {
                if ((value ?? string.Empty).Trim().ToLowerInvariant() == normalizedCandidate) return true;
            }
            return false;
        }

        private static List<string> AllChannelKeys(SyncRulesDocument doc)
        {
            var keys = new List<string>();
            var channels = doc.Channels ?? new List<SyncChannel>();
            foreach (var channel in channels)
            {
                if (channel == null) continue;
                var key = ChannelKey(channel.Name);
                if (key.Length > 0 && !keys.Contains(key)) keys.Add(key);
            }
            return keys;
        }
    }
}
