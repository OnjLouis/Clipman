using System;
using System.Collections.Generic;
using System.Globalization;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace Clipman
{
    internal static class ServerSettingsSanitizer
    {
        private static readonly Regex UrlRegex = new Regex(@"(?:https?|clipman)://[^\s""'<>]+", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private static readonly Regex JsonAuthTokenRegex = new Regex(@"""(?:AuthToken|token)""\s*:\s*""([^""]+)""", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private static readonly Regex JsonPortRegex = new Regex(@"""Port""\s*:\s*(\d+)", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private static readonly Regex JsonHostRegex = new Regex(@"""Host""\s*:\s*""([^""]+)""", RegexOptions.IgnoreCase | RegexOptions.Compiled);

        public static string CleanUrl(string value)
        {
            var text = (value ?? string.Empty).Trim();
            if (text.Length == 0) return string.Empty;

            var directUrl = UrlRegex.Match(text);
            if (directUrl.Success)
            {
                return NormalizeDisplayUrl(TrimUrlPunctuation(directUrl.Value));
            }

            var host = MatchGroup(JsonHostRegex, text);
            var port = MatchGroup(JsonPortRegex, text);
            if (host.Length > 0 && port.Length > 0)
            {
                if (string.Equals(host, "0.0.0.0", StringComparison.OrdinalIgnoreCase))
                {
                    host = "localhost";
                }
                return "clipman://" + host + ":" + port;
            }

            var cleaned = TrimUrlPunctuation(text);
            if (cleaned.Length > 0 &&
                cleaned.IndexOf("://", StringComparison.Ordinal) < 0 &&
                cleaned.IndexOfAny(new[] { ' ', '\t', '\r', '\n' }) < 0)
            {
                cleaned = "clipman://" + cleaned;
            }
            return NormalizeDisplayUrl(cleaned);
        }

        public static string CleanTransportUrl(string value)
        {
            var cleaned = CleanUrl(value);
            if (cleaned.StartsWith("clipman://", StringComparison.OrdinalIgnoreCase))
            {
                return "http://" + cleaned.Substring("clipman://".Length);
            }
            return cleaned;
        }

        public static string CleanToken(string value)
        {
            var text = (value ?? string.Empty).Trim();
            if (text.Length == 0) return string.Empty;

            var jsonToken = MatchGroup(JsonAuthTokenRegex, text);
            if (jsonToken.Length > 0)
            {
                return jsonToken.Trim();
            }

            try
            {
                var serializer = new JavaScriptSerializer();
                var parsed = serializer.Deserialize<ServerSettingsTokenProbe>(text);
                if (parsed != null && !string.IsNullOrWhiteSpace(parsed.AuthToken))
                {
                    return parsed.AuthToken.Trim();
                }
            }
            catch
            {
            }

            return text.Trim().Trim('"', '\'', ',', ';');
        }

        public static bool TryParseConnectionConfig(string value, out ServerConnectionDetails details, out string error)
        {
            details = null;
            error = string.Empty;
            try
            {
                var serializer = new JavaScriptSerializer();
                var parsed = serializer.DeserializeObject(value ?? string.Empty) as Dictionary<string, object>;
                if (parsed == null || !string.Equals(GetString(parsed, "clipman"), "server-connection", StringComparison.Ordinal))
                {
                    error = "This is not a Clipman Server connection file.";
                    return false;
                }

                int version;
                if (!int.TryParse(GetString(parsed, "version"), out version) || version != 1)
                {
                    error = "This Clipman Server connection-file version is not supported.";
                    return false;
                }

                var address = CleanUrl(GetString(parsed, "address"));
                if (address.Length == 0)
                {
                    var host = GetString(parsed, "host");
                    var port = GetString(parsed, "port");
                    if (host.Length > 0 && port.Length > 0)
                    {
                        address = CleanUrl(host + ":" + port);
                    }
                }
                var token = CleanToken(GetString(parsed, "token"));
                if (address.Length == 0 || token.Length == 0)
                {
                    error = "The connection file does not contain both a server address and token.";
                    return false;
                }

                ServerCertificateAuthority authority;
                if (!TryParseCertificateAuthority(GetString(parsed, "ca_cert_pem"), address, out authority, out error))
                {
                    return false;
                }

                details = new ServerConnectionDetails(address, token, authority);
                return true;
            }
            catch (Exception ex)
            {
                error = "Clipman could not read this connection file: " + ex.Message;
                return false;
            }
        }

        public static bool TryCreateConnectionConfig(string addressValue, string tokenValue, out string json, out string error)
        {
            return TryCreateConnectionConfig(addressValue, tokenValue, string.Empty, string.Empty, out json, out error);
        }

        public static bool TryCreateConnectionConfig(
            string addressValue,
            string tokenValue,
            string caCertPem,
            string caHost,
            out string json,
            out string error)
        {
            json = string.Empty;
            error = string.Empty;
            var address = CleanUrl(addressValue);
            var token = CleanToken(tokenValue);
            if (address.Length == 0 || token.Length == 0)
            {
                error = "Enter both a Clipman Server address and token before exporting the connection file.";
                return false;
            }

            Uri uri;
            var transport = CleanTransportUrl(address);
            if (!Uri.TryCreate(transport, UriKind.Absolute, out uri) || string.IsNullOrWhiteSpace(uri.Host))
            {
                error = "The Clipman Server address is not valid.";
                return false;
            }

            ServerCertificateAuthority authority;
            if (!TryParseCertificateAuthority(caCertPem, address, out authority, out error))
            {
                return false;
            }
            if (authority != null &&
                !string.IsNullOrWhiteSpace(caHost) &&
                !string.Equals(authority.Host, caHost.Trim(), StringComparison.OrdinalIgnoreCase))
            {
                error = "The private certificate authority is configured for a different server host.";
                return false;
            }

            var values = new Dictionary<string, object>
            {
                { "clipman", "server-connection" },
                { "version", 1 },
                { "address", address },
                { "host", uri.Host },
                { "port", uri.IsDefaultPort ? (string.Equals(uri.Scheme, "https", StringComparison.OrdinalIgnoreCase) ? 443 : 80) : uri.Port },
                { "token", token }
            };
            if (authority != null)
            {
                values["ca_cert_pem"] = authority.Pem;
            }
            json = new JavaScriptSerializer().Serialize(values);
            return true;
        }

        public static bool TryParseCertificateAuthority(
            string pemValue,
            string addressValue,
            out ServerCertificateAuthority authority,
            out string error)
        {
            authority = null;
            error = string.Empty;
            var pem = (pemValue ?? string.Empty).Trim();
            if (pem.Length == 0) return true;
            if (Encoding.UTF8.GetByteCount(pem) > 32 * 1024)
            {
                error = "The private certificate authority exceeds the 32 KiB limit.";
                return false;
            }
            if (pem.IndexOf("PRIVATE KEY", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                error = "The private certificate authority must not contain private key material.";
                return false;
            }

            var match = Regex.Match(
                pem,
                @"\A\s*-----BEGIN CERTIFICATE-----\s*(?<data>[A-Za-z0-9+/=\r\n]+?)\s*-----END CERTIFICATE-----\s*\z",
                RegexOptions.CultureInvariant);
            if (!match.Success)
            {
                error = "The private certificate authority must contain exactly one PEM CERTIFICATE block.";
                return false;
            }

            byte[] raw;
            X509Certificate2 certificate;
            try
            {
                raw = Convert.FromBase64String(Regex.Replace(match.Groups["data"].Value, @"\s+", string.Empty));
                certificate = new X509Certificate2(raw);
            }
            catch (Exception ex)
            {
                error = "Clipman could not parse the private certificate authority: " + ex.Message;
                return false;
            }

            var isAuthority = false;
            var canSign = true;
            foreach (X509Extension extension in certificate.Extensions)
            {
                if (extension.Oid != null && extension.Oid.Value == "2.5.29.19")
                {
                    var constraints = new X509BasicConstraintsExtension(extension, extension.Critical);
                    isAuthority = constraints.CertificateAuthority;
                }
                else if (extension.Oid != null && extension.Oid.Value == "2.5.29.15")
                {
                    var usage = new X509KeyUsageExtension(extension, extension.Critical);
                    canSign = (usage.KeyUsages & X509KeyUsageFlags.KeyCertSign) != 0;
                }
            }
            if (!isAuthority)
            {
                error = "The configured certificate is not marked as a certificate authority.";
                return false;
            }
            if (!canSign)
            {
                error = "The configured certificate authority cannot sign certificates.";
                return false;
            }
            var now = DateTime.Now;
            if (now < certificate.NotBefore)
            {
                error = "The configured certificate authority is not valid yet.";
                return false;
            }
            if (now > certificate.NotAfter)
            {
                error = "The configured certificate authority has expired.";
                return false;
            }

            Uri uri;
            var displayAddress = CleanUrl(addressValue);
            var transportAddress = CleanTransportUrl(displayAddress);
            if (!Uri.TryCreate(transportAddress, UriKind.Absolute, out uri) ||
                !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
                string.IsNullOrWhiteSpace(uri.Host))
            {
                error = "A private certificate authority can be used only with an HTTPS server address.";
                return false;
            }

            var canonicalPem = "-----BEGIN CERTIFICATE-----\n" +
                Convert.ToBase64String(raw, Base64FormattingOptions.InsertLineBreaks).Replace("\r\n", "\n") +
                "\n-----END CERTIFICATE-----\n";
            authority = new ServerCertificateAuthority(
                canonicalPem,
                uri.Host,
                raw,
                certificate.Subject,
                certificate.NotAfter,
                Sha256Fingerprint(raw));
            return true;
        }

        private static string Sha256Fingerprint(byte[] raw)
        {
            using (var sha = SHA256.Create())
            {
                return BitConverter.ToString(sha.ComputeHash(raw)).Replace("-", ":");
            }
        }

        private static string GetString(Dictionary<string, object> values, string key)
        {
            object value;
            return values.TryGetValue(key, out value) && value != null
                ? Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture).Trim()
                : string.Empty;
        }

        private static string MatchGroup(Regex regex, string text)
        {
            var match = regex.Match(text);
            return match.Success && match.Groups.Count > 1 ? match.Groups[1].Value.Trim() : string.Empty;
        }

        private static string TrimUrlPunctuation(string value)
        {
            return (value ?? string.Empty).Trim().Trim('"', '\'', ',', ';', '.', ')', ']', '}');
        }

        private static string NormalizeDisplayUrl(string value)
        {
            var cleaned = TrimUrlPunctuation(value);
            if (cleaned.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
            {
                cleaned = "clipman://" + cleaned.Substring("http://".Length);
            }
            return cleaned;
        }

        private sealed class ServerSettingsTokenProbe
        {
            public string AuthToken { get; set; }
        }
    }

    internal sealed class ServerConnectionDetails
    {
        public ServerConnectionDetails(string address, string token, ServerCertificateAuthority authority)
        {
            Address = address;
            Token = token;
            Authority = authority;
        }

        public string Address { get; private set; }
        public string Token { get; private set; }
        public ServerCertificateAuthority Authority { get; private set; }
    }

    internal sealed class ServerCertificateAuthority
    {
        public ServerCertificateAuthority(
            string pem,
            string host,
            byte[] rawData,
            string subject,
            DateTime expires,
            string fingerprint)
        {
            Pem = pem ?? string.Empty;
            Host = host ?? string.Empty;
            RawData = rawData ?? new byte[0];
            Subject = subject ?? string.Empty;
            Expires = expires;
            Fingerprint = fingerprint ?? string.Empty;
        }

        public string Pem { get; private set; }
        public string Host { get; private set; }
        public byte[] RawData { get; private set; }
        public string Subject { get; private set; }
        public DateTime Expires { get; private set; }
        public string Fingerprint { get; private set; }
    }
}
