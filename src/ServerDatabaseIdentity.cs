using System;
using System.Security.Cryptography;
using System.Text;

namespace Clipman
{
    internal static class ServerDatabaseIdentity
    {
        private const string Purpose = "Clipman.ServerDatabaseId.v1";
        public static string FromTokenAndPassword(string serverToken, string historyPassword)
        {
            var token = (serverToken ?? string.Empty).Trim();
            var password = historyPassword ?? string.Empty;
            if (token.Length == 0 || password.Length == 0) return string.Empty;

            var key = SHA256.Create().ComputeHash(Encoding.UTF8.GetBytes(token));
            using (var hmac = new HMACSHA256(key))
            {
                var bytes = Encoding.UTF8.GetBytes(Purpose + "\n" + password);
                return ToBase64Url(hmac.ComputeHash(bytes));
            }
        }

        private static string ToBase64Url(byte[] bytes)
        {
            return Convert.ToBase64String(bytes ?? new byte[0]).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        }
    }
}
