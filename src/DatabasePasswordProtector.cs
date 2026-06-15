using System;
using System.Security.Cryptography;
using System.Text;

namespace Clipman
{
    internal static class DatabasePasswordProtector
    {
        private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("Clipman.DatabasePassword.v1");

        public static string Protect(string password)
        {
            if (string.IsNullOrEmpty(password)) return string.Empty;
            var data = Encoding.UTF8.GetBytes(password);
            var protectedData = ProtectedData.Protect(data, Entropy, DataProtectionScope.CurrentUser);
            return Convert.ToBase64String(protectedData);
        }

        public static string Unprotect(string protectedPassword)
        {
            if (string.IsNullOrWhiteSpace(protectedPassword)) return string.Empty;
            var data = Convert.FromBase64String(protectedPassword);
            var plain = ProtectedData.Unprotect(data, Entropy, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plain);
        }

        public static bool CanUnprotect(string protectedPassword)
        {
            try
            {
                return !string.IsNullOrEmpty(Unprotect(protectedPassword));
            }
            catch
            {
                return false;
            }
        }

        public static string GeneratePassword()
        {
            var bytes = new byte[24];
            using (var rng = RandomNumberGenerator.Create())
            {
                rng.GetBytes(bytes);
            }

            return Convert.ToBase64String(bytes)
                .TrimEnd('=')
                .Replace('+', '-')
                .Replace('/', '_');
        }
    }
}
