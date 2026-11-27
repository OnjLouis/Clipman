using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Threading;
using System.Windows.Forms;

namespace Clipman
{
    internal static partial class Program
    {
        private const int MaximumWindowsUpdateBytes = 64 * 1024 * 1024;

        private static void ApplyUpdateFromCommandLine(string[] args)
        {
            string targetDir;
            string exePath;
            var noRestart = args.Any(arg => string.Equals(arg, "--update-no-restart", StringComparison.OrdinalIgnoreCase));
            TryGetOptionValue(args, "--update-target", out targetDir);
            TryGetOptionValue(args, "--update-exe", out exePath);
            var canRestart = false;
            try
            {
                string zipUrl;
                string tempBase;
                string pidText;
                TryGetOptionValue(args, "--update-url", out zipUrl);
                TryGetOptionValue(args, "--update-temp", out tempBase);
                TryGetOptionValue(args, "--update-wait-pid", out pidText);

                if (string.IsNullOrWhiteSpace(zipUrl) ||
                    string.IsNullOrWhiteSpace(targetDir) ||
                    string.IsNullOrWhiteSpace(exePath))
                {
                    throw new InvalidOperationException("The updater was not given enough information to install the update.");
                }

                exePath = Path.GetFullPath(exePath);
                targetDir = Path.GetFullPath(targetDir).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                if (!string.Equals(exePath, Path.Combine(targetDir, "clipman.exe"), StringComparison.OrdinalIgnoreCase) || !File.Exists(exePath))
                {
                    throw new InvalidOperationException("The updater must target an existing Clipman installation.");
                }

                WriteUpdateHistory(targetDir, "Update command received.");
                int processId;
                if (int.TryParse(pidText, out processId) && processId > 0)
                {
                    WriteUpdateHistory(targetDir, "Waiting for Clipman process " + processId + " to exit.");
                    WaitForProcessExit(processId);
                }

                canRestart = !noRestart;
                ApplyWindowsUpdate(zipUrl, targetDir, exePath, string.IsNullOrWhiteSpace(tempBase) ? Path.GetTempPath() : tempBase, noRestart, DownloadUpdateFile);
            }
            catch (Exception ex)
            {
                WriteUpdateHistory(args, "ERROR: " + ex.Message);
                WriteUpdaterLog(args, ex);
                Environment.ExitCode = 1;
                if (canRestart && !(ex is UpdateRollbackException)) TryRestartUpdatedApp(exePath, targetDir);
                if (noRestart) return;
                MessageBox.Show(
                    "Clipman update failed:" + Environment.NewLine + Environment.NewLine + ex.Message,
                    "Clipman updater",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
        }

        internal static void ApplyWindowsUpdate(string zipUrl, string targetDir, string exePath, string tempBase, bool noRestart, Action<Uri, Stream, int> download)
        {
            var version = WindowsUpdateSignature.DownloadVersion(zipUrl);
            var current = InstalledUpdateVersion(exePath);
            if (version == null || version <= current)
            {
                throw new InvalidDataException("The update must be a newer Windows release from the Clipman project.");
            }

            tempBase = Path.GetFullPath(tempBase).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (string.Equals(tempBase, targetDir, StringComparison.OrdinalIgnoreCase) ||
                tempBase.StartsWith(targetDir + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("The Windows update must be staged outside the installed folder.");
            }
            CheckUpdatePath(tempBase, true);
            Directory.CreateDirectory(tempBase);
            var root = Path.Combine(tempBase, "ClipmanUpdate_" + Guid.NewGuid().ToString("N"));
            var zip = Path.Combine(root, "update.zip");
            var stage = Path.Combine(root, "stage");
            Directory.CreateDirectory(root);
            Directory.CreateDirectory(stage);

            try
            {
                WriteUpdateHistory(targetDir, "Downloading update publisher signature and ZIP.");
                byte[] signature;
                using (var signatureFile = new MemoryStream())
                {
                    download(new Uri(zipUrl + WindowsUpdateSignature.SignatureSuffix), signatureFile, WindowsUpdateSignature.SignatureBytes);
                    signature = signatureFile.ToArray();
                }
                using (var archive = new FileStream(zip, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
                {
                    download(new Uri(zipUrl), archive, MaximumWindowsUpdateBytes);
                    archive.Position = 0;
                    ExtractVerifiedWindowsUpdate(archive, signature, version, stage);
                }
                if (InstalledUpdateVersion(Path.Combine(stage, "clipman.exe")) != version)
                {
                    throw new InvalidDataException("The signed Windows update executable does not match the release version.");
                }

                WriteUpdateHistory(targetDir, "Requesting other shared-folder instances to close.");
                SharedUpdateStateStore.PublishCloseRequest(Path.Combine(targetDir, "Settings"), exePath, 90);
                Thread.Sleep(5000);

                WriteUpdateHistory(targetDir, "Publisher signature verified. Applying files.");
                if (InstalledUpdateVersion(exePath) >= version)
                {
                    throw new InvalidDataException("Another update already installed this version or a newer version of Clipman.");
                }
                InstallWindowsUpdate(stage, targetDir, current);
            }
            finally
            {
                TryDeleteDirectory(root);
            }

            if (noRestart)
            {
                WriteUpdateHistory(targetDir, "Update applied. Restart skipped by command line.");
                return;
            }

            WriteUpdateHistory(targetDir, "Update applied. Restarting Clipman.");
            TryRestartUpdatedApp(exePath, targetDir);
        }

        private static void CleanupObsoleteRootUpdateFolders(string targetDir)
        {
            var rootUpdateBackups = Path.Combine(targetDir, "Update Backups");
            if (Directory.Exists(rootUpdateBackups))
            {
                TryDeleteDirectory(rootUpdateBackups);
            }

            TryDeleteDirectory(Path.Combine(targetDir, "Backups\\Updates"));
            TryDeleteDirectory(Path.Combine(targetDir, "Update Temp"));
            CleanupEmptyBackupFolders(targetDir);
        }

        private static void CleanupStaleUpdaterLaunchers(string appDirectory)
        {
            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var roots = new[]
            {
                string.IsNullOrWhiteSpace(localAppData) ? string.Empty : Path.Combine(localAppData, "Temp"),
                Path.GetTempPath(),
                Path.Combine(appDirectory, "Settings", "Update Temp")
            }
            .Where(path => !string.IsNullOrWhiteSpace(path))
            .Select(path => Path.GetFullPath(path))
            .Distinct(StringComparer.OrdinalIgnoreCase);

            var cutoff = DateTime.UtcNow.AddMinutes(-5);
            foreach (var root in roots)
            {
                try
                {
                    if (!Directory.Exists(root)) continue;
                    foreach (var folder in Directory.GetDirectories(root, "ClipmanUpdater-*", SearchOption.TopDirectoryOnly))
                    {
                        try
                        {
                            if (Directory.GetLastWriteTimeUtc(folder) > cutoff) continue;
                            Directory.Delete(folder, true);
                        }
                        catch
                        {
                        }
                    }
                }
                catch
                {
                }
            }
        }

        private static void CleanupObsoleteFactorySoundBackups(string targetDir)
        {
            try
            {
                var backupRoots = new[]
                {
                    Path.Combine(targetDir, "Backups\\Updates"),
                    Path.Combine(targetDir, "Update Backups")
                };

                foreach (var root in backupRoots)
                {
                    if (!Directory.Exists(root)) continue;

                    foreach (var file in Directory.GetFiles(root, "Previous-sounds*.zip", SearchOption.AllDirectories))
                    {
                        TryDeleteFile(file);
                    }

                    foreach (var folder in Directory.GetDirectories(root, "Previous-sounds*", SearchOption.AllDirectories)
                        .OrderByDescending(path => path.Length))
                    {
                        TryDeleteDirectory(folder);
                    }
                }
            }
            catch
            {
            }
        }

        private static void ExtractVerifiedWindowsUpdate(Stream archive, byte[] signature, Version version, string stage)
        {
            WindowsUpdateSignature.Verify(archive, signature, version);
            archive.Position = 0;
            using (var zip = new ZipArchive(archive, ZipArchiveMode.Read, true))
            {
                zip.ExtractToDirectory(stage);
            }
        }

        private static void DownloadUpdateFile(Uri url, Stream destination, int maximumBytes)
        {
            NetworkSecurity.EnableModernTls();
            for (var redirects = 0; redirects < 6; redirects++)
            {
                if (url.Scheme != Uri.UriSchemeHttps || !string.IsNullOrEmpty(url.UserInfo) || !url.IsDefaultPort)
                {
                    throw new InvalidDataException("The Windows update download must use HTTPS.");
                }

                var request = (HttpWebRequest)WebRequest.Create(url);
                request.UserAgent = "Clipman updater";
                request.AllowAutoRedirect = false;
                request.Timeout = 30000;
                request.ReadWriteTimeout = 30000;
                try
                {
                    using (var response = (HttpWebResponse)request.GetResponse())
                    {
                        var status = (int)response.StatusCode;
                        if (status >= 300 && status < 400)
                        {
                            if (!Uri.TryCreate(url, response.Headers[HttpResponseHeader.Location], out url))
                            {
                                throw new InvalidDataException("The Windows update returned an invalid download location.");
                            }
                            continue;
                        }
                        if (status != 200 || response.ContentLength > maximumBytes)
                        {
                            throw new InvalidDataException("The Windows update download has an unexpected response or size.");
                        }
                        using (var input = response.GetResponseStream())
                        {
                            var buffer = new byte[65536];
                            var time = Stopwatch.StartNew();
                            int count;
                            while ((count = input.Read(buffer, 0, buffer.Length)) != 0)
                            {
                                if (destination.Length + count > maximumBytes || time.Elapsed.TotalSeconds > 120)
                                {
                                    throw new InvalidDataException("The Windows update download exceeded its size or time limit.");
                                }
                                destination.Write(buffer, 0, count);
                            }
                        }
                        return;
                    }
                }
                catch (WebException error)
                {
                    if (error.Response != null) error.Response.Close();
                    var fileName = maximumBytes == WindowsUpdateSignature.SignatureBytes ? "publisher signature" : "ZIP";
                    throw new IOException("Could not download the Windows update " + fileName + ".", error);
                }
            }
            throw new InvalidDataException("The Windows update exceeded its download redirect limit.");
        }

        private static void WaitForProcessExit(int processId)
        {
            try
            {
                using (var process = Process.GetProcessById(processId))
                {
                    if (!process.WaitForExit(30000))
                    {
                        throw new IOException("Clipman is still running. Close it before trying the update again.");
                    }
                }
            }
            catch (ArgumentException)
            {
            }
        }

        private static void TryRestartUpdatedApp(string exePath, string targetDir)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(exePath) || !File.Exists(exePath))
                {
                    throw new FileNotFoundException("The updated Clipman executable could not be found.", exePath ?? string.Empty);
                }

                var workingDirectory = Directory.Exists(targetDir) ? targetDir : Path.GetDirectoryName(exePath);
                Process.Start(new ProcessStartInfo
                {
                    FileName = exePath,
                    WorkingDirectory = workingDirectory,
                    UseShellExecute = true
                });
            }
            catch (Exception ex)
            {
                WriteUpdaterLog(null, ex);
                MessageBox.Show(
                    "Clipman was updated, but it could not be restarted automatically." +
                    Environment.NewLine +
                    Environment.NewLine +
                    "Please start Clipman from its installed folder or shortcut." +
                    Environment.NewLine +
                    Environment.NewLine +
                    ex.Message,
                    "Clipman updater",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
            }
        }

        private static void RemoveEmptyDirectory(string folder)
        {
            try
            {
                if (Directory.Exists(folder) && !Directory.GetFileSystemEntries(folder).Any())
                {
                    Directory.Delete(folder);
                }
            }
            catch
            {
            }
        }

        private static void CleanupEmptyBackupFolders(string targetDir)
        {
            try
            {
                var backups = Path.Combine(targetDir, "Backups");
                if (!Directory.Exists(backups)) return;
                foreach (var folder in Directory.GetDirectories(backups, "*", SearchOption.AllDirectories).OrderByDescending(p => p.Length))
                {
                    RemoveEmptyDirectory(folder);
                }

                RemoveEmptyDirectory(Path.Combine(backups, "Updates"));
                RemoveEmptyDirectory(backups);
            }
            catch
            {
            }
        }

        private static void TryDeleteDirectory(string path)
        {
            try
            {
                if (Directory.Exists(path))
                {
                    Directory.Delete(path, true);
                }
            }
            catch
            {
            }
        }

        private static void TryDeleteFile(string path)
        {
            try
            {
                if (File.Exists(path))
                {
                    File.Delete(path);
                }
            }
            catch
            {
            }
        }

        private static void WriteUpdaterLog(string[] args, Exception exception)
        {
            try
            {
                string targetDir;
                if (args == null || !TryGetOptionValue(args, "--update-target", out targetDir) || string.IsNullOrWhiteSpace(targetDir))
                {
                    targetDir = AppDomain.CurrentDomain.BaseDirectory;
                }

                var logRoot = Path.Combine(targetDir, "Logs");
                Directory.CreateDirectory(logRoot);
                File.AppendAllText(
                    Path.Combine(logRoot, "Updater.log"),
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") +
                    " Clipman updater error" +
                    Environment.NewLine +
                    (exception == null ? "(No exception object.)" : exception.ToString()) +
                    Environment.NewLine +
                    Environment.NewLine);
            }
            catch
            {
            }
        }

        private static void WriteUpdateHistory(string[] args, string message)
        {
            try
            {
                string targetDir;
                if (args == null || !TryGetOptionValue(args, "--update-target", out targetDir) || string.IsNullOrWhiteSpace(targetDir))
                {
                    targetDir = AppDomain.CurrentDomain.BaseDirectory;
                }

                WriteUpdateHistory(targetDir, message);
            }
            catch
            {
            }
        }

        private static void WriteUpdateHistory(string targetDir, string message)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(targetDir))
                {
                    targetDir = AppDomain.CurrentDomain.BaseDirectory;
                }

                var logRoot = Path.Combine(targetDir, "Logs");
                Directory.CreateDirectory(logRoot);
                File.AppendAllText(
                    Path.Combine(logRoot, "Update.log"),
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") +
                    " " +
                    (string.IsNullOrWhiteSpace(message) ? "(no update message)" : message) +
                    Environment.NewLine);
            }
            catch
            {
            }
        }
    }
}
