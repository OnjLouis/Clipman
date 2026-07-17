using System;
using System.Security.Cryptography;
using System.Text;

namespace Clipman
{
    internal static class ServerTokenProtector
    {
        private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("Clipman.ServerToken.v1");

        public static string Protect(string token)
        {
            if (string.IsNullOrEmpty(token)) return string.Empty;
            var data = Encoding.UTF8.GetBytes(token);
            var protectedData = ProtectedData.Protect(data, Entropy, DataProtectionScope.CurrentUser);
            return Convert.ToBase64String(protectedData);
        }

        public static string Unprotect(string protectedToken)
        {
            if (string.IsNullOrWhiteSpace(protectedToken)) return string.Empty;
            var data = Convert.FromBase64String(protectedToken);
            var plain = ProtectedData.Unprotect(data, Entropy, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plain);
        }
    }
}
