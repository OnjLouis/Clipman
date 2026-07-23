using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace Clipman
{
    internal static class SyncConflictResolver
    {
        public static void ResolveSettingsConflicts(string settingsPath)
        {
            try
            {
                var conflicts = FindConflictSiblings(settingsPath).ToList();
                if (conflicts.Count == 0) return;

                var allFiles = new List<string>();
                if (File.Exists(settingsPath)) allFiles.Add(settingsPath);
                allFiles.AddRange(conflicts);
                var newest = allFiles
                    .Select(path => new FileInfo(path))
                    .Where(info => info.Exists)
                    .OrderByDescending(info => info.LastWriteTimeUtc)
                    .FirstOrDefault();
                if (newest == null) return;

                Directory.CreateDirectory(Path.GetDirectoryName(settingsPath));
                if (!string.Equals(newest.FullName, settingsPath, StringComparison.OrdinalIgnoreCase))
                {
                    File.Copy(newest.FullName, settingsPath, true);
                }

                DeleteFiles(conflicts);
            }
            catch
            {
            }
        }

        public static void ResolveDatabaseConflicts(string databasePath)
        {
            ResolveDatabaseConflicts(databasePath, string.Empty);
        }

        public static void ResolveDatabaseConflicts(string databasePath, string password)
        {
            try
            {
                var conflicts = FindConflictSiblings(databasePath).ToList();
                if (conflicts.Count == 0) return;

                var merged = new ClipDatabase();
                if (File.Exists(databasePath))
                {
                    MergeInto(merged, ClipDatabaseFile.Load(databasePath, password));
                }

                foreach (var conflict in conflicts)
                {
                    MergeInto(merged, ClipDatabaseFile.Load(conflict, password));
                }

                NormalizeMergedDatabase(merged);
                ClipDatabaseFile.SaveAtomic(databasePath, merged, password);
                DeleteFiles(conflicts);
            }
            catch
            {
            }
        }

        public static IEnumerable<string> FindConflictSiblings(string canonicalPath)
        {
            if (string.IsNullOrWhiteSpace(canonicalPath)) yield break;
            var directory = Path.GetDirectoryName(canonicalPath);
            var fileName = Path.GetFileName(canonicalPath);
            if (string.IsNullOrWhiteSpace(directory) || string.IsNullOrWhiteSpace(fileName) || !Directory.Exists(directory))
            {
                yield break;
            }

            var baseName = Path.GetFileNameWithoutExtension(fileName);
            var extension = Path.GetExtension(fileName);
            foreach (var file in Directory.GetFiles(directory, "*" + extension))
            {
                if (string.Equals(file, canonicalPath, StringComparison.OrdinalIgnoreCase)) continue;
                if (IsConflictNameFor(file, baseName, extension))
                {
                    yield return file;
                }
            }
        }

        private static bool IsConflictNameFor(string path, string baseName, string extension)
        {
            if (!string.Equals(Path.GetExtension(path), extension, StringComparison.OrdinalIgnoreCase)) return false;
            var name = Path.GetFileNameWithoutExtension(path);
            if (string.IsNullOrWhiteSpace(name) || !name.StartsWith(baseName, StringComparison.OrdinalIgnoreCase)) return false;

            var suffix = name.Substring(baseName.Length).Trim();
            if (suffix.Length == 0) return false;
            var lower = suffix.ToLowerInvariant();

            if (lower.Contains("conflicted copy")) return true;
            if (lower.Contains("[conflict]")) return true;
            if (lower.Contains(" conflict")) return true;
            if (lower.StartsWith("_conf(")) return true;
            if (lower.StartsWith(" _conf(")) return true;

            return LooksLikeOneDriveComputerSuffix(suffix);
        }

        private static bool LooksLikeOneDriveComputerSuffix(string suffix)
        {
            var value = suffix.Trim();
            if (value.Length < 3 || value.Length > 80) return false;
            if (!(value.StartsWith("-", StringComparison.Ordinal) ||
                  value.StartsWith("(", StringComparison.Ordinal) ||
                  value.StartsWith(" ", StringComparison.Ordinal)))
            {
                return false;
            }

            value = value.Trim(' ', '-', '(', ')');
            if (value.Length < 2 || value.Length > 64) return false;
            return value.All(ch => char.IsLetterOrDigit(ch) || ch == '-' || ch == '_');
        }

        public static void MergeInto(ClipDatabase target, ClipDatabase source)
        {
            if (target == null || source == null || source.Entries == null) return;
            if (target.Entries == null) target.Entries = new List<ClipEntry>();
            if (target.DeletedEntries == null) target.DeletedEntries = new List<DeletedClipEntry>();
            MergeDeletedEntries(target, source);
            ApplyDeletedEntries(target);
            foreach (var entry in source.Entries.Where(e => e != null && !string.IsNullOrEmpty(e.Text)))
            {
                if (IsDeleted(target, entry)) continue;
                var existing = target.Entries.FirstOrDefault(e =>
                    !string.IsNullOrWhiteSpace(entry.Id) &&
                    string.Equals(e.Id, entry.Id, StringComparison.OrdinalIgnoreCase));
                if (existing == null)
                {
                    existing = target.Entries.FirstOrDefault(e => string.Equals(e.Text, entry.Text, StringComparison.Ordinal));
                }

                if (existing == null)
                {
                    target.Entries.Add(Clone(entry));
                    continue;
                }

                MergeEntry(existing, entry);
            }
            ApplyDeletedEntries(target);
        }

        private static void MergeEntry(ClipEntry existing, ClipEntry incoming)
        {
            var incomingWins = incoming.LastUsedUnixMs >= existing.LastUsedUnixMs;
            var incomingCreatedWins = incoming.CreatedUnixMs > existing.CreatedUnixMs;
            if (incoming.LastUsedUnixMs > existing.LastUsedUnixMs) existing.LastUsedUnixMs = incoming.LastUsedUnixMs;
            if (incoming.CreatedUnixMs > 0 &&
                (existing.CreatedUnixMs == 0 ||
                 incomingCreatedWins ||
                 (!incomingWins && incoming.CreatedUnixMs < existing.CreatedUnixMs)))
            {
                existing.CreatedUnixMs = incoming.CreatedUnixMs;
            }
            if (!string.IsNullOrWhiteSpace(incoming.Name) && incomingWins) existing.Name = incoming.Name.Trim();
            if (!string.IsNullOrWhiteSpace(incoming.Group) && incomingWins) existing.Group = incoming.Group.Trim();
            if (!string.IsNullOrWhiteSpace(incoming.SourceMachine) && (incomingWins || incomingCreatedWins)) existing.SourceMachine = incoming.SourceMachine.Trim();
            existing.Pinned = existing.Pinned || incoming.Pinned;
            existing.IsTemplate = existing.IsTemplate || incoming.IsTemplate;
            if (existing.ManualOrder <= 0 || (incoming.ManualOrder > 0 && incoming.ManualOrder < existing.ManualOrder)) existing.ManualOrder = incoming.ManualOrder;
        }

        private static void NormalizeMergedDatabase(ClipDatabase database)
        {
            if (database.Entries == null) database.Entries = new List<ClipEntry>();
            database.Version = Math.Max(1, database.Version);
            database.UpdatedUnixMs = TimeUtil.NowUnixMs();
            NormalizeDeletedEntries(database);
            ApplyDeletedEntries(database);

            var next = 1L;
            foreach (var entry in database.Entries
                .OrderBy(e => e.ManualOrder <= 0 ? long.MaxValue : e.ManualOrder)
                .ThenBy(e => e.CreatedUnixMs))
            {
                if (string.IsNullOrWhiteSpace(entry.Id)) entry.Id = Guid.NewGuid().ToString("N");
                if (entry.Name == null) entry.Name = string.Empty;
                if (entry.Group == null) entry.Group = string.Empty;
                if (entry.SourceMachine == null) entry.SourceMachine = string.Empty;
                if (entry.CreatedUnixMs == 0) entry.CreatedUnixMs = TimeUtil.NowUnixMs();
                if (entry.LastUsedUnixMs == 0) entry.LastUsedUnixMs = entry.CreatedUnixMs;
                entry.ManualOrder = next++;
            }
        }

        private static ClipEntry Clone(ClipEntry entry)
        {
            return new ClipEntry
            {
                Id = string.IsNullOrWhiteSpace(entry.Id) ? Guid.NewGuid().ToString("N") : entry.Id,
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

        private static void MergeDeletedEntries(ClipDatabase target, ClipDatabase source)
        {
            NormalizeDeletedEntries(target);
            if (source.DeletedEntries == null) return;
            foreach (var marker in source.DeletedEntries.Where(d => d != null && !string.IsNullOrWhiteSpace(d.Id)))
            {
                var existing = target.DeletedEntries.FirstOrDefault(d =>
                    string.Equals(d.Id, marker.Id, StringComparison.OrdinalIgnoreCase));
                if (existing == null)
                {
                    target.DeletedEntries.Add(Clone(marker));
                }
                else if (marker.DeletedUnixMs > existing.DeletedUnixMs)
                {
                    existing.DeletedUnixMs = marker.DeletedUnixMs;
                    existing.TextHash = marker.TextHash ?? string.Empty;
                    existing.SourceMachine = marker.SourceMachine ?? string.Empty;
                }
                else if (string.IsNullOrWhiteSpace(existing.TextHash) && !string.IsNullOrWhiteSpace(marker.TextHash))
                {
                    existing.TextHash = marker.TextHash;
                }
            }
            NormalizeDeletedEntries(target);
        }

        private static void NormalizeDeletedEntries(ClipDatabase database)
        {
            if (database.DeletedEntries == null)
            {
                database.DeletedEntries = new List<DeletedClipEntry>();
                return;
            }
            var now = TimeUtil.NowUnixMs();
            var cutoff = now - (long)TimeSpan.FromDays(90).TotalMilliseconds;
            foreach (var marker in database.DeletedEntries.Where(d => d != null && d.DeletedUnixMs <= 0))
            {
                marker.DeletedUnixMs = now;
            }
            database.DeletedEntries = database.DeletedEntries
                .Where(d => d != null && !string.IsNullOrWhiteSpace(d.Id) && d.DeletedUnixMs >= cutoff)
                .GroupBy(d => d.Id, StringComparer.OrdinalIgnoreCase)
                .Select(group => group.OrderByDescending(d => d.DeletedUnixMs).First())
                .ToList();
        }

        private static void ApplyDeletedEntries(ClipDatabase database)
        {
            if (database.Entries == null || database.DeletedEntries == null || database.DeletedEntries.Count == 0) return;
            database.Entries.RemoveAll(entry => IsDeleted(database, entry));
        }

        private static bool IsDeleted(ClipDatabase database, ClipEntry entry)
        {
            if (entry == null || database.DeletedEntries == null) return false;
            var entryChangedUnixMs = Math.Max(entry.CreatedUnixMs, entry.LastUsedUnixMs);
            var hash = ComputeTextHash(entry.Text);
            return database.DeletedEntries.Any(marker =>
                string.Equals(marker.Id, entry.Id, StringComparison.OrdinalIgnoreCase) ||
                (!string.IsNullOrWhiteSpace(marker.TextHash) &&
                 string.Equals(marker.TextHash, hash, StringComparison.OrdinalIgnoreCase) &&
                 (marker.DeletedUnixMs <= 0 || entryChangedUnixMs <= marker.DeletedUnixMs)));
        }

        private static string ComputeTextHash(string text)
        {
            using (var sha = SHA256.Create())
            {
                return string.Concat(sha.ComputeHash(Encoding.UTF8.GetBytes(text ?? string.Empty)).Select(b => b.ToString("x2")));
            }
        }

        private static DeletedClipEntry Clone(DeletedClipEntry marker)
        {
            return new DeletedClipEntry
            {
                Id = marker.Id ?? string.Empty,
                TextHash = marker.TextHash ?? string.Empty,
                DeletedUnixMs = marker.DeletedUnixMs,
                SourceMachine = marker.SourceMachine ?? string.Empty
            };
        }

        private static void DeleteFiles(IEnumerable<string> paths)
        {
            foreach (var path in paths)
            {
                try
                {
                    if (File.Exists(path))
                    {
                        File.Delete(path);
                    }
                }
                catch
                {
                }
            }
        }
    }
}
