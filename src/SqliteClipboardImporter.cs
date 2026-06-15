using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace Clipman
{
    internal static class SqliteClipboardImporter
    {
        private const int SQLITE_OK = 0;
        private const int SQLITE_ROW = 100;
        private const int SQLITE_DONE = 101;
        public static bool LooksLikeSqliteDatabase(string path)
        {
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path)) return false;
            try
            {
                var header = new byte[16];
                using (var stream = File.OpenRead(path))
                {
                    if (stream.Read(header, 0, header.Length) != header.Length) return false;
                }
                return Encoding.ASCII.GetString(header) == "SQLite format 3\0";
            }
            catch
            {
                return false;
            }
        }

        public static List<ClipEntry> LoadEntries(string path)
        {
            using (var db = new SqliteDatabase(path))
            {
                if (db.HasTable("formats") && db.HasTable("items"))
                {
                    return LoadTylerClipmanEntries(db);
                }

                if (db.HasTable("Main") && db.HasColumn("Main", "mText"))
                {
                    return LoadDittoEntries(db);
                }
            }

            throw new InvalidDataException("This SQLite database is not a supported clipboard manager database.");
        }

        private static List<ClipEntry> LoadTylerClipmanEntries(SqliteDatabase db)
        {
            var entries = new List<ClipEntry>();
            const string sql =
                "select i.time, f.data " +
                "from items i join formats f on f.clip_id = i.id " +
                "where f.format = 'CF_UNICODETEXT' " +
                "order by i.time asc, i.id asc";
            db.Query(sql, reader =>
            {
                var created = UnixSecondsToMilliseconds(reader.Int64(0));
                var text = DecodeUnicodeText(reader.Blob(1));
                if (string.IsNullOrWhiteSpace(text)) return;
                entries.Add(new ClipEntry
                {
                    Text = text,
                    Group = "Imported from old Clipman",
                    SourceMachine = CurrentMachineName(),
                    CreatedUnixMs = created,
                    LastUsedUnixMs = created
                });
            });
            return entries;
        }

        private static List<ClipEntry> LoadDittoEntries(SqliteDatabase db)
        {
            var entries = new List<ClipEntry>();
            var timeColumn = db.HasColumn("Main", "lDate") ? "lDate" :
                db.HasColumn("Main", "clipOrder") ? "clipOrder" :
                db.HasColumn("Main", "CRC") ? "CRC" :
                string.Empty;
            var order = timeColumn.Length == 0 ? "rowid" : timeColumn;
            var sql = timeColumn.Length == 0
                ? "select mText from Main order by rowid asc"
                : "select mText, " + timeColumn + " from Main order by " + order + " asc";
            db.Query(sql, reader =>
            {
                var text = reader.String(0);
                if (string.IsNullOrWhiteSpace(text)) return;
                var created = timeColumn.Length == 0 ? TimeUtil.NowUnixMs() : NormalizePotentialUnixTime(reader.Int64(1));
                entries.Add(new ClipEntry
                {
                    Text = text.TrimEnd('\0'),
                    Group = "Imported from Ditto",
                    SourceMachine = CurrentMachineName(),
                    CreatedUnixMs = created,
                    LastUsedUnixMs = created
                });
            });
            return entries;
        }

        private static long NormalizePotentialUnixTime(long value)
        {
            if (value <= 0) return TimeUtil.NowUnixMs();
            if (value > 1000000000000L) return value;
            if (value > 1000000000L) return value * 1000L;
            return TimeUtil.NowUnixMs();
        }

        private static long UnixSecondsToMilliseconds(long seconds)
        {
            return seconds > 0 ? seconds * 1000L : TimeUtil.NowUnixMs();
        }

        private static string DecodeUnicodeText(byte[] data)
        {
            if (data == null || data.Length == 0) return string.Empty;
            return Encoding.Unicode.GetString(data).TrimEnd('\0');
        }

        private static string CurrentMachineName()
        {
            try { return Environment.MachineName; }
            catch { return string.Empty; }
        }

        private sealed class SqliteDatabase : IDisposable
        {
            private IntPtr handle;

            public SqliteDatabase(string path)
            {
                if (sqlite3_open16(path, out handle) != SQLITE_OK)
                {
                    var message = LastError();
                    Close();
                    throw new InvalidDataException("Could not open SQLite database: " + message);
                }
            }

            public bool HasTable(string name)
            {
                var found = false;
                Query("select name from sqlite_master where type='table' and lower(name)=lower(?)", statement =>
                {
                    statement.BindText(1, name);
                }, reader =>
                {
                    found = true;
                });
                return found;
            }

            public bool HasColumn(string table, string column)
            {
                var found = false;
                Query("pragma table_info(" + QuoteIdentifier(table) + ")", reader =>
                {
                    if (string.Equals(reader.String(1), column, StringComparison.OrdinalIgnoreCase))
                    {
                        found = true;
                    }
                });
                return found;
            }

            public void Query(string sql, Action<RowReader> row)
            {
                Query(sql, null, row);
            }

            public void Query(string sql, Action<Statement> bind, Action<RowReader> row)
            {
                using (var statement = Prepare(sql))
                {
                    if (bind != null) bind(statement);
                    while (true)
                    {
                        var result = sqlite3_step(statement.Handle);
                        if (result == SQLITE_ROW)
                        {
                            row(new RowReader(statement.Handle));
                            continue;
                        }
                        if (result == SQLITE_DONE) break;
                        throw new InvalidDataException("SQLite query failed: " + LastError());
                    }
                }
            }

            private Statement Prepare(string sql)
            {
                IntPtr statement;
                var result = sqlite3_prepare16_v2(handle, sql, -1, out statement, IntPtr.Zero);
                if (result != SQLITE_OK)
                {
                    throw new InvalidDataException("SQLite prepare failed: " + LastError());
                }
                return new Statement(statement);
            }

            private string LastError()
            {
                if (handle == IntPtr.Zero) return "unknown error";
                var ptr = sqlite3_errmsg(handle);
                return ptr == IntPtr.Zero ? "unknown error" : Marshal.PtrToStringAnsi(ptr);
            }

            public void Dispose()
            {
                Close();
            }

            private void Close()
            {
                if (handle == IntPtr.Zero) return;
                sqlite3_close(handle);
                handle = IntPtr.Zero;
            }
        }

        private sealed class Statement : IDisposable
        {
            public IntPtr Handle { get; private set; }

            public Statement(IntPtr handle)
            {
                Handle = handle;
            }

            public void BindText(int index, string value)
            {
                var result = sqlite3_bind_text16(Handle, index, value, -1, new IntPtr(-1));
                if (result != SQLITE_OK)
                {
                    throw new InvalidDataException("SQLite parameter bind failed.");
                }
            }

            public void Dispose()
            {
                if (Handle == IntPtr.Zero) return;
                sqlite3_finalize(Handle);
                Handle = IntPtr.Zero;
            }
        }

        private sealed class RowReader
        {
            private readonly IntPtr statement;

            public RowReader(IntPtr statement)
            {
                this.statement = statement;
            }

            public string String(int column)
            {
                var ptr = sqlite3_column_text16(statement, column);
                if (ptr == IntPtr.Zero) return string.Empty;
                var bytes = sqlite3_column_bytes16(statement, column);
                if (bytes <= 0) return string.Empty;
                var data = new byte[bytes];
                Marshal.Copy(ptr, data, 0, bytes);
                return Encoding.Unicode.GetString(data).TrimEnd('\0');
            }

            public long Int64(int column)
            {
                return sqlite3_column_int64(statement, column);
            }

            public byte[] Blob(int column)
            {
                var bytes = sqlite3_column_bytes(statement, column);
                if (bytes <= 0) return new byte[0];
                var ptr = sqlite3_column_blob(statement, column);
                if (ptr == IntPtr.Zero) return new byte[0];
                var data = new byte[bytes];
                Marshal.Copy(ptr, data, 0, bytes);
                return data;
            }
        }

        private static string QuoteIdentifier(string value)
        {
            return "\"" + (value ?? string.Empty).Replace("\"", "\"\"") + "\"";
        }

        [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode)]
        private static extern int sqlite3_open16(string filename, out IntPtr db);

        [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_close(IntPtr db);

        [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_errmsg(IntPtr db);

        [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode, EntryPoint = "sqlite3_prepare16_v2")]
        private static extern int sqlite3_prepare16_v2(IntPtr db, string sql, int nByte, out IntPtr statement, IntPtr tail);

        [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_step(IntPtr statement);

        [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_finalize(IntPtr statement);

        [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode)]
        private static extern int sqlite3_bind_text16(IntPtr statement, int index, string value, int bytes, IntPtr destructor);

        [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_column_text16(IntPtr statement, int column);

        [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_column_bytes16(IntPtr statement, int column);

        [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
        private static extern long sqlite3_column_int64(IntPtr statement, int column);

        [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_column_blob(IntPtr statement, int column);

        [DllImport("sqlite3", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_column_bytes(IntPtr statement, int column);
    }
}
