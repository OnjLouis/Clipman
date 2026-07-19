using System;
using System.IO;
using System.Net;
using System.Text;

namespace Clipman
{
    internal sealed class ServerStorageClient
    {
        private readonly string baseUrl;
        private readonly string token;
        private readonly string databaseId;

        public ServerStorageClient(string serverUrl, string token, string databasePassword)
        {
            baseUrl = NormalizeBaseUrl(serverUrl);
            this.token = ServerSettingsSanitizer.CleanToken(token);
            databaseId = ServerDatabaseIdentity.FromTokenAndPassword(this.token, databasePassword);
        }

        public bool IsConfigured
        {
            get { return baseUrl.Length > 0 && token.Trim().Length > 0 && databaseId.Length > 0; }
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
                throw new InvalidOperationException("Clipman server host and token are required.");
            }

            var request = (HttpWebRequest)WebRequest.Create(new Uri(new Uri(baseUrl), relativePath));
            request.Method = method;
            request.Timeout = 8000;
            request.ReadWriteTimeout = 8000;
            request.Headers["Authorization"] = "Bearer " + token.Trim();
            request.UserAgent = "Clipman/" + VersionString();
            return request;
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
            return version == null ? "2.0.3" : version.ToString();
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
