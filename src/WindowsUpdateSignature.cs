using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Clipman
{
    internal static class WindowsUpdateSignature
    {
        internal const int SignatureBytes = 384;
        internal const string SignatureSuffix = ".sig";
        private const string PackagePrefix = "Clipman-Windows-x64-";
        private const string PublisherKey = "<RSAKeyValue><Modulus>vBj6wQnvb2sxygX30URel/RMZSfIrqWbhXitfs00toVifdUMHsSFibHwLKlTMcojGcPm2B+Y9OJHS/zMbKuH6gAE3YUZx6fM1E8pOrUbkD5Ojgf/e7kYi0xc13Uvi9iefE9pr4IPTz8uy//8XwkgOxdU0FWAGBsx4sc8vYF6i8VrHyDTkC7CNQLwaFypni7XbGTwq5dg1K5D70lx8cf5riw4wCQt3ilUd38EZNkl6AN6Iuax8ku8EEzoUz/fb6tKc2m+On8Fm47dO76o/DCxJeGoITD/DDcZVuAouQqsbFDWr2v2XNGYfZ/KpS3KRdnAoFkefiSfQExkk46Kcwx+MkCSBDPXT5QyN0YyIYMxuVSrsa4sA59HZ1BvKzpX34FlwXW4ltOV076iF0WO5bQJKnmh65JwbDvKAOXkXffmOchReNLRm4l7BZjPABAT+d3HJscbN3qRoTtnZMJLyVqpzlysf9jAUxUSdMmgR/1A+Jp8hkTvzetrHJqAXrVhO1ud</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>";

        internal static string PackageName(Version version)
        {
            return PackagePrefix + version.ToString(3) + ".zip";
        }

        internal static Version DownloadVersion(string url)
        {
            Uri uri;
            if (!Uri.TryCreate(url, UriKind.Absolute, out uri)) return null;
            var segments = uri.AbsolutePath.Split('/');
            Version version;
            if (segments.Length != 7 || !Version.TryParse(segments[5].TrimStart('v'), out version) ||
                version.Build < 0 || version.Revision >= 0 ||
                !string.Equals(url, DownloadUrl(version), StringComparison.Ordinal)) return null;
            return version;
        }

        internal static string DownloadUrl(Version version)
        {
            return UpdateService.ProjectUrl + "/releases/download/v" + version.ToString(3) + "/" + PackageName(version);
        }

        internal static void Verify(Stream archive, byte[] signature, Version version)
        {
            Verify(archive, signature, version, PublisherKey);
        }

        internal static void Verify(Stream archive, byte[] signature, Version version, string publicKey)
        {
            if (signature == null || signature.Length != SignatureBytes)
            {
                throw new InvalidDataException("The Windows update publisher signature is missing or malformed.");
            }

            string digest;
            using (var sha256 = SHA256.Create())
            {
                digest = BitConverter.ToString(sha256.ComputeHash(archive)).Replace("-", "").ToLowerInvariant();
            }

            // Include product, platform and version so another signed asset cannot be replayed as this update.
            var message = Encoding.ASCII.GetBytes("Clipman Windows x64 ZIP\n" + version.ToString(3) + "\n" + digest + "\n");
            using (var rsa = new RSACryptoServiceProvider(new CspParameters(24) { Flags = CspProviderFlags.CreateEphemeralKey }))
            {
                rsa.FromXmlString(publicKey);
                if (!rsa.VerifyData(message, CryptoConfig.MapNameToOID("SHA256"), signature))
                {
                    throw new InvalidDataException("The Windows update publisher signature is invalid.");
                }
            }
        }
    }
}
