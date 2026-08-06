using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text;
using System.Text.RegularExpressions;
using System.Web;

namespace Clipman
{
    internal sealed class LinkTitleFetchResult
    {
        public bool Success { get; set; }
        public string Title { get; set; }
        public string Error { get; set; }
        public string Host { get; set; }
    }

    internal static class LinkTitleFetcher
    {
        private const int MaximumMetadataCharacters = 128 * 1024;
        private const int MaximumWireBodyBytes = 1024 * 1024;
        private const int MaximumDecodedBodyBytes = 2 * 1024 * 1024;
        private const int MaximumHeaderBytes = 32 * 1024;
        private const int FetchDeadlineMilliseconds = 15000;

        private sealed class PinnedHttpResponse
        {
            public int StatusCode { get; set; }
            public byte[] Body { get; set; }
            public Dictionary<string, string> Headers { get; set; }

            public string Header(string name)
            {
                string value;
                return Headers != null && Headers.TryGetValue(name, out value) ? value : string.Empty;
            }
        }

        private sealed class DeadlineStream : Stream
        {
            private readonly Stream inner;
            private readonly Stopwatch deadline;

            public DeadlineStream(Stream inner, Stopwatch deadline)
            {
                this.inner = inner;
                this.deadline = deadline;
            }

            public override bool CanRead { get { return inner.CanRead; } }
            public override bool CanSeek { get { return inner.CanSeek; } }
            public override bool CanWrite { get { return inner.CanWrite; } }
            public override long Length { get { return inner.Length; } }
            public override long Position { get { return inner.Position; } set { inner.Position = value; } }
            public override void Flush() { SetWriteTimeout(inner, deadline); inner.Flush(); }
            public override int Read(byte[] buffer, int offset, int count) { SetReadTimeout(inner, deadline); return inner.Read(buffer, offset, count); }
            public override int ReadByte() { SetReadTimeout(inner, deadline); return inner.ReadByte(); }
            public override long Seek(long offset, SeekOrigin origin) { return inner.Seek(offset, origin); }
            public override void SetLength(long value) { inner.SetLength(value); }
            public override void Write(byte[] buffer, int offset, int count) { SetWriteTimeout(inner, deadline); inner.Write(buffer, offset, count); }
        }
        private static readonly string[] CapabilityParameters =
        {
            "access_token", "apikey", "api_key", "auth", "authorization", "challenge", "code", "confirmation", "credential", "hmac",
            "id_token", "invite", "jwt", "key", "nonce", "one_time", "otp", "passcode", "password", "reset", "secret",
            "session", "sig", "signature", "signed", "sso", "state", "ticket", "token", "verification", "awsaccesskeyid",
            "googleaccessid", "key-pair-id"
        };

        private static readonly string[] JunkTitleExactMatches =
        {
            "just a moment", "attention required", "access denied", "access to this page has been denied",
            "are you a robot", "are you a human", "please wait", "javascript is disabled",
            "javascript is required", "enable javascript", "security check", "checking your browser",
            "verify you are human", "human verification", "bot verification", "one moment please", "loading",
            "redirecting", "error", "page not found", "not found", "404", "403 forbidden", "forbidden",
            "site maintenance", "under construction", "untitled", "untitled document", "log in", "login",
            "sign in", "signin", "log in or sign up", "robot check", "captcha", "request blocked", "blocked",
            "reddit - dive into anything"
        };

        private static readonly string[] JunkTitleSubstrings =
        {
            "please wait for verification", "checking if the site connection is secure",
            "enable javascript and cookies to continue", "verify you are a human",
            "your request has been blocked", "unusual traffic"
        };

        private static readonly string[] NonMetadataElements =
        {
            "script", "style", "template", "noscript", "svg", "iframe"
        };

        public static bool CanFetch(Uri uri, out string reason)
        {
            return Validate(uri, true, out reason);
        }

        public static bool CanOffer(Uri uri, out string reason)
        {
            return Validate(uri, false, out reason);
        }

