using System;
using System.Net;

namespace Clipman
{
    internal static class NetworkSecurity
    {
        private const int Tls12 = 3072;
        private const int Tls13 = 12288;

        public static void EnableModernTls()
        {
            var protocols = (SecurityProtocolType)Tls12;
            var tls13 = (SecurityProtocolType)Tls13;
            if (Enum.IsDefined(typeof(SecurityProtocolType), tls13))
            {
                protocols |= tls13;
            }

            ServicePointManager.SecurityProtocol = protocols;
        }
    }
}
