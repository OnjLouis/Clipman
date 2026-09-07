using System;
using System.Security.Cryptography;
using System.Text;

namespace Clipman
{
    internal static class ServerDatabaseIdentity
    {
        private const string Purpose = "Clipman.ServerDatabaseId.v1";
        private const string ChannelPurpose = "Clipman.ServerChannelId.v1";
        private const string SyncRulesPurpose = "Clipman.ServerSyncRulesId.v1";

        public static string FromTokenAndPassword(string serverToken, string historyPassword)
        {
            var password = historyPassword ?? string.Empty;
            return Derive(serverToken, password, Purpose + "\n" + password);
        }

        public static string ChannelFromTokenAndPassword(string serverToken, string historyPassword, string channelKey)
        {
            var password = historyPassword ?? string.Empty;
            return Derive(serverToken, password, ChannelPurpose + "\n" + password + "\n" + (channelKey ?? string.Empty));
        }

        public static string SyncRulesFromTokenAndPassword(string serverToken, string historyPassword)
        {
            var password = historyPassword ?? string.Empty;
            return Derive(serverToken, password, SyncRulesPurpose + "\n" + password);
        }

        private static string Derive(string serverToken, string password, string message)
        {
            var token = (serverToken ?? string.Empty).Trim();
            if (token.Length == 0 || password.Length == 0) return string.Empty;

            var key = SHA256.Create().ComputeHash(Encoding.UTF8.GetBytes(token));
            using (var hmac = new HMACSHA256(key))
            {
                return ToBase64Url(hmac.ComputeHash(Encoding.UTF8.GetBytes(message)));
            }
        }

        private static string ToBase64Url(byte[] bytes)
        {
            return Convert.ToBase64String(bytes ?? new byte[0]).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        }
    }
}
