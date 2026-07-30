using System;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace Clipman
{
    internal sealed class ServerStorageClient
    {
        private readonly string baseUrl;
        private readonly string token;
        private readonly string databaseId;
        private readonly bool hasDatabasePassword;
        private readonly X509Certificate2 privateAuthority;

        public ServerStorageClient(
            string serverUrl,
            string token,
            string databasePassword,
            string caCertPem,
            string caHost)
        {
            baseUrl = NormalizeBaseUrl(serverUrl);
            this.token = ServerSettingsSanitizer.CleanToken(token);
            hasDatabasePassword = !string.IsNullOrEmpty(databasePassword);
            databaseId = ServerDatabaseIdentity.FromTokenAndPassword(this.token, databasePassword);
            privateAuthority = ParsePrivateAuthority(caCertPem, caHost, serverUrl);
        }

        public bool IsConfigured
        {
            get { return baseUrl.Length > 0 && token.Trim().Length > 0 && hasDatabasePassword && databaseId.Length > 0; }
        }

        public ServerDatabaseMetadata GetMetadata()
        {
            var request = CreateRequest(DatabasePath(), "HEAD");
            using (var response = (HttpWebResponse)request.GetResponse())
            {
                return MetadataFromResponse(response);
            }
        }

        public ServerDatabaseDownload Download()
        {
            var request = CreateRequest(DatabasePath(), "GET");
            using (var response = (HttpWebResponse)request.GetResponse())
            using (var memory = new MemoryStream())
            {
                response.GetResponseStream().CopyTo(memory);
                return new ServerDatabaseDownload
                {
                    Metadata = MetadataFromResponse(response),
                    Data = memory.ToArray()
                };
            }
        }

        public ServerDatabaseMetadata Upload(byte[] data, string expectedRevision)
        {
            var request = CreateRequest(DatabasePath(), "PUT");
            if (!string.IsNullOrWhiteSpace(expectedRevision))
            {
                request.Headers["If-Match"] = "\"" + expectedRevision.Trim('"') + "\"";
            }
            request.ContentType = "application/octet-stream";
            request.ContentLength = data == null ? 0 : data.Length;
            using (var output = request.GetRequestStream())
            {
                if (data != null && data.Length > 0)
                {
                    output.Write(data, 0, data.Length);
                }
            }
            using (var response = (HttpWebResponse)request.GetResponse())
            {
                return MetadataFromResponse(response);
            }
        }

        public bool IsNotFound(WebException ex)
        {
            var response = ex == null ? null : ex.Response as HttpWebResponse;
            return response != null && response.StatusCode == HttpStatusCode.NotFound;
        }

        public bool IsConflict(WebException ex)
        {
            var response = ex == null ? null : ex.Response as HttpWebResponse;
            return response != null && response.StatusCode == HttpStatusCode.Conflict;
        }

        private HttpWebRequest CreateRequest(string relativePath, string method)
        {
            if (!IsConfigured)
            {
                throw new InvalidOperationException("Clipman server host, token, and history password are required.");
            }

            NetworkSecurity.EnableModernTls();
            var request = (HttpWebRequest)WebRequest.Create(new Uri(new Uri(baseUrl), relativePath));
            request.Method = method;
            request.Timeout = 8000;
            request.ReadWriteTimeout = 8000;
            request.AllowAutoRedirect = false;
            request.Headers["Authorization"] = "Bearer " + token.Trim();
            request.UserAgent = "Clipman/" + VersionString();
            if (privateAuthority != null)
            {
                request.ServerCertificateValidationCallback = ValidatePrivateAuthority;
            }
            return request;
        }

        private bool ValidatePrivateAuthority(
            object sender,
            X509Certificate certificate,
            X509Chain suppliedChain,
            SslPolicyErrors errors)
        {
            if (certificate == null || privateAuthority == null) return false;
            if ((errors & SslPolicyErrors.RemoteCertificateNameMismatch) != 0 ||
                (errors & SslPolicyErrors.RemoteCertificateNotAvailable) != 0)
            {
                return false;
            }

            using (var leaf = new X509Certificate2(certificate))
            using (var chain = new X509Chain())
            {
                chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
                chain.ChainPolicy.VerificationFlags = X509VerificationFlags.AllowUnknownCertificateAuthority;
                chain.ChainPolicy.ApplicationPolicy.Add(new Oid("1.3.6.1.5.5.7.3.1"));
                chain.ChainPolicy.ExtraStore.Add(privateAuthority);
                if (suppliedChain != null)
                {
                    foreach (X509ChainElement element in suppliedChain.ChainElements)
                    {
                        if (!string.Equals(element.Certificate.Thumbprint, leaf.Thumbprint, StringComparison.OrdinalIgnoreCase))
                        {
                            chain.ChainPolicy.ExtraStore.Add(element.Certificate);
                        }
                    }
                }

                chain.Build(leaf);
                foreach (X509ChainStatus status in chain.ChainStatus)
                {
                    if (status.Status != X509ChainStatusFlags.NoError &&
                        status.Status != X509ChainStatusFlags.UntrustedRoot)
                    {
                        return false;
                    }
                }
                if (chain.ChainElements.Count == 0) return false;
                var root = chain.ChainElements[chain.ChainElements.Count - 1].Certificate;
                return ByteArraysEqual(root.RawData, privateAuthority.RawData);
            }
        }

        private static X509Certificate2 ParsePrivateAuthority(string pem, string expectedHost, string serverUrl)
        {
            if (string.IsNullOrWhiteSpace(pem)) return null;
            ServerCertificateAuthority authority;
            string error;
            if (!ServerSettingsSanitizer.TryParseCertificateAuthority(pem, serverUrl, out authority, out error) ||
                authority == null)
            {
                throw new InvalidDataException("Clipman could not use the configured private certificate authority: " + error);
            }
            if (!string.IsNullOrWhiteSpace(expectedHost) &&
                !string.Equals(expectedHost.Trim(), authority.Host, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("The private certificate authority is configured for a different server host.");
            }
            return new X509Certificate2(authority.RawData);
        }

        private static bool ByteArraysEqual(byte[] first, byte[] second)
        {
            if (first == null || second == null || first.Length != second.Length) return false;
            var difference = 0;
            for (var index = 0; index < first.Length; index++)
            {
                difference |= first[index] ^ second[index];
            }
            return difference == 0;
        }

        private static ServerDatabaseMetadata MetadataFromResponse(HttpWebResponse response)
        {
            return new ServerDatabaseMetadata
            {
                Revision = CleanRevision(response.Headers["X-Clipman-Revision"] ?? response.Headers["ETag"]),
                Length = response.ContentLength < 0 ? 0 : response.ContentLength
            };
        }

        private static string NormalizeBaseUrl(string value)
        {
            var url = ServerSettingsSanitizer.CleanTransportUrl(value);
            if (url.Length == 0) return string.Empty;
            if (!url.EndsWith("/", StringComparison.Ordinal)) url += "/";
            return url;
        }

        private string DatabasePath()
        {
            return "api/v1/database/" + Uri.EscapeDataString(databaseId);
        }

        private static string CleanRevision(string value)
        {
            return (value ?? string.Empty).Trim().Trim('"');
        }

        private static string VersionString()
        {
            var version = typeof(ServerStorageClient).Assembly.GetName().Version;
            return version == null ? "unknown" : version.ToString();
        }
    }

    internal sealed class ServerDatabaseMetadata
    {
        public string Revision { get; set; }
        public long Length { get; set; }

        public ServerDatabaseMetadata()
        {
            Revision = string.Empty;
        }
    }

    internal sealed class ServerDatabaseDownload
    {
        public ServerDatabaseMetadata Metadata { get; set; }
        public byte[] Data { get; set; }

        public ServerDatabaseDownload()
        {
            Metadata = new ServerDatabaseMetadata();
            Data = new byte[0];
        }
    }
}
