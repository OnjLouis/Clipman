using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace Clipman
{
    internal sealed class SecretStore
    {
        private readonly object sync = new object();
        private readonly Func<string> passwordProvider;
        private SecretDatabase database = new SecretDatabase();

        public string DatabasePath { get; private set; }

        public SecretStore(string databasePath, Func<string> passwordProvider)
        {
            if (string.IsNullOrWhiteSpace(databasePath))
            {
                throw new ArgumentException("Secret database path cannot be blank.", "databasePath");
            }
            DatabasePath = databasePath;
            this.passwordProvider = passwordProvider ?? (() => string.Empty);
            Load();
        }

        public List<SecretEntry> GetEntries()
        {
            lock (sync)
            {
                return database.Entries
                    .OrderBy(e => e.Name, StringComparer.CurrentCultureIgnoreCase)
                    .Select(Clone)
                    .ToList();
            }
        }

        public SecretEntry GetEntryById(string id)
        {
            if (string.IsNullOrWhiteSpace(id)) return null;
            lock (sync)
            {
                var entry = database.Entries.FirstOrDefault(e => string.Equals(e.Id, id, StringComparison.Ordinal));
                return entry == null ? null : Clone(entry);
            }
        }

        public void SaveEntry(SecretEntry entry)
        {
            if (entry == null) return;
            if (string.IsNullOrEmpty(CurrentPassword()))
            {
                throw new DatabasePasswordRequiredException("Secrets require a history password.");
            }
            var now = TimeUtil.NowUnixMs();
            lock (sync)
            {
                var existing = database.Entries.FirstOrDefault(e => string.Equals(e.Id, entry.Id, StringComparison.Ordinal));
                if (existing == null)
                {
                    existing = new SecretEntry { Id = string.IsNullOrWhiteSpace(entry.Id) ? Guid.NewGuid().ToString("N") : entry.Id };
                    existing.CreatedUnixMs = now;
                    database.Entries.Add(existing);
                }

                existing.Name = (entry.Name ?? string.Empty).Trim();
                existing.Value = entry.Value ?? string.Empty;
                existing.Hotkey = (entry.Hotkey ?? string.Empty).Trim();
                existing.UpdatedUnixMs = now;
                database.UpdatedUnixMs = now;
                SaveLocked();
            }
        }

        public void DeleteEntry(string id)
        {
            if (string.IsNullOrWhiteSpace(id)) return;
            if (string.IsNullOrEmpty(CurrentPassword()))
            {
                throw new DatabasePasswordRequiredException("Secrets require a history password.");
            }
            lock (sync)
            {
                database.Entries.RemoveAll(e => string.Equals(e.Id, id, StringComparison.Ordinal));
                database.UpdatedUnixMs = TimeUtil.NowUnixMs();
                SaveLocked();
            }
        }

        public void ChangeDatabasePassword()
        {
            if (string.IsNullOrEmpty(CurrentPassword()))
            {
                return;
            }
            lock (sync)
            {
                if (!File.Exists(DatabasePath) && database.Entries.Count == 0)
                {
                    return;
                }
                database.UpdatedUnixMs = TimeUtil.NowUnixMs();
                SaveLocked();
            }
        }

        private void Load()
        {
            lock (sync)
            {
                if (!File.Exists(DatabasePath))
                {
                    database = new SecretDatabase();
                    return;
                }
                database = ClipDatabaseFile.Load<SecretDatabase>(DatabasePath, CurrentPassword()) ?? new SecretDatabase();
                if (database.Entries == null) database.Entries = new List<SecretEntry>();
            }
        }

        private void SaveLocked()
        {
            var directory = Path.GetDirectoryName(DatabasePath);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }
            ClipDatabaseFile.SaveAtomic(DatabasePath, database, CurrentPassword());
        }

        private string CurrentPassword()
        {
            return passwordProvider == null ? string.Empty : (passwordProvider() ?? string.Empty);
        }

        private static SecretEntry Clone(SecretEntry entry)
        {
            return new SecretEntry
            {
                Id = entry.Id,
                Name = entry.Name,
                Value = entry.Value,
                Hotkey = entry.Hotkey,
                CreatedUnixMs = entry.CreatedUnixMs,
                UpdatedUnixMs = entry.UpdatedUnixMs
            };
        }
    }
}
