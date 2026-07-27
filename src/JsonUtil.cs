using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace Clipman
{
    internal static class JsonUtil
    {
        private static readonly JavaScriptSerializer Serializer = new JavaScriptSerializer
        {
            MaxJsonLength = int.MaxValue,
            RecursionLimit = 100
        };

        public static T Load<T>(string path) where T : new()
        {
            if (!File.Exists(path))
            {
                return new T();
            }

            var text = File.ReadAllText(path, Encoding.UTF8);
            if (string.IsNullOrWhiteSpace(text))
            {
                return new T();
            }

            var value = Serializer.Deserialize<T>(text);
            if (value == null)
            {
                return new T();
            }
            return value;
        }

        public static void SaveAtomic<T>(string path, T value)
        {
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }

            var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            var json = Serializer.Serialize(value);
            try
            {
                File.WriteAllText(temp, PrettyPrint(json), Encoding.UTF8);
                ReplaceTempWithRetry(temp, path);
            }
            finally
            {
                try
                {
                    if (File.Exists(temp)) File.Delete(temp);
                }
                catch
                {
                }
            }
        }

        private static void ReplaceTempWithRetry(string temp, string path)
        {
            Exception last = null;
            var accessDenied = false;
            for (var attempt = 0; attempt < 8; attempt++)
            {
                try
                {
                    if (File.Exists(path))
                    {
                        File.Replace(temp, path, null);
                    }
                    else
                    {
                        File.Move(temp, path);
                    }
                    return;
                }
                catch (IOException ex)
                {
                    last = ex;
                }
                catch (UnauthorizedAccessException ex)
                {
                    last = ex;
                    accessDenied = true;
                }

                if (attempt < 7)
                {
                    Thread.Sleep(50 * (attempt + 1));
                }
            }

            if (!accessDenied && File.Exists(path))
            {
                try
                {
                    ReplaceWithVerifiedCopyFallback(temp, path);
                    return;
                }
                catch (Exception ex)
                {
                    last = new IOException("Clipman could not use the verified remote-filesystem fallback for " + path + ".", ex);
                }
            }

            throw new IOException("Clipman could not replace " + path + " after waiting for the file to become available.", last);
        }

        internal static void ReplaceWithVerifiedCopyFallback(string temp, string path)
        {
            if (string.IsNullOrWhiteSpace(temp)) throw new ArgumentException("A temporary file path is required.", "temp");
            if (string.IsNullOrWhiteSpace(path)) throw new ArgumentException("A destination file path is required.", "path");
            if (!File.Exists(temp)) throw new FileNotFoundException("The completed temporary settings file was not found.", temp);
            if (!File.Exists(path)) throw new FileNotFoundException("The existing settings file was not found.", path);

            var expected = File.ReadAllBytes(temp);
            var backup = path + "." + Guid.NewGuid().ToString("N") + ".fallback-backup";
            var mayDeleteBackup = false;
            try
            {
                File.Copy(path, backup, true);
                File.Copy(temp, path, true);
                if (!BytesEqual(expected, File.ReadAllBytes(path)))
                {
                    throw new IOException("The replacement settings file did not match the completed temporary file.");
                }
                mayDeleteBackup = true;
            }
            catch (Exception writeException)
            {
                try
                {
                    if (File.Exists(backup))
                    {
                        var original = File.ReadAllBytes(backup);
                        File.Copy(backup, path, true);
                        if (!BytesEqual(original, File.ReadAllBytes(path)))
                        {
                            throw new IOException("The restored settings file did not match its backup.");
                        }
                        mayDeleteBackup = true;
                    }
                }
                catch (Exception restoreException)
                {
                    throw new IOException(
                        "Clipman could not replace the settings file and could not restore its backup. The backup remains at " + backup + ".",
                        new AggregateException(writeException, restoreException));
                }
                throw new IOException("Clipman could not replace the settings file. The previous file was restored.", writeException);
            }
            finally
            {
                if (mayDeleteBackup)
                {
                    try { if (File.Exists(backup)) File.Delete(backup); }
                    catch { }
                }
            }
        }

        private static bool BytesEqual(byte[] left, byte[] right)
        {
            if (ReferenceEquals(left, right)) return true;
            if (left == null || right == null || left.Length != right.Length) return false;
            for (var index = 0; index < left.Length; index++)
            {
                if (left[index] != right[index]) return false;
            }
            return true;
        }

        public static string SerializePretty<T>(T value)
        {
            return PrettyPrint(Serializer.Serialize(value));
        }

        public static T Deserialize<T>(string text) where T : new()
        {
            if (string.IsNullOrWhiteSpace(text))
            {
                return new T();
            }

            var value = Serializer.Deserialize<T>(text);
            return value == null ? new T() : value;
        }

        private static string PrettyPrint(string json)
        {
            var output = new StringBuilder();
            var indent = 0;
            var quoted = false;
            for (var i = 0; i < json.Length; i++)
            {
                var ch = json[i];
                if (ch == '"' && !IsEscaped(json, i))
                {
                    quoted = !quoted;
                }

                if (quoted)
                {
                    output.Append(ch);
                    continue;
                }

                switch (ch)
                {
                    case '{':
                    case '[':
                        output.Append(ch).AppendLine();
                        indent++;
                        output.Append(new string(' ', indent * 2));
                        break;
                    case '}':
                    case ']':
                        output.AppendLine();
                        indent--;
                        output.Append(new string(' ', indent * 2)).Append(ch);
                        break;
                    case ',':
                        output.Append(ch).AppendLine();
                        output.Append(new string(' ', indent * 2));
                        break;
                    case ':':
                        output.Append(": ");
                        break;
                    default:
                        output.Append(ch);
                        break;
                }
            }

            return output.ToString();
        }

        private static bool IsEscaped(string text, int index)
        {
            var slashCount = 0;
            for (var i = index - 1; i >= 0 && text[i] == '\\'; i--)
            {
                slashCount++;
            }
            return slashCount % 2 == 1;
        }
    }
}
