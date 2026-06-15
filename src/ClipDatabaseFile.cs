using System;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace Clipman
{
    internal sealed class DatabasePasswordRequiredException : Exception
    {
        public DatabasePasswordRequiredException(string message) : base(message) { }
    }

    internal static class ClipDatabaseFile
    {
        public const string CompressedExtension = ".clipdb";
        private static readonly byte[] CompressedMagic = Encoding.ASCII.GetBytes("CLIPDB1");
        private static readonly byte[] EncryptedMagic = Encoding.ASCII.GetBytes("CLIPDB2");
        private static readonly object KeyCacheLock = new object();
        private static string cachedKeyId;
        private static KeyPair cachedKeys;

        public static ClipDatabase Load(string path)
        {
            return Load(path, string.Empty);
        }

        public static ClipDatabase Load(string path, string password)
        {
            if (!File.Exists(path))
            {
                return new ClipDatabase();
            }

            string text;
            if (IsEncryptedFile(path))
            {
                text = ReadEncryptedText(path, password);
            }
            else
            {
                text = IsCompressedPath(path) ? ReadCompressedText(path) : File.ReadAllText(path, Encoding.UTF8);
            }
            return JsonUtil.Deserialize<ClipDatabase>(text);
        }

        public static void SaveAtomic(string path, ClipDatabase database)
        {
            SaveAtomic(path, database, string.Empty);
        }

        public static void SaveAtomic(string path, ClipDatabase database, string password)
        {
            if (!string.IsNullOrEmpty(password) && IsCompressedPath(path))
            {
                SaveEncryptedAtomic(path, database, password);
                return;
            }

            if (IsCompressedPath(path))
            {
                SaveCompressedAtomic(path, database);
                return;
            }

            JsonUtil.SaveAtomic(path, database);
        }

        public static bool IsEncryptedFile(string path)
        {
            return HasMagic(path, EncryptedMagic);
        }

        private static bool IsCompressedPath(string path)
        {
            return string.Equals(Path.GetExtension(path), CompressedExtension, StringComparison.OrdinalIgnoreCase);
        }

        private static string ReadCompressedText(string path)
        {
            using (var file = File.OpenRead(path))
            {
                if (StartsWithMagic(file, CompressedMagic))
                {
                    file.Position = CompressedMagic.Length;
                }
                else
                {
                    file.Position = 0;
                }

                using (var gzip = new GZipStream(file, CompressionMode.Decompress))
                using (var reader = new StreamReader(gzip, Encoding.UTF8))
                {
                    return reader.ReadToEnd();
                }
            }
        }

        private static bool HasMagic(string path, byte[] magic)
        {
            if (!File.Exists(path)) return false;
            try
            {
                using (var file = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    return StartsWithMagic(file, magic);
                }
            }
            catch
            {
                return false;
            }
        }

        private static bool StartsWithMagic(Stream stream, byte[] magic)
        {
            var buffer = new byte[magic.Length];
            if (stream.Read(buffer, 0, buffer.Length) != buffer.Length) return false;
            for (var i = 0; i < magic.Length; i++)
            {
                if (buffer[i] != magic[i]) return false;
            }
            return true;
        }

        private static void WriteCompressedPayload(Stream output, ClipDatabase database)
        {
            output.Write(CompressedMagic, 0, CompressedMagic.Length);
            using (var gzip = new GZipStream(output, CompressionMode.Compress, true))
            using (var writer = new StreamWriter(gzip, Encoding.UTF8))
            {
                writer.Write(JsonUtil.SerializePretty(database));
            }
        }

        private static void SaveCompressedAtomic(string path, ClipDatabase database)
        {
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }

            var temp = path + ".tmp";
            using (var file = File.Create(temp))
            {
                WriteCompressedPayload(file, database);
            }

            ReplaceTemp(temp, path);
        }

        private static string ReadEncryptedText(string path, string password)
        {
            if (string.IsNullOrEmpty(password))
            {
                throw new DatabasePasswordRequiredException("This Clipman database is encrypted and needs its history password.");
            }

            var bytes = File.ReadAllBytes(path);
            if (bytes.Length < EncryptedMagic.Length + 1 + 16 + 16 + 32)
            {
                throw new InvalidDataException("The encrypted Clipman database is incomplete.");
            }

            var offset = EncryptedMagic.Length;
            var version = bytes[offset++];
            if (version != 1)
            {
                throw new InvalidDataException("This encrypted Clipman database uses an unsupported format.");
            }

            var salt = Slice(bytes, offset, 16);
            offset += 16;
            var iv = Slice(bytes, offset, 16);
            offset += 16;
            var hmac = Slice(bytes, bytes.Length - 32, 32);
            var cipherLength = bytes.Length - offset - 32;
            var cipher = Slice(bytes, offset, cipherLength);
            var keys = DeriveKeys(password, salt);
            var signed = Slice(bytes, 0, bytes.Length - 32);
            using (var h = new HMACSHA256(keys.MacKey))
            {
                if (!ConstantTimeEquals(h.ComputeHash(signed), hmac))
                {
                    throw new DatabasePasswordRequiredException("The Clipman database password is incorrect.");
                }
            }

            using (var aes = Aes.Create())
            {
                aes.Key = keys.EncryptionKey;
                aes.IV = iv;
                aes.Mode = CipherMode.CBC;
                aes.Padding = PaddingMode.PKCS7;
                using (var decryptor = aes.CreateDecryptor())
                {
                    var plain = decryptor.TransformFinalBlock(cipher, 0, cipher.Length);
                    var compressed = DecompressBytes(plain);
                    return Encoding.UTF8.GetString(compressed);
                }
            }
        }

        private static void SaveEncryptedAtomic(string path, ClipDatabase database, string password)
        {
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }

            var temp = path + ".tmp";
            var salt = ExistingEncryptedSalt(path) ?? RandomBytes(16);
            var iv = RandomBytes(16);
            var keys = DeriveKeys(password, salt);
            var plain = Encoding.UTF8.GetBytes(JsonUtil.SerializePretty(database));
            var compressed = CompressBytes(plain);
            byte[] cipher;
            using (var aes = Aes.Create())
            {
                aes.Key = keys.EncryptionKey;
                aes.IV = iv;
                aes.Mode = CipherMode.CBC;
                aes.Padding = PaddingMode.PKCS7;
                using (var encryptor = aes.CreateEncryptor())
                {
                    cipher = encryptor.TransformFinalBlock(compressed, 0, compressed.Length);
                }
            }

            using (var memory = new MemoryStream())
            {
                memory.Write(EncryptedMagic, 0, EncryptedMagic.Length);
                memory.WriteByte(1);
                memory.Write(salt, 0, salt.Length);
                memory.Write(iv, 0, iv.Length);
                memory.Write(cipher, 0, cipher.Length);
                using (var h = new HMACSHA256(keys.MacKey))
                {
                    var signed = memory.ToArray();
                    var mac = h.ComputeHash(signed);
                    memory.Write(mac, 0, mac.Length);
                }
                File.WriteAllBytes(temp, memory.ToArray());
            }

            ReplaceTemp(temp, path);
        }

        private static byte[] CompressBytes(byte[] value)
        {
            using (var output = new MemoryStream())
            {
                using (var gzip = new GZipStream(output, CompressionMode.Compress))
                {
                    gzip.Write(value, 0, value.Length);
                }
                return output.ToArray();
            }
        }

        private static byte[] DecompressBytes(byte[] value)
        {
            using (var input = new MemoryStream(value))
            using (var gzip = new GZipStream(input, CompressionMode.Decompress))
            using (var output = new MemoryStream())
            {
                gzip.CopyTo(output);
                return output.ToArray();
            }
        }

        private static KeyPair DeriveKeys(string password, byte[] salt)
        {
            var cacheId = CacheId(password, salt);
            lock (KeyCacheLock)
            {
                if (cachedKeys != null && string.Equals(cachedKeyId, cacheId, StringComparison.Ordinal))
                {
                    return cachedKeys.Clone();
                }
            }

            using (var derive = new Rfc2898DeriveBytes(password, salt, 150000))
            {
                var keys = new KeyPair
                {
                    EncryptionKey = derive.GetBytes(32),
                    MacKey = derive.GetBytes(32)
                };

                lock (KeyCacheLock)
                {
                    cachedKeyId = cacheId;
                    cachedKeys = keys.Clone();
                }

                return keys;
            }
        }

        private static string CacheId(string password, byte[] salt)
        {
            using (var sha = SHA256.Create())
            {
                return Convert.ToBase64String(sha.ComputeHash(Encoding.UTF8.GetBytes((password ?? string.Empty) + "\0" + Convert.ToBase64String(salt ?? new byte[0]))));
            }
        }

        private static byte[] ExistingEncryptedSalt(string path)
        {
            try
            {
                if (!IsEncryptedFile(path)) return null;
                var buffer = new byte[EncryptedMagic.Length + 1 + 16];
                using (var file = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    if (file.Read(buffer, 0, buffer.Length) != buffer.Length) return null;
                }
                return Slice(buffer, EncryptedMagic.Length + 1, 16);
            }
            catch
            {
                return null;
            }
        }

        private static byte[] RandomBytes(int length)
        {
            var bytes = new byte[length];
            using (var rng = RandomNumberGenerator.Create())
            {
                rng.GetBytes(bytes);
            }
            return bytes;
        }

        private static byte[] Slice(byte[] source, int offset, int length)
        {
            var result = new byte[length];
            Buffer.BlockCopy(source, offset, result, 0, length);
            return result;
        }

        private static bool ConstantTimeEquals(byte[] left, byte[] right)
        {
            if (left == null || right == null || left.Length != right.Length) return false;
            var diff = 0;
            for (var i = 0; i < left.Length; i++)
            {
                diff |= left[i] ^ right[i];
            }
            return diff == 0;
        }

        private static void ReplaceTemp(string temp, string path)
        {
            if (File.Exists(path))
            {
                File.Replace(temp, path, null);
            }
            else
            {
                File.Move(temp, path);
            }
        }

        private sealed class KeyPair
        {
            public byte[] EncryptionKey { get; set; }
            public byte[] MacKey { get; set; }

            public KeyPair Clone()
            {
                return new KeyPair
                {
                    EncryptionKey = (byte[])EncryptionKey.Clone(),
                    MacKey = (byte[])MacKey.Clone()
                };
            }
        }
    }
}