        private static bool Validate(Uri uri, bool resolveHost, out string reason)
        {
            reason = string.Empty;
            if (!LinkPresentation.IsUrlWithinLimit(uri))
            {
                reason = "Website addresses longer than 8192 characters are not contacted.";
                return false;
            }
            if (!uri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) &&
                !uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
            {
                reason = "Only HTTP and HTTPS links can provide website titles.";
                return false;
            }
            if (!string.IsNullOrEmpty(uri.UserInfo))
            {
                reason = "Links containing a username or password are not contacted.";
                return false;
            }
            if (!uri.IsDefaultPort)
            {
                reason = "Links using a non-standard port are not contacted.";
                return false;
            }
            if (IsCapabilityUrl(uri))
            {
                reason = "This link contains a token-like path or a credential-related parameter, so Clipman will not contact it.";
                return false;
            }
            if (resolveHost)
            {
                if (!HasOnlyPublicAddresses(uri.Host, out reason)) return false;
            }
            else if (!HasSafeHostWithoutNetwork(uri.Host, out reason))
            {
                return false;
            }
            return true;
        }

        public static LinkTitleFetchResult Fetch(Uri original)
        {
            var result = new LinkTitleFetchResult { Title = string.Empty, Error = string.Empty, Host = original == null ? string.Empty : original.Host };
            try
            {
                var deadline = Stopwatch.StartNew();
                var current = original;
                for (var redirect = 0; redirect <= 3; redirect++)
                {
                    string reason;
                    IPAddress[] addresses;
                    if (!Validate(current, false, out reason) || !TryResolvePublicAddresses(current.Host, deadline, out addresses, out reason)) return Failure(result, reason);
                    result.Host = current.Host;
                    var response = SendPinned(current, addresses, deadline);
                    var status = response.StatusCode;
                    if (status >= 300 && status <= 399)
                    {
                        var location = response.Header("Location");
                        Uri next;
                        if (redirect == 3 || string.IsNullOrWhiteSpace(location) ||
                            location.Length > LinkPresentation.MaximumUrlCharacters || !Uri.TryCreate(current, location, out next))
                        {
                            return Failure(result, "The website redirected too many times or returned an invalid redirect.");
                        }
                        if (current.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) &&
                            next.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase))
                        {
                            return Failure(result, "The website redirected from HTTPS to insecure HTTP.");
                        }
                        current = next;
                        continue;
                    }
                    if (status < 200 || status > 299) return Failure(result, "The website returned HTTP " + status + ".");
                    var contentType = response.Header("Content-Type");
                    if (!contentType.StartsWith("text/html", StringComparison.OrdinalIgnoreCase) &&
                        !contentType.StartsWith("application/xhtml+xml", StringComparison.OrdinalIgnoreCase))
                    {
                        return Failure(result, "The link did not return an HTML page.");
                    }
                    var html = Decode(response.Body, CharacterSet(contentType));
                    var title = ExtractTitle(html, current.Host);
                    if (string.IsNullOrWhiteSpace(title)) return Failure(result, "The website did not provide a useful title.");
                    result.Success = true;
                    result.Title = title;
                    result.Host = current.Host;
                    return result;
                }
            }
            catch (Exception ex)
            {
                return Failure(result, "Could not retrieve the website title: " + ex.Message);
            }
            return Failure(result, "The website title could not be retrieved.");
        }

        private static PinnedHttpResponse SendPinned(Uri uri, IEnumerable<IPAddress> addresses, Stopwatch deadline)
        {
            Exception lastError = null;
            foreach (var address in addresses ?? Enumerable.Empty<IPAddress>())
            {
                RemainingMilliseconds(deadline, FetchDeadlineMilliseconds);
                try { return SendPinned(uri, address, deadline); }
                catch (Exception ex) { lastError = ex; }
            }
            throw new IOException("No validated website address accepted the connection.", lastError);
        }

        private static PinnedHttpResponse SendPinned(Uri uri, IPAddress address, Stopwatch deadline)
        {
            var port = uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ? 443 : 80;
            using (var client = new TcpClient(address.AddressFamily))
            {
                client.NoDelay = true;
                client.ReceiveTimeout = RemainingMilliseconds(deadline, 5000);
                client.SendTimeout = RemainingMilliseconds(deadline, 5000);
                var connect = client.BeginConnect(address, port, null, null);
                using (connect.AsyncWaitHandle)
                {
                    if (!connect.AsyncWaitHandle.WaitOne(RemainingMilliseconds(deadline, 8000))) throw new TimeoutException("The website connection timed out.");
                    client.EndConnect(connect);
                }

                using (var network = client.GetStream())
                {
                    SetReadTimeout(network, deadline);
                    SetWriteTimeout(network, deadline);
                    if (uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
                    {
                        using (var tls = new SslStream(network, false))
                        {
                            SetReadTimeout(tls, deadline);
                            SetWriteTimeout(tls, deadline);
                            var handshake = tls.BeginAuthenticateAsClient(uri.DnsSafeHost, null, SslProtocols.Tls12, true, null, null);
                            using (handshake.AsyncWaitHandle)
                            {
                                if (!handshake.AsyncWaitHandle.WaitOne(RemainingMilliseconds(deadline, FetchDeadlineMilliseconds)))
                                    throw new TimeoutException("The website TLS connection timed out.");
                                tls.EndAuthenticateAsClient(handshake);
                            }
                            return SendAndRead(uri, new DeadlineStream(tls, deadline));
                        }
                    }
                    return SendAndRead(uri, new DeadlineStream(network, deadline));
                }
            }
        }

        private static int RemainingMilliseconds(Stopwatch deadline, int cap)
        {
            var remaining = FetchDeadlineMilliseconds - (int)Math.Min(int.MaxValue, deadline == null ? FetchDeadlineMilliseconds : deadline.ElapsedMilliseconds);
            if (remaining <= 0) throw new TimeoutException("The website title request timed out.");
            return Math.Max(1, Math.Min(cap, remaining));
        }

        private static void SetReadTimeout(Stream stream, Stopwatch deadline)
        {
            if (stream != null && stream.CanTimeout) stream.ReadTimeout = RemainingMilliseconds(deadline, 5000);
        }

        private static void SetWriteTimeout(Stream stream, Stopwatch deadline)
        {
            if (stream != null && stream.CanTimeout) stream.WriteTimeout = RemainingMilliseconds(deadline, 5000);
        }

        private static PinnedHttpResponse SendAndRead(Uri uri, Stream stream)
        {
            var host = uri.HostNameType == UriHostNameType.IPv6 ? "[" + uri.DnsSafeHost + "]" : uri.DnsSafeHost;
            var target = string.IsNullOrEmpty(uri.PathAndQuery) ? "/" : uri.PathAndQuery;
            var request = "GET " + target + " HTTP/1.1\r\n" +
                          "Host: " + host + "\r\n" +
                          "User-Agent: Clipman/WebsiteTitle\r\n" +
                          "Accept: text/html,application/xhtml+xml;q=0.9\r\n" +
                          "Accept-Encoding: gzip\r\n" +
                          "Connection: close\r\n\r\n";
            var requestBytes = Encoding.ASCII.GetBytes(request);
            stream.Write(requestBytes, 0, requestBytes.Length);
            stream.Flush();

            var headerBytes = ReadHeader(stream);
            var headerText = Encoding.GetEncoding(28591).GetString(headerBytes);
            var lines = headerText.Split(new[] { "\r\n" }, StringSplitOptions.None);
            if (lines.Length == 0) throw new InvalidDataException("The website returned an invalid HTTP response.");
            var statusMatch = Regex.Match(lines[0], @"^HTTP/\d(?:\.\d)?\s+(\d{3})(?:\s|$)", RegexOptions.CultureInvariant);
            if (!statusMatch.Success) throw new InvalidDataException("The website returned an invalid HTTP status.");
            var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (var index = 1; index < lines.Length; index++)
            {
                if (lines[index].Length == 0) continue;
                var colon = lines[index].IndexOf(':');
                if (colon <= 0) throw new InvalidDataException("The website returned an invalid HTTP header.");
                var name = lines[index].Substring(0, colon).Trim();
                var value = lines[index].Substring(colon + 1).Trim();
                string existing;
                headers[name] = headers.TryGetValue(name, out existing) ? existing + ", " + value : value;
            }
            byte[] body;
            string transferEncoding;
            if (headers.TryGetValue("Transfer-Encoding", out transferEncoding) && transferEncoding.IndexOf("chunked", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                body = ReadChunked(stream, MaximumWireBodyBytes);
            }
            else
            {
                string lengthText;
                var contentLength = 0;
                if (headers.TryGetValue("Content-Length", out lengthText) &&
                    (!int.TryParse(lengthText, NumberStyles.None, CultureInfo.InvariantCulture, out contentLength) || contentLength < 0))
                {
                    throw new InvalidDataException("The website returned an invalid content length.");
                }
                body = headers.ContainsKey("Content-Length") ? ReadExact(stream, Math.Min(contentLength, MaximumWireBodyBytes)) : ReadPrefix(stream, MaximumWireBodyBytes);
            }

            string contentEncoding;
            if (headers.TryGetValue("Content-Encoding", out contentEncoding))
            {
                contentEncoding = contentEncoding.Trim();
            }
            if (string.IsNullOrWhiteSpace(contentEncoding) || contentEncoding.Equals("identity", StringComparison.OrdinalIgnoreCase))
            {
                if (body.Length > MaximumDecodedBodyBytes) body = body.Take(MaximumDecodedBodyBytes).ToArray();
            }
            else if (contentEncoding.Equals("gzip", StringComparison.OrdinalIgnoreCase) || contentEncoding.Equals("x-gzip", StringComparison.OrdinalIgnoreCase))
            {
                body = DecompressGzip(body, MaximumDecodedBodyBytes);
            }
            else
            {
                throw new InvalidDataException("The website returned an unsupported content encoding.");
            }
            return new PinnedHttpResponse
            {
                StatusCode = int.Parse(statusMatch.Groups[1].Value, CultureInfo.InvariantCulture),
                Headers = headers,
                Body = body
            };
        }

        internal static bool IsCapabilityUrl(Uri uri)
        {
            var path = HttpUtility.UrlDecode(uri.AbsolutePath ?? string.Empty) ?? string.Empty;
            if (path.Split('/').Any(segment => LooksOpaque(segment))) return true;
            NameValueCollection query;
            try { query = HttpUtility.ParseQueryString(uri.Query ?? string.Empty); }
            catch { return true; }
            foreach (var keyObject in query.AllKeys)
            {
                var key = keyObject ?? string.Empty;
                if (IsSensitiveParameterName(key)) return true;
            }
            return false;
        }

        private static bool LooksOpaque(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Length < 32 || value.IndexOf(' ') >= 0) return false;
            if (Regex.IsMatch(value, "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")) return true;
            if (LooksLikeReadableSlug(value)) return false;
            var letters = value.Count(char.IsLetter);
            var digits = value.Count(char.IsDigit);
            return letters >= 8 && digits >= 4;
        }

        private static bool LooksLikeReadableSlug(string value)
        {
            var slug = Regex.Replace(value ?? string.Empty, @"\.(?:html?|shtml)$", string.Empty, RegexOptions.IgnoreCase);
            var parts = Regex.Split(slug, "[-_]+").Where(part => part.Length > 0).ToArray();
            if (parts.Length < 5 || parts.Any(part => part.Length > 24)) return false;
            if (parts.Any(part => !part.All(char.IsLetter) &&
                !(part.Length <= 12 && part.All(char.IsDigit)) &&
                !Regex.IsMatch(part, "^[A-Za-z]?[0-9]{4,12}$"))) return false;
            return parts.Count(part => part.Length >= 3 && part.All(char.IsLetter)) >= 4;
        }

        private static bool IsSensitiveParameterName(string value)
        {
            var key = (value ?? string.Empty).Trim().ToLowerInvariant();
            if (key.StartsWith("x-amz-", StringComparison.Ordinal) || key.StartsWith("x-goog-", StringComparison.Ordinal)) return true;
            return CapabilityParameters.Any(name => key.Equals(name, StringComparison.Ordinal) ||
                key.EndsWith("_" + name, StringComparison.Ordinal) ||
                key.EndsWith("-" + name, StringComparison.Ordinal) ||
                key.EndsWith("." + name, StringComparison.Ordinal));
        }

        private static bool HasOnlyPublicAddresses(string host, out string reason)
        {
            IPAddress[] addresses;
            return TryResolvePublicAddresses(host, Stopwatch.StartNew(), out addresses, out reason);
        }

        private static bool TryResolvePublicAddresses(string host, Stopwatch deadline, out IPAddress[] addresses, out string reason)
        {
            addresses = new IPAddress[0];
            reason = string.Empty;
            if (!HasSafeHostWithoutNetwork(host, out reason)) return false;
            try
            {
                var lookup = Dns.BeginGetHostAddresses(host, null, null);
                using (lookup.AsyncWaitHandle)
                {
                    if (!lookup.AsyncWaitHandle.WaitOne(RemainingMilliseconds(deadline, FetchDeadlineMilliseconds)))
                    {
                        reason = "The website address lookup timed out.";
                        return false;
                    }
                    addresses = Dns.EndGetHostAddresses(lookup);
                }
                if (addresses.Length == 0 || addresses.Any(address => !IsPublic(address)))
                {
                    addresses = new IPAddress[0];
                    reason = "The website did not resolve exclusively to public internet addresses.";
                    return false;
                }
                return true;
            }
            catch
            {
                addresses = new IPAddress[0];
                reason = "The website address could not be resolved safely.";
                return false;
            }
        }

        private static bool HasSafeHostWithoutNetwork(string host, out string reason)
        {
            reason = string.Empty;
            var value = (host ?? string.Empty).TrimEnd('.');
            var lower = value.ToLowerInvariant();
            var blockedSuffixes = new[]
            {
                "localhost", ".localhost", ".local", ".lan", ".internal", ".home", ".home.arpa",
                ".localdomain", ".example", ".invalid", ".test", ".onion"
            };
            if (value.Length == 0 || (value.IndexOf('.') < 0 && !value.Contains(":")) ||
                blockedSuffixes.Any(suffix => lower.Equals(suffix.TrimStart('.'), StringComparison.Ordinal) || lower.EndsWith(suffix, StringComparison.Ordinal)))
            {
                reason = "Local and private network addresses are not contacted for website titles.";
                return false;
            }
            IPAddress literal;
            if (IPAddress.TryParse(value, out literal) && !IsPublic(literal))
            {
                reason = "Local and private network addresses are not contacted for website titles.";
                return false;
            }
            return true;
        }

        private static bool IsPublic(IPAddress address)
        {
            if (address == null || IPAddress.IsLoopback(address)) return false;
            if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
            var bytes = address.GetAddressBytes();
            if (address.AddressFamily == AddressFamily.InterNetwork)
            {
                if (bytes[0] == 0 || bytes[0] == 10 || bytes[0] == 127 || bytes[0] >= 224) return false;
                if (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127) return false;
                if (bytes[0] == 169 && bytes[1] == 254) return false;
                if (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) return false;
                if (bytes[0] == 192 && bytes[1] == 168) return false;
                if (bytes[0] == 192 && bytes[1] == 0 && (bytes[2] == 0 || bytes[2] == 2)) return false;
                if (bytes[0] == 192 && bytes[1] == 88 && bytes[2] == 99) return false;
                if (bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19)) return false;
                if (bytes[0] == 198 && bytes[1] == 51 && bytes[2] == 100) return false;
                if (bytes[0] == 203 && bytes[1] == 0 && bytes[2] == 113) return false;
                return true;
            }
            if (address.AddressFamily == AddressFamily.InterNetworkV6)
            {
                if (address.Equals(IPAddress.IPv6Any) || address.Equals(IPAddress.IPv6None) || address.Equals(IPAddress.IPv6Loopback) ||
                    address.IsIPv6LinkLocal || address.IsIPv6Multicast || address.IsIPv6SiteLocal) return false;
                if ((bytes[0] & 0xfe) == 0xfc) return false;
                if (HasPrefix(bytes, new byte[] { 0x00, 0x64, 0xff, 0x9b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, 96)) return false;
                if (HasPrefix(bytes, new byte[] { 0x00, 0x64, 0xff, 0x9b, 0x00, 0x01 }, 48)) return false;
                if (HasPrefix(bytes, new byte[] { 0x20, 0x02 }, 16)) return false;
                if (HasPrefix(bytes, new byte[] { 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, 64)) return false;
                if (HasPrefix(bytes, new byte[] { 0x20, 0x01, 0x00, 0x02, 0x00, 0x00 }, 48)) return false;
                if (HasPrefix(bytes, new byte[] { 0x20, 0x01, 0x00, 0x10 }, 28)) return false;
                if (HasPrefix(bytes, new byte[] { 0x20, 0x01, 0x0d, 0xb8 }, 32)) return false;
                if (HasSensitiveEmbeddedIPv4Tail(bytes)) return false;
                return true;
            }
            return false;
        }

        private static bool HasPrefix(byte[] value, byte[] prefix, int bitCount)
        {
            if (value == null || prefix == null || bitCount < 0 || value.Length * 8 < bitCount || prefix.Length * 8 < bitCount) return false;
            var fullBytes = bitCount / 8;
            for (var index = 0; index < fullBytes; index++)
            {
                if (value[index] != prefix[index]) return false;
            }
            var remainingBits = bitCount % 8;
            if (remainingBits == 0) return true;
            var mask = (byte)(0xff << (8 - remainingBits));
            return (value[fullBytes] & mask) == (prefix[fullBytes] & mask);
        }

        private static bool HasSensitiveEmbeddedIPv4Tail(byte[] bytes)
        {
            if (bytes == null || bytes.Length != 16) return false;
            var a = bytes[12];
            var b = bytes[13];
            if (a == 10 || a == 127) return true;
            if (a == 100 && b >= 64 && b <= 127) return true;
            if (a == 169 && b == 254) return true;
            if (a == 172 && b >= 16 && b <= 31) return true;
            return a == 192 && b == 168;
        }

        private static byte[] ReadHeader(Stream stream)
        {
            using (var output = new MemoryStream())
            {
                var matched = 0;
                var marker = new byte[] { 13, 10, 13, 10 };
                while (output.Length < MaximumHeaderBytes)
                {
                    var value = stream.ReadByte();
                    if (value < 0) throw new EndOfStreamException("The website closed before returning HTTP headers.");
                    output.WriteByte((byte)value);
                    matched = value == marker[matched] ? matched + 1 : value == marker[0] ? 1 : 0;
                    if (matched == marker.Length) return output.ToArray();
                }
            }
            throw new InvalidDataException("The website returned HTTP headers larger than Clipman accepts.");
        }

        private static byte[] ReadPrefix(Stream stream, int maximum)
        {
            using (var output = new MemoryStream())
            {
                var buffer = new byte[8192];
                while (output.Length < maximum)
                {
                    var read = stream.Read(buffer, 0, Math.Min(buffer.Length, maximum - (int)output.Length));
                    if (read <= 0) break;
                    output.Write(buffer, 0, read);
                }
                return output.ToArray();
            }
        }

        private static byte[] DecompressGzip(byte[] input, int maximum)
        {
            using (var source = new MemoryStream(input ?? new byte[0], false))
            using (var gzip = new GZipStream(source, CompressionMode.Decompress, false))
            using (var output = new MemoryStream())
            {
                var buffer = new byte[8192];
                while (true)
                {
                    var read = gzip.Read(buffer, 0, buffer.Length);
                    if (read <= 0) break;
                    if (output.Length + read > maximum)
                        throw new InvalidDataException("The website response exceeded Clipman's decompression safety limit.");
                    output.Write(buffer, 0, read);
                }
                return output.ToArray();
            }
        }

        private static byte[] ReadExact(Stream stream, int count)
        {
            var output = new byte[count];
            var offset = 0;
            while (offset < count)
            {
                var read = stream.Read(output, offset, count - offset);
                if (read <= 0) throw new EndOfStreamException("The website response ended unexpectedly.");
                offset += read;
            }
            return output;
        }

        private static byte[] ReadChunked(Stream stream, int maximum)
        {
            using (var output = new MemoryStream())
            {
                while (true)
                {
                    var line = ReadAsciiLine(stream, 8192);
                    var semicolon = line.IndexOf(';');
                    if (semicolon >= 0) line = line.Substring(0, semicolon);
                    int size;
                    if (!int.TryParse(line.Trim(), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out size) || size < 0)
                        throw new InvalidDataException("The website returned invalid chunked data.");
                    if (size == 0)
                    {
                        var trailerBytes = 0;
                        while (true)
                        {
                            var trailer = ReadAsciiLine(stream, 8192);
                            trailerBytes += trailer.Length + 2;
                            if (trailerBytes > MaximumHeaderBytes) throw new InvalidDataException("The website returned oversized HTTP trailers.");
                            if (trailer.Length == 0) return output.ToArray();
                        }
                    }
                    if (output.Length + size > maximum)
                    {
                        var remaining = maximum - (int)output.Length;
                        if (remaining > 0)
                        {
                            var prefix = ReadExact(stream, remaining);
                            output.Write(prefix, 0, prefix.Length);
                        }
                        return output.ToArray();
                    }
                    var chunk = ReadExact(stream, size);
                    output.Write(chunk, 0, chunk.Length);
                    if (stream.ReadByte() != 13 || stream.ReadByte() != 10) throw new InvalidDataException("The website returned invalid chunk framing.");
                }
            }
        }

        private static string ReadAsciiLine(Stream stream, int maximumBytes)
        {
            using (var output = new MemoryStream())
            {
                var previous = -1;
                while (output.Length < maximumBytes)
                {
                    var value = stream.ReadByte();
                    if (value < 0) throw new EndOfStreamException("The website response ended unexpectedly.");
                    if (previous == 13 && value == 10)
                    {
                        var bytes = output.ToArray();
                        return Encoding.ASCII.GetString(bytes, 0, Math.Max(0, bytes.Length - 1));
                    }
                    output.WriteByte((byte)value);
                    previous = value;
                }
            }
            throw new InvalidDataException("The website returned an oversized HTTP line.");
        }

        private static string CharacterSet(string contentType)
        {
            var match = Regex.Match(contentType ?? string.Empty, "(?:^|;)\\s*charset\\s*=\\s*(?:\"([^\"]+)\"|'([^']+)'|([^;\\s]+))", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            if (!match.Success) return string.Empty;
            return match.Groups[1].Success ? match.Groups[1].Value : match.Groups[2].Success ? match.Groups[2].Value : match.Groups[3].Value;
        }

        private static string Decode(byte[] bytes, string charset)
        {
            if (bytes == null) return string.Empty;
            try
            {
                if (!string.IsNullOrWhiteSpace(charset)) return Encoding.GetEncoding(charset.Trim()).GetString(bytes);
            }
            catch { }
            return Encoding.UTF8.GetString(bytes);
        }

        internal static string ExtractTitle(string html, string host)
        {
            if (string.IsNullOrEmpty(html)) return string.Empty;
            var metadata = RetainMetadata(html, MaximumMetadataCharacters);
            string openGraph = null;
            string twitter = null;
            foreach (Match match in Regex.Matches(metadata, @"<meta\b[^>]{0,4096}>", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
            {
                var tag = match.Value;
                var key = Attribute(tag, "property");
                if (key.Length == 0) key = Attribute(tag, "name");
                if (key.Length == 0) key = Attribute(tag, "itemprop");
                var content = Attribute(tag, "content");
                if (key.Equals("og:title", StringComparison.OrdinalIgnoreCase) && openGraph == null && !string.IsNullOrWhiteSpace(content)) openGraph = content;
                if (key.Equals("twitter:title", StringComparison.OrdinalIgnoreCase) && twitter == null && !string.IsNullOrWhiteSpace(content)) twitter = content;
            }
            var titleMatch = Regex.Match(metadata, @"<title\b[^>]*>(.*?)</title\s*>", RegexOptions.IgnoreCase | RegexOptions.Singleline | RegexOptions.CultureInvariant);
            var headingMatch = Regex.Match(metadata, @"<h1\b[^>]*>(.*?)</h1\s*>", RegexOptions.IgnoreCase | RegexOptions.Singleline | RegexOptions.CultureInvariant);
            var candidates = new[]
            {
                openGraph,
                twitter,
                titleMatch.Success ? titleMatch.Groups[1].Value : null,
                headingMatch.Success ? headingMatch.Groups[1].Value : null
            };
            foreach (var candidate in candidates)
            {
                var title = SanitizeTitle(candidate);
                if (title.Length == 0 || IsJunkTitle(title) || title.Equals(host ?? string.Empty, StringComparison.OrdinalIgnoreCase)) continue;
                return title;
            }
            return string.Empty;
        }

        private static string RetainMetadata(string html, int maximumCharacters)
        {
            var output = new StringBuilder(Math.Min(maximumCharacters, html.Length));
            var index = 0;
            while (index < html.Length && output.Length < maximumCharacters)
            {
                if (StartsWith(html, index, "<!--"))
                {
                    var commentEnd = html.IndexOf("-->", index + 4, StringComparison.Ordinal);
                    index = commentEnd < 0 ? html.Length : commentEnd + 3;
                    continue;
                }
                if (html[index] != '<')
                {
                    var nextTag = html.IndexOf('<', index);
                    if (nextTag < 0) nextTag = html.Length;
                    AppendWithinLimit(output, html, index, nextTag - index, maximumCharacters);
                    index = nextTag;
                    continue;
                }
                var tagEnd = FindTagEnd(html, index);
                if (tagEnd < 0) break;
                var tag = html.Substring(index, tagEnd - index + 1);
                var closing = false;
                var tagName = TagName(tag, out closing);
                if (!closing && NonMetadataElements.Contains(tagName, StringComparer.OrdinalIgnoreCase) && !tag.TrimEnd().EndsWith("/>", StringComparison.Ordinal))
                {
                    var closeStart = html.IndexOf("</" + tagName, tagEnd + 1, StringComparison.OrdinalIgnoreCase);
                    if (closeStart < 0) break;
                    var closeEnd = FindTagEnd(html, closeStart);
                    index = closeEnd < 0 ? html.Length : closeEnd + 1;
                    continue;
                }
                AppendWithinLimit(output, tag, 0, tag.Length, maximumCharacters);
                index = tagEnd + 1;
                if (closing && tagName.Equals("head", StringComparison.OrdinalIgnoreCase) &&
                    output.ToString().IndexOf("og:title", StringComparison.OrdinalIgnoreCase) >= 0 &&
                    output.ToString().IndexOf("<title", StringComparison.OrdinalIgnoreCase) >= 0) break;
            }
            return output.ToString();
        }

        private static bool StartsWith(string value, int index, string prefix)
        {
            return index >= 0 && index + prefix.Length <= value.Length &&
                string.Compare(value, index, prefix, 0, prefix.Length, StringComparison.Ordinal) == 0;
        }

        private static int FindTagEnd(string value, int start)
        {
            var quote = '\0';
            for (var index = start + 1; index < value.Length; index++)
            {
                var current = value[index];
                if (quote != '\0')
                {
                    if (current == quote) quote = '\0';
                }
                else if (current == '\'' || current == '"') quote = current;
                else if (current == '>') return index;
            }
            return -1;
        }

        private static string TagName(string tag, out bool closing)
        {
            closing = false;
            if (string.IsNullOrEmpty(tag) || tag[0] != '<') return string.Empty;
            var index = 1;
            while (index < tag.Length && char.IsWhiteSpace(tag[index])) index++;
            if (index < tag.Length && tag[index] == '/')
            {
                closing = true;
                index++;
            }
            while (index < tag.Length && char.IsWhiteSpace(tag[index])) index++;
            var start = index;
            while (index < tag.Length && (char.IsLetterOrDigit(tag[index]) || tag[index] == ':' || tag[index] == '-')) index++;
            return index > start ? tag.Substring(start, index - start).ToLowerInvariant() : string.Empty;
        }

        private static void AppendWithinLimit(StringBuilder output, string value, int start, int count, int maximum)
        {
            var remaining = maximum - output.Length;
            if (remaining <= 0 || count <= 0) return;
            output.Append(value, start, Math.Min(count, remaining));
        }

        private static string Attribute(string tag, string name)
        {
            var match = Regex.Match(tag, "\\b" + Regex.Escape(name) + "\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            if (!match.Success) return string.Empty;
            return match.Groups[1].Success ? match.Groups[1].Value : match.Groups[2].Success ? match.Groups[2].Value : match.Groups[3].Value;
        }

        internal static string SanitizeTitle(string value)
        {
            var decoded = HttpUtility.HtmlDecode(value ?? string.Empty);
            decoded = Regex.Replace(decoded, @"<[^>]+>", " ", RegexOptions.CultureInvariant);
            var sanitized = LinkPresentation.SanitizeLabel(decoded, 200);
            return sanitized.Trim(' ', '|', '-', '\u2013', '\u2014', '\u00b7', '\u00bb', '<');
        }

        private static bool IsJunkTitle(string title)
        {
            var normalized = Regex.Replace(title ?? string.Empty, @"\s+", " ", RegexOptions.CultureInvariant)
                .Trim()
                .Trim('.', '!', '|', '-', '\u2013', '\u2014')
                .Trim()
                .ToLowerInvariant();
            return JunkTitleExactMatches.Contains(normalized, StringComparer.Ordinal) ||
                JunkTitleSubstrings.Any(value => normalized.IndexOf(value, StringComparison.Ordinal) >= 0);
        }

        private static LinkTitleFetchResult Failure(LinkTitleFetchResult result, string error)
        {
            result.Success = false;
            result.Error = error ?? "The website title could not be retrieved.";
            return result;
        }
    }
}
