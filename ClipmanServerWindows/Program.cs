using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace ClipmanServerWrapper
{
    internal static class Program
    {
        private const string MutexName = "Local\\ClipmanPythonServerWrapper";

        [STAThread]
        private static int Main(string[] args)
        {
            if (ServerUpdateService.HandleCommandLine(args))
            {
                return 0;
            }

            bool created;
            using (var mutex = new Mutex(true, MutexName, out created))
            {
                if (!created)
                {
                    MessageBox.Show("Clipman Server is already running.", "Clipman Server", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return 0;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new ServerTrayContext(AppDomain.CurrentDomain.BaseDirectory));
            }

            return 0;
        }
    }

    internal sealed class ServerTrayContext : ApplicationContext
    {
        private const string StartupValueName = "Clipman Server";
        private readonly string appDirectory;
        private readonly string scriptPath;
        private readonly string settingsDirectory;
        private readonly string settingsPath;
        private readonly string logDirectory;
        private readonly string wrapperLogPath;
        private readonly NotifyIcon tray;
        private Process serverProcess;
        private bool quitting;

        public ServerTrayContext(string appDirectory)
        {
            this.appDirectory = appDirectory;
            settingsDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Clipman Server");
            settingsPath = Path.Combine(settingsDirectory, "clipman-server-settings.json");
            logDirectory = Path.Combine(settingsDirectory, "logs");
            wrapperLogPath = Path.Combine(logDirectory, "clipman-server-wrapper.log");
            scriptPath = Path.Combine(settingsDirectory, "Runtime", "clipman_server.py");

            Directory.CreateDirectory(settingsDirectory);
            Directory.CreateDirectory(logDirectory);
            ExtractBundledServerScript();

            tray = new NotifyIcon
            {
                Icon = SystemIcons.Application,
                Text = "Clipman Server: starting",
                Visible = true,
                ContextMenuStrip = BuildMenu()
            };

            StartServer();
        }

        private ContextMenuStrip BuildMenu()
        {
            var menu = new ContextMenuStrip();
            menu.Opening += delegate
            {
                menu.Items.Clear();
                menu.Items.Add("Clipman Server: " + StatusText()).Enabled = false;
                menu.Items.Add("Copy connection details", null, delegate { CopyConnectionDetails(); });
                menu.Items.Add("Open settings folder", null, delegate { OpenFolder(settingsDirectory); });
                menu.Items.Add("Open logs folder", null, delegate { OpenFolder(logDirectory); });
                menu.Items.Add("Check for updates", null, delegate { ServerUpdateService.CheckForUpdates(null, false, ExitThread); });
                var controlText = string.Equals(StatusText(), "running", StringComparison.OrdinalIgnoreCase) ? "Restart server" : "Start server";
                menu.Items.Add(controlText, null, delegate { RestartServer(); });
                var startup = new ToolStripMenuItem("Run at Windows startup") { Checked = IsStartupEnabled(), CheckOnClick = false };
                startup.Click += delegate { SetStartupEnabled(!IsStartupEnabled()); };
                menu.Items.Add(startup);
                menu.Items.Add(new ToolStripSeparator());
                menu.Items.Add("Quit", null, delegate { ExitThread(); });
            };
            return menu;
        }

        private string StatusText()
        {
            if (serverProcess == null)
            {
                return "stopped";
            }
            try
            {
                return serverProcess.HasExited ? "stopped" : "running";
            }
            catch
            {
                return "unknown";
            }
        }

        private void StartServer()
        {
            if (!File.Exists(scriptPath))
            {
                tray.Text = "Clipman Server: missing script";
                tray.ShowBalloonTip(5000, "Clipman Server", "The bundled server script could not be prepared. Open the logs folder for details.", ToolTipIcon.Error);
                return;
            }

            var python = FindPythonLauncher();
            if (python == null)
            {
                tray.Text = "Clipman Server: Python missing";
                tray.ShowBalloonTip(5000, "Clipman Server", "Python 3 was not found. Install Python 3, then restart Clipman Server.", ToolTipIcon.Error);
                return;
            }

            var start = new ProcessStartInfo
            {
                FileName = python.FileName,
                Arguments = python.ArgumentsPrefix + Quote(scriptPath) + " --config " + Quote(settingsPath),
                WorkingDirectory = appDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            };

            serverProcess = new Process { StartInfo = start, EnableRaisingEvents = true };
            serverProcess.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { LogLine(e.Data); };
            serverProcess.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { LogLine(e.Data); };
            serverProcess.Exited += delegate
            {
                if (!quitting)
                {
                    tray.Text = "Clipman Server: stopped";
                    tray.ShowBalloonTip(5000, "Clipman Server", "The server stopped. Use Restart server from the tray menu.", ToolTipIcon.Warning);
                }
            };

            try
            {
                serverProcess.Start();
                serverProcess.BeginOutputReadLine();
                serverProcess.BeginErrorReadLine();
                tray.Text = "Clipman Server: running";
                tray.ShowBalloonTip(2500, "Clipman Server", "Server started in the background.", ToolTipIcon.Info);
            }
            catch (Exception ex)
            {
                LogLine(ex.ToString());
                tray.Text = "Clipman Server: error";
                tray.ShowBalloonTip(5000, "Clipman Server", ex.Message, ToolTipIcon.Error);
            }
        }

        private void RestartServer()
        {
            StopServer();
            StartServer();
        }

        private void StopServer()
        {
            if (serverProcess == null)
            {
                return;
            }

            try
            {
                if (!serverProcess.HasExited)
                {
                    serverProcess.Kill();
                    serverProcess.WaitForExit(3000);
                }
            }
            catch
            {
            }
            finally
            {
                serverProcess.Dispose();
                serverProcess = null;
            }
        }

        private void CopyConnectionDetails()
        {
            var connectionPath = Path.Combine(settingsDirectory, "clipman-server-connection.txt");
            if (File.Exists(connectionPath))
            {
                Clipboard.SetText(File.ReadAllText(connectionPath, Encoding.UTF8));
                tray.ShowBalloonTip(2000, "Clipman Server", "Connection details copied.", ToolTipIcon.Info);
                return;
            }

            var settings = LoadSettings();
            if (settings == null)
            {
                tray.ShowBalloonTip(3000, "Clipman Server", "Connection details are not ready yet.", ToolTipIcon.Warning);
                return;
            }

            Clipboard.SetText("Server address:\r\n" + settings.Host + "\r\nPort:\r\n" + settings.Port + "\r\nToken:\r\n" + settings.AuthToken);
            tray.ShowBalloonTip(2000, "Clipman Server", "Connection details copied.", ToolTipIcon.Info);
        }

        private ServerSettings LoadSettings()
        {
            try
            {
                if (!File.Exists(settingsPath))
                {
                    return null;
                }
                return new JavaScriptSerializer().Deserialize<ServerSettings>(File.ReadAllText(settingsPath, Encoding.UTF8));
            }
            catch
            {
                return null;
            }
        }

        private bool IsStartupEnabled()
        {
            using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", false))
            {
                var value = key == null ? null : key.GetValue(StartupValueName) as string;
                return string.Equals(value, Quote(Application.ExecutablePath), StringComparison.OrdinalIgnoreCase);
            }
        }

        private void SetStartupEnabled(bool enabled)
        {
            using (var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
            {
                if (enabled)
                {
                    key.SetValue(StartupValueName, Quote(Application.ExecutablePath), RegistryValueKind.String);
                    tray.ShowBalloonTip(2000, "Clipman Server", "Clipman Server will run at Windows startup.", ToolTipIcon.Info);
                }
                else
                {
                    key.DeleteValue(StartupValueName, false);
                    tray.ShowBalloonTip(2000, "Clipman Server", "Clipman Server startup entry removed.", ToolTipIcon.Info);
                }
            }
        }

        private static PythonLauncher FindPythonLauncher()
        {
            var candidates = new[]
            {
                new PythonLauncher("py.exe", "-3 "),
                new PythonLauncher("pythonw.exe", ""),
                new PythonLauncher("python.exe", "")
            };

            foreach (var candidate in candidates)
            {
                try
                {
                    var test = new ProcessStartInfo
                    {
                        FileName = candidate.FileName,
                        Arguments = candidate.ArgumentsPrefix + "--version",
                        UseShellExecute = false,
                        CreateNoWindow = true,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true
                    };
                    using (var process = Process.Start(test))
                    {
                        process.WaitForExit(3000);
                        if (process.ExitCode == 0)
                        {
                            return candidate;
                        }
                    }
                }
                catch
                {
                }
            }

            return null;
        }

        private void LogLine(string line)
        {
            if (string.IsNullOrEmpty(line))
            {
                return;
            }

            try
            {
                File.AppendAllText(wrapperLogPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss ") + line + Environment.NewLine, Encoding.UTF8);
            }
            catch
            {
            }
        }

        private void ExtractBundledServerScript()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(scriptPath));
                var assembly = Assembly.GetExecutingAssembly();
                using (var input = assembly.GetManifestResourceStream("ClipmanServerWrapper.clipman_server.py"))
                {
                    if (input == null)
                    {
                        LogLine("Bundled clipman_server.py resource was not found.");
                        return;
                    }

                    using (var output = new MemoryStream())
                    {
                        input.CopyTo(output);
                        var bytes = output.ToArray();
                        if (File.Exists(scriptPath))
                        {
                            var existing = File.ReadAllBytes(scriptPath);
                            if (BytesEqual(existing, bytes))
                            {
                                return;
                            }
                        }

                        File.WriteAllBytes(scriptPath, bytes);
                    }
                }
            }
            catch (Exception ex)
            {
                LogLine(ex.ToString());
            }
        }

        private static bool BytesEqual(byte[] left, byte[] right)
        {
            if (left == null || right == null || left.Length != right.Length)
            {
                return false;
            }

            for (var i = 0; i < left.Length; i++)
            {
                if (left[i] != right[i])
                {
                    return false;
                }
            }

            return true;
        }

        private static void OpenFolder(string path)
        {
            Directory.CreateDirectory(path);
            Process.Start("explorer.exe", path);
        }

        private static string Quote(string path)
        {
            return "\"" + path.Replace("\"", "\\\"") + "\"";
        }

        protected override void ExitThreadCore()
        {
            quitting = true;
            tray.Visible = false;
            tray.Dispose();
            StopServer();
            base.ExitThreadCore();
        }
    }

    internal sealed class PythonLauncher
    {
        public string FileName { get; private set; }
        public string ArgumentsPrefix { get; private set; }

        public PythonLauncher(string fileName, string argumentsPrefix)
        {
            FileName = fileName;
            ArgumentsPrefix = argumentsPrefix;
        }
    }

    internal sealed class ServerSettings
    {
        public string Host { get; set; }
        public int Port { get; set; }
        public string AuthToken { get; set; }

        public ServerSettings()
        {
            Host = string.Empty;
            AuthToken = string.Empty;
        }
    }

    internal static class ServerUpdateService
    {
        private const string ProjectUrl = "https://github.com/OnjLouis/Clipman";
        private const string UserAgent = "Clipman Server updater";

        public static bool HandleCommandLine(string[] args)
        {
            if (args == null || args.Length == 0)
            {
                return false;
            }

            if (HasArg(args, "--help") || HasArg(args, "/?"))
            {
                MessageBox.Show(
                    "Clipman Server command line:" + Environment.NewLine +
                    "--version" + Environment.NewLine +
                    "--check-updates" + Environment.NewLine +
                    "--install-update [--silent]" + Environment.NewLine +
                    "--apply-update --update-url <url> --update-exe <path> --update-wait-pid <pid>",
                    "Clipman Server",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
                return true;
            }

            if (HasArg(args, "--version"))
            {
                MessageBox.Show(CurrentVersion(), "Clipman Server version", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return true;
            }

            if (HasArg(args, "--check-updates"))
            {
                CheckForUpdates(null, false, null);
                return true;
            }

            if (HasArg(args, "--install-update"))
            {
                CheckForUpdates(null, HasArg(args, "--silent") || HasArg(args, "--yes"), null);
                return true;
            }

            if (HasArg(args, "--apply-update"))
            {
                ApplyUpdateFromCommandLine(args);
                return true;
            }

            return false;
        }

        public static void CheckForUpdates(IWin32Window owner, bool installSilently, Action exitApp)
        {
            try
            {
                var release = LatestRelease();
                var remoteText = (release.TagName ?? string.Empty).Trim().TrimStart('v', 'V');
                Version current;
                Version remote;
                if (!Version.TryParse(CurrentVersion(), out current) || !Version.TryParse(remoteText, out remote))
                {
                    if (!installSilently) MessageBox.Show(owner, "Could not read the latest Clipman Server release version.", "Clipman Server updates", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                if (remote <= current)
                {
                    if (!installSilently) MessageBox.Show(owner, "Clipman Server is up to date. Current version: " + CurrentVersion() + ".", "Clipman Server updates", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                var asset = FindServerAsset(release);
                if (asset == null || string.IsNullOrWhiteSpace(asset.BrowserDownloadUrl))
                {
                    if (!installSilently) MessageBox.Show(owner, "Clipman Server " + remote + " is available, but no ClipmanServer ZIP asset was found.", "Clipman Server updates", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                if (!installSilently)
                {
                    var answer = MessageBox.Show(
                        owner,
                        "Clipman Server " + remote + " is available." + Environment.NewLine + Environment.NewLine +
                        "The server will close, download the server ZIP, replace this Windows server wrapper, and restart. Server settings and databases are kept in your user profile." + Environment.NewLine + Environment.NewLine +
                        "Do you want to update now?",
                        "Clipman Server updates",
                        MessageBoxButtons.YesNo,
                        MessageBoxIcon.Question,
                        MessageBoxDefaultButton.Button2);
                    if (answer != DialogResult.Yes)
                    {
                        return;
                    }
                }

                StartUpdate(asset.BrowserDownloadUrl, exitApp);
            }
            catch (Exception ex)
            {
                if (!installSilently)
                {
                    MessageBox.Show(owner, "Could not check for Clipman Server updates." + Environment.NewLine + Environment.NewLine + ex.Message, "Clipman Server updates", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
            }
        }

        private static void StartUpdate(string zipUrl, Action exitApp)
        {
            var exePath = Application.ExecutablePath;
            var tempRoot = Path.Combine(Path.GetTempPath(), "ClipmanServerUpdater-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(tempRoot);
            var updaterExe = Path.Combine(tempRoot, "Clipman Server Updater.exe");
            File.Copy(exePath, updaterExe, true);

            Process.Start(new ProcessStartInfo
            {
                FileName = updaterExe,
                Arguments =
                    "--apply-update" +
                    " --update-url " + Quote(zipUrl) +
                    " --update-exe " + Quote(exePath) +
                    " --update-wait-pid " + Process.GetCurrentProcess().Id,
                WorkingDirectory = tempRoot,
                UseShellExecute = false,
                CreateNoWindow = true
            });

            if (exitApp != null)
            {
                exitApp();
            }
            else
            {
                Application.Exit();
            }
        }

        private static void ApplyUpdateFromCommandLine(string[] args)
        {
            string zipUrl;
            string exePath;
            string pidText;
            TryGetOptionValue(args, "--update-url", out zipUrl);
            TryGetOptionValue(args, "--update-exe", out exePath);
            TryGetOptionValue(args, "--update-wait-pid", out pidText);

            try
            {
                if (string.IsNullOrWhiteSpace(zipUrl) || string.IsNullOrWhiteSpace(exePath))
                {
                    throw new InvalidOperationException("The updater was not given enough information to install the update.");
                }

                int pid;
                if (int.TryParse(pidText, out pid) && pid > 0)
                {
                    WaitForProcessExit(pid);
                }

                var root = Path.Combine(Path.GetTempPath(), "ClipmanServerUpdate_" + Guid.NewGuid().ToString("N"));
                var zip = Path.Combine(root, "server.zip");
                var stage = Path.Combine(root, "stage");
                Directory.CreateDirectory(stage);
                DownloadFile(zipUrl, zip);
                ZipFile.ExtractToDirectory(zip, stage);
                var sourceExe = Directory.GetFiles(stage, "Clipman Server.exe", SearchOption.AllDirectories)
                    .FirstOrDefault(path => path.IndexOf(Path.DirectorySeparatorChar + "Windows" + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) >= 0)
                    ?? Directory.GetFiles(stage, "Clipman Server.exe", SearchOption.AllDirectories).FirstOrDefault();
                if (string.IsNullOrWhiteSpace(sourceExe))
                {
                    throw new InvalidOperationException("The server update ZIP did not contain Windows\\Clipman Server.exe.");
                }

                CopyFileWithRetry(sourceExe, exePath);
                TryDeleteDirectory(root);
                Process.Start(new ProcessStartInfo
                {
                    FileName = exePath,
                    WorkingDirectory = Path.GetDirectoryName(exePath),
                    UseShellExecute = true
                });
            }
            catch (Exception ex)
            {
                MessageBox.Show("Clipman Server update failed:" + Environment.NewLine + Environment.NewLine + ex.Message, "Clipman Server updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private static GitHubRelease LatestRelease()
        {
            using (var client = GitHubClient())
            {
                var json = client.DownloadString(ProjectUrl.Replace("https://github.com/", "https://api.github.com/repos/") + "/releases?per_page=20");
                var rows = new JavaScriptSerializer().DeserializeObject(json) as object[];
                return (rows ?? new object[0])
                    .Select(ParseRelease)
                    .Where(r => r != null && VersionText(r.TagName).Length > 0)
                    .OrderByDescending(r => ParsedVersion(r.TagName))
                    .FirstOrDefault();
            }
        }

        private static GitHubRelease ParseRelease(object value)
        {
            var map = value as System.Collections.Generic.Dictionary<string, object>;
            if (map == null) return null;
            var release = new GitHubRelease
            {
                TagName = GetString(map, "tag_name"),
                Assets = new System.Collections.Generic.List<GitHubAsset>()
            };
            object assetsObject;
            if (map.TryGetValue("assets", out assetsObject))
            {
                var rows = assetsObject as object[];
                foreach (var row in rows ?? new object[0])
                {
                    var asset = row as System.Collections.Generic.Dictionary<string, object>;
                    if (asset == null) continue;
                    release.Assets.Add(new GitHubAsset
                    {
                        Name = GetString(asset, "name"),
                        BrowserDownloadUrl = GetString(asset, "browser_download_url")
                    });
                }
            }
            return release;
        }

        private static GitHubAsset FindServerAsset(GitHubRelease release)
        {
            return release == null || release.Assets == null
                ? null
                : release.Assets.FirstOrDefault(a =>
                    a != null &&
                    !string.IsNullOrWhiteSpace(a.BrowserDownloadUrl) &&
                    !string.IsNullOrWhiteSpace(a.Name) &&
                    a.Name.StartsWith("ClipmanServer-", StringComparison.OrdinalIgnoreCase) &&
                    a.Name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase));
        }

        private static WebClient GitHubClient()
        {
            ServicePointManager.SecurityProtocol |= (SecurityProtocolType)3072;
            var client = new WebClient();
            client.Headers.Add("User-Agent", UserAgent);
            return client;
        }

        private static void DownloadFile(string url, string destination)
        {
            using (var client = GitHubClient())
            {
                client.DownloadFile(url, destination);
            }
        }

        private static string CurrentVersion()
        {
            var version = Assembly.GetExecutingAssembly().GetCustomAttributes(typeof(AssemblyInformationalVersionAttribute), false)
                .OfType<AssemblyInformationalVersionAttribute>()
                .Select(a => a.InformationalVersion)
                .FirstOrDefault();
            return string.IsNullOrWhiteSpace(version) ? "0.0.0" : version;
        }

        private static string VersionText(string tagName)
        {
            return (tagName ?? string.Empty).Trim().TrimStart('v', 'V');
        }

        private static Version ParsedVersion(string tagName)
        {
            Version version;
            return Version.TryParse(VersionText(tagName), out version) ? version : new Version(0, 0);
        }

        private static string GetString(System.Collections.Generic.Dictionary<string, object> map, string key)
        {
            object value;
            return map != null && map.TryGetValue(key, out value) && value != null ? Convert.ToString(value) : string.Empty;
        }

        private static bool HasArg(string[] args, string name)
        {
            return args.Any(arg => string.Equals(arg, name, StringComparison.OrdinalIgnoreCase));
        }

        private static bool TryGetOptionValue(string[] args, string option, out string value)
        {
            value = string.Empty;
            for (var i = 0; i < args.Length - 1; i++)
            {
                if (string.Equals(args[i], option, StringComparison.OrdinalIgnoreCase))
                {
                    value = args[i + 1];
                    return true;
                }
            }
            return false;
        }

        private static void WaitForProcessExit(int processId)
        {
            try
            {
                using (var process = Process.GetProcessById(processId))
                {
                    process.WaitForExit(30000);
                }
            }
            catch
            {
            }
        }

        private static void CopyFileWithRetry(string source, string destination)
        {
            Exception last = null;
            for (var attempt = 0; attempt < 30; attempt++)
            {
                try
                {
                    File.Copy(source, destination, true);
                    return;
                }
                catch (Exception ex)
                {
                    last = ex;
                    Thread.Sleep(1000);
                }
            }
            throw new IOException("Could not replace " + destination + " after waiting for the server wrapper to close.", last);
        }

        private static void TryDeleteDirectory(string path)
        {
            try
            {
                if (Directory.Exists(path)) Directory.Delete(path, true);
            }
            catch
            {
            }
        }

        private static string Quote(string value)
        {
            return "\"" + (value ?? string.Empty).Replace("\"", "\\\"") + "\"";
        }

        private sealed class GitHubRelease
        {
            public string TagName { get; set; }
            public System.Collections.Generic.List<GitHubAsset> Assets { get; set; }
        }

        private sealed class GitHubAsset
        {
            public string Name { get; set; }
            public string BrowserDownloadUrl { get; set; }
        }
    }
}
