using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
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
        private const string PreferencesRegistryPath = @"Software\Clipman Server";
        private const string AutomaticUpdatesValueName = "AutomaticUpdates";
        private const int BindErrorExitCode = 20;
        private readonly string appDirectory;
        private readonly string scriptPath;
        private readonly string settingsDirectory;
        private readonly string settingsPath;
        private readonly string logDirectory;
        private readonly string wrapperLogPath;
        private readonly NotifyIcon tray;
        private readonly SynchronizationContext uiContext;
        private Process serverProcess;
        private Process certificateShareProcess;
        private System.Windows.Forms.Timer restartTimer;
        private System.Windows.Forms.Timer automaticUpdateTimer;
        private int unexpectedRestartCount;
        private DateTime serverStartedUtc;
        private bool stoppingServer;
        private bool quitting;
        private string statusOverride;

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
            uiContext = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();

            tray = new NotifyIcon
            {
                Icon = SystemIcons.Application,
                Text = "Clipman Server: starting",
                Visible = true,
                ContextMenuStrip = BuildMenu()
            };

            StartServer();
            ScheduleAutomaticUpdateCheck(TimeSpan.FromMinutes(1));
        }

        private ContextMenuStrip BuildMenu()
        {
            var menu = new ContextMenuStrip();
            menu.Opening += delegate
            {
                menu.Items.Clear();
                menu.Items.Add("Clipman Server: " + StatusText()).Enabled = false;
                menu.Items.Add("Copy connection details", null, delegate { CopyConnectionDetails(); });
                menu.Items.Add("Create temporary setup link", null, delegate { CreateTemporarySetupLink(); });
                var revokeSetup = new ToolStripMenuItem("Revoke temporary setup link", null, delegate { RevokeTemporarySetupLink(); });
                revokeSetup.Enabled = File.Exists(Path.Combine(settingsDirectory, "clipman-server-setup-link.json"));
                menu.Items.Add(revokeSetup);
                menu.Items.Add("Change listening port...", null, delegate { ChangeListeningPort(); });
                menu.Items.Add("Create or renew HTTPS certificate", null, delegate { CreateHttpsCertificate(); });
                menu.Items.Add("Copy authority fingerprint", null, delegate { CopyAuthorityFingerprint(); });
                menu.Items.Add("Share certificate authority", null, delegate { ShareCertificateAuthority(); });
                menu.Items.Add("Open settings folder", null, delegate { OpenFolder(settingsDirectory); });
                menu.Items.Add("Open logs folder", null, delegate { OpenFolder(logDirectory); });
                menu.Items.Add("Check for updates", null, delegate { ServerUpdateService.CheckForUpdates(null, false, ExitThread); });
                var automaticUpdates = new ToolStripMenuItem("Install updates automatically") { Checked = AreAutomaticUpdatesEnabled(), CheckOnClick = false };
                automaticUpdates.Click += delegate { SetAutomaticUpdatesEnabled(!AreAutomaticUpdatesEnabled()); };
                menu.Items.Add(automaticUpdates);
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
            if (!string.IsNullOrWhiteSpace(statusOverride))
            {
                return statusOverride;
            }
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
            if (serverProcess != null && StatusText() == "running")
            {
                return;
            }
            stoppingServer = false;
            statusOverride = null;
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

            var process = new Process { StartInfo = start, EnableRaisingEvents = true };
            process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { LogLine(e.Data); };
            process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { LogLine(e.Data); };
            process.Exited += delegate
            {
                HandleUnexpectedServerExit(process);
            };
            serverProcess = process;

            try
            {
                process.Start();
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                serverStartedUtc = DateTime.UtcNow;
                tray.Text = "Clipman Server: running";
                tray.ShowBalloonTip(2500, "Clipman Server", "Server started in the background.", ToolTipIcon.Info);
            }
            catch (Exception ex)
            {
                LogLine(ex.ToString());
                try { process.Dispose(); } catch { }
                if (serverProcess == process) serverProcess = null;
                tray.Text = "Clipman Server: error";
                tray.ShowBalloonTip(5000, "Clipman Server", ex.Message, ToolTipIcon.Error);
            }
        }

        private void RestartServer()
        {
            unexpectedRestartCount = 0;
            StopServer();
            StartServer();
        }

        private void StopServer()
        {
            stoppingServer = true;
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

        private void HandleUnexpectedServerExit(Process process)
        {
            int exitCode;
            try { exitCode = process.ExitCode; }
            catch { exitCode = -1; }
            uiContext.Post(delegate
            {
                if (quitting || stoppingServer || serverProcess != process)
                {
                    return;
                }
                try { process.Dispose(); } catch { }
                serverProcess = null;
                if (exitCode == BindErrorExitCode)
                {
                    statusOverride = "port unavailable";
                    tray.Text = "Clipman Server: port unavailable";
                    tray.ShowBalloonTip(
                        8000,
                        "Clipman Server",
                        "The listening port is unavailable. Choose Change listening port from this menu; existing settings and databases are unchanged.",
                        ToolTipIcon.Error);
                    return;
                }
                tray.Text = "Clipman Server: stopped";
                if (serverStartedUtc != default(DateTime) && DateTime.UtcNow - serverStartedUtc >= TimeSpan.FromMinutes(1))
                {
                    unexpectedRestartCount = 0;
                }
                unexpectedRestartCount++;
                if (unexpectedRestartCount > 3)
                {
                    tray.ShowBalloonTip(5000, "Clipman Server", "The server stopped repeatedly. Open the logs folder for details.", ToolTipIcon.Error);
                    return;
                }
                tray.ShowBalloonTip(3000, "Clipman Server", "The server stopped unexpectedly. Restarting in 5 seconds.", ToolTipIcon.Warning);
                if (restartTimer != null)
                {
                    restartTimer.Stop();
                    restartTimer.Dispose();
                }
                restartTimer = new System.Windows.Forms.Timer { Interval = 5000 };
                restartTimer.Tick += delegate
                {
                    restartTimer.Stop();
                    restartTimer.Dispose();
                    restartTimer = null;
                    StartServer();
                };
                restartTimer.Start();
            }, null);
        }

        private void ChangeListeningPort()
        {
            var suggestion = RunPythonUtility("--suggest-port", 10000);
            int suggestedPort;
            if (!suggestion.Succeeded || !int.TryParse(suggestion.Output.Trim(), out suggestedPort))
            {
                MessageBox.Show(suggestion.Output, "Change Listening Port", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            using (var dialog = new ListeningPortDialog(suggestedPort))
            {
                if (dialog.ShowDialog() != DialogResult.OK)
                {
                    return;
                }

                StopServer();
                var result = RunPythonUtility("--port " + dialog.SelectedPort + " --write-connection-info", 30000);
                if (!result.Succeeded)
                {
                    MessageBox.Show(result.Output, "Change Listening Port", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    StartServer();
                    return;
                }

                unexpectedRestartCount = 0;
                StartServer();
                MessageBox.Show(
                    "Clipman Server now uses port " + dialog.SelectedPort + "." + Environment.NewLine + Environment.NewLine +
                    "Update the server address on each Clipman client, or import the refreshed connection file from the server settings folder.",
                    "Change Listening Port",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
            }
        }

        private void CreateHttpsCertificate()
        {
            tray.ShowBalloonTip(2500, "Clipman Server", "Checking network addresses for the HTTPS certificate.", ToolTipIcon.Info);
            ThreadPool.QueueUserWorkItem(delegate
            {
                var detected = RunPythonUtility("--list-certificate-ips", 10000);
                uiContext.Post(delegate
                {
                    if (!detected.Succeeded)
                    {
                        LogLine(detected.Output);
                        MessageBox.Show(detected.Output, "Clipman Server HTTPS", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return;
                    }
                    var addresses = detected.Output
                        .Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries)
                        .Select(value => value.Trim())
                        .Where(value => { IPAddress parsed; return IPAddress.TryParse(value, out parsed); })
                        .Distinct(StringComparer.OrdinalIgnoreCase)
                        .ToArray();
                    using (var dialog = new CertificateOptionsDialog(addresses))
                    {
                        if (dialog.ShowDialog() != DialogResult.OK) return;
                        BeginHttpsCertificateGeneration(dialog.SelectedAddresses, dialog.AdditionalHostnames);
                    }
                }, null);
            });
        }

        private void BeginHttpsCertificateGeneration(IEnumerable<string> addresses, IEnumerable<string> hostnames)
        {
            var arguments = new StringBuilder("--create-tls-certificate");
            foreach (var address in addresses) arguments.Append(" --cert-ip ").Append(Quote(address));
            foreach (var hostname in hostnames) arguments.Append(" --cert-host ").Append(Quote(hostname));
            tray.ShowBalloonTip(2500, "Clipman Server", "Creating the HTTPS certificate.", ToolTipIcon.Info);
            ThreadPool.QueueUserWorkItem(delegate
            {
                var result = RunPythonUtility(arguments.ToString(), 120000);
                uiContext.Post(delegate
                {
                    if (!result.Succeeded)
                    {
                        LogLine(result.Output);
                        MessageBox.Show(result.Output, "Clipman Server HTTPS", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return;
                    }
                    RestartServer();
                    MessageBox.Show(
                        result.Output + Environment.NewLine + Environment.NewLine +
                        "Import the refreshed .clpconf file in current Clipman clients. It carries the public authority for app-specific trust. Older clients may still require Share certificate authority and operating-system trust.",
                        "Clipman Server HTTPS",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information);
                }, null);
            });
        }

        private void CopyAuthorityFingerprint()
        {
            ThreadPool.QueueUserWorkItem(delegate
            {
                var result = RunPythonUtility("--show-ca-fingerprint", 10000);
                uiContext.Post(delegate
                {
                    if (!result.Succeeded || string.IsNullOrWhiteSpace(result.Output))
                    {
                        MessageBox.Show(result.Output, "Authority Fingerprint", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return;
                    }
                    Clipboard.SetText(result.Output.Trim());
                    tray.ShowBalloonTip(3000, "Clipman Server", "Authority SHA-256 fingerprint copied.", ToolTipIcon.Info);
                }, null);
            });
        }

        private void ShareCertificateAuthority()
        {
            if (certificateShareProcess != null)
            {
                try
                {
                    if (!certificateShareProcess.HasExited)
                    {
                        tray.ShowBalloonTip(3000, "Clipman Server", "The certificate authority is already being shared.", ToolTipIcon.Info);
                        return;
                    }
                }
                catch { }
            }
            ThreadPool.QueueUserWorkItem(delegate
            {
                var python = FindPythonLauncher();
                if (python == null)
                {
                    uiContext.Post(delegate { MessageBox.Show("Python 3 was not found.", "Clipman Server", MessageBoxButtons.OK, MessageBoxIcon.Error); }, null);
                    return;
                }
                var start = CreatePythonStartInfo(python, "--share-ca");
                var process = new Process { StartInfo = start };
                certificateShareProcess = process;
                try
                {
                    process.Start();
                    var urlLine = process.StandardOutput.ReadLine() ?? "";
                    var fingerprintLine = process.StandardOutput.ReadLine() ?? "";
                    var limitLine = process.StandardOutput.ReadLine() ?? "";
                    if (!urlLine.StartsWith("Certificate URL: ", StringComparison.Ordinal))
                    {
                        var error = process.StandardError.ReadToEnd();
                        throw new InvalidOperationException(string.IsNullOrWhiteSpace(error) ? "The certificate sharing service did not start." : error.Trim());
                    }
                    var url = urlLine.Substring("Certificate URL: ".Length);
                    uiContext.Post(delegate
                    {
                        Clipboard.SetText(url);
                        MessageBox.Show(
                            urlLine + Environment.NewLine + fingerprintLine + Environment.NewLine + limitLine + Environment.NewLine + Environment.NewLine +
                            "The URL has been copied to the clipboard.",
                            "Share Certificate Authority",
                            MessageBoxButtons.OK,
                            MessageBoxIcon.Information);
                    }, null);
                    process.WaitForExit();
                    var remainder = process.StandardOutput.ReadToEnd();
                    if (!string.IsNullOrWhiteSpace(remainder)) LogLine(remainder.Trim());
                }
                catch (Exception ex)
                {
                    LogLine(ex.ToString());
                    uiContext.Post(delegate { MessageBox.Show(ex.Message, "Share Certificate Authority", MessageBoxButtons.OK, MessageBoxIcon.Error); }, null);
                }
                finally
                {
                    try { process.Dispose(); } catch { }
                    if (certificateShareProcess == process) certificateShareProcess = null;
                }
            });
        }

        private CommandResult RunPythonUtility(string arguments, int timeoutMilliseconds)
        {
            var python = FindPythonLauncher();
            if (python == null) return new CommandResult(false, "Python 3 was not found.");
            using (var process = new Process { StartInfo = CreatePythonStartInfo(python, arguments) })
            {
                process.Start();
                var output = process.StandardOutput.ReadToEnd();
                var error = process.StandardError.ReadToEnd();
                if (!process.WaitForExit(timeoutMilliseconds))
                {
                    try { process.Kill(); } catch { }
                    return new CommandResult(false, "The operation did not finish before the time limit.");
                }
                var combined = string.Join(Environment.NewLine, new[] { output.Trim(), error.Trim() }.Where(value => !string.IsNullOrWhiteSpace(value)));
                return new CommandResult(process.ExitCode == 0, string.IsNullOrWhiteSpace(combined) ? "The operation completed." : combined);
            }
        }

        private void CreateTemporarySetupLink()
        {
            ThreadPool.QueueUserWorkItem(delegate
            {
                var result = RunPythonUtility("--create-setup-link --setup-minutes 30 --setup-downloads 5", 30000);
                uiContext.Post(delegate
                {
                    if (!result.Succeeded)
                    {
                        MessageBox.Show(result.Output, "Temporary Setup Link", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return;
                    }
                    var urlLine = result.Output.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries)
                        .FirstOrDefault(line => line.StartsWith("Setup URL: ", StringComparison.Ordinal));
                    if (string.IsNullOrWhiteSpace(urlLine))
                    {
                        MessageBox.Show("Clipman Server did not return a setup URL.", "Temporary Setup Link", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return;
                    }
                    var url = urlLine.Substring("Setup URL: ".Length).Trim();
                    Clipboard.SetText(url);
                    try
                    {
                        Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
                    }
                    catch (Exception ex)
                    {
                        LogLine(ex.ToString());
                    }
                    MessageBox.Show(
                        result.Output + Environment.NewLine + Environment.NewLine +
                        "The URL has been copied and opened in your browser. Revoke it from this menu when onboarding is complete.",
                        "Temporary Setup Link",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information);
                }, null);
            });
        }

        private void RevokeTemporarySetupLink()
        {
            ThreadPool.QueueUserWorkItem(delegate
            {
                var result = RunPythonUtility("--revoke-setup-link", 10000);
                uiContext.Post(delegate
                {
                    if (!result.Succeeded)
                    {
                        MessageBox.Show(result.Output, "Temporary Setup Link", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return;
                    }
                    tray.ShowBalloonTip(3000, "Clipman Server", result.Output.Trim(), ToolTipIcon.Info);
                }, null);
            });
        }

        private ProcessStartInfo CreatePythonStartInfo(PythonLauncher python, string arguments)
        {
            return new ProcessStartInfo
            {
                FileName = python.FileName,
                Arguments = python.ArgumentsPrefix + Quote(scriptPath) + " --config " + Quote(settingsPath) + " " + arguments,
                WorkingDirectory = appDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            };
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

        private bool AreAutomaticUpdatesEnabled()
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(PreferencesRegistryPath, false))
                {
                    var value = key == null ? null : key.GetValue(AutomaticUpdatesValueName);
                    return value == null || Convert.ToInt32(value) != 0;
                }
            }
            catch { return true; }
        }

        private void SetAutomaticUpdatesEnabled(bool enabled)
        {
            using (var key = Registry.CurrentUser.CreateSubKey(PreferencesRegistryPath))
            {
                key.SetValue(AutomaticUpdatesValueName, enabled ? 1 : 0, RegistryValueKind.DWord);
            }

            if (enabled)
            {
                ScheduleAutomaticUpdateCheck(TimeSpan.FromMinutes(1));
                tray.ShowBalloonTip(2000, "Clipman Server", "Automatic server updates enabled.", ToolTipIcon.Info);
            }
            else
            {
                StopAutomaticUpdateTimer();
                tray.ShowBalloonTip(2000, "Clipman Server", "Automatic server updates disabled.", ToolTipIcon.Info);
            }
        }

        private void ScheduleAutomaticUpdateCheck(TimeSpan delay)
        {
            StopAutomaticUpdateTimer();
            if (!AreAutomaticUpdatesEnabled())
            {
                return;
            }

            automaticUpdateTimer = new System.Windows.Forms.Timer
            {
                Interval = (int)Math.Min(int.MaxValue, Math.Max(1000, delay.TotalMilliseconds))
            };
            automaticUpdateTimer.Tick += delegate
            {
                StopAutomaticUpdateTimer();
                ScheduleAutomaticUpdateCheck(TimeSpan.FromDays(1));
                ThreadPool.QueueUserWorkItem(delegate
                {
                    ServerUpdateService.CheckForUpdates(null, true, delegate
                    {
                        uiContext.Post(delegate { ExitThread(); }, null);
                    });
                });
            };
            automaticUpdateTimer.Start();
        }

        private void StopAutomaticUpdateTimer()
        {
            if (automaticUpdateTimer == null)
            {
                return;
            }
            automaticUpdateTimer.Stop();
            automaticUpdateTimer.Dispose();
            automaticUpdateTimer = null;
        }

        private static PythonLauncher FindPythonLauncher()
        {
            var candidates = new[]
            {
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

            try
            {
                var locate = new ProcessStartInfo
                {
                    FileName = "py.exe",
                    Arguments = "-3 -c \"import sys;print(sys.executable)\"",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };
                using (var process = Process.Start(locate))
                {
                    var executable = process.StandardOutput.ReadToEnd().Trim();
                    process.WaitForExit(5000);
                    if (process.ExitCode == 0 && File.Exists(executable))
                    {
                        return new PythonLauncher(executable, "");
                    }
                }
            }
            catch { }

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
            if (restartTimer != null)
            {
                restartTimer.Stop();
                restartTimer.Dispose();
            }
            StopAutomaticUpdateTimer();
            if (certificateShareProcess != null)
            {
                try { if (!certificateShareProcess.HasExited) certificateShareProcess.Kill(); } catch { }
            }
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

    internal sealed class CommandResult
    {
        public bool Succeeded { get; private set; }
        public string Output { get; private set; }

        public CommandResult(bool succeeded, string output)
        {
            Succeeded = succeeded;
            Output = output;
        }
    }

    internal sealed class ListeningPortDialog : Form
    {
        private readonly NumericUpDown portField;

        public int SelectedPort { get { return Decimal.ToInt32(portField.Value); } }

        public ListeningPortDialog(int suggestedPort)
        {
            Text = "Change Listening Port";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = false;
            ClientSize = new Size(390, 150);

            var explanation = new Label
            {
                AutoSize = false,
                Location = new Point(12, 12),
                Size = new Size(366, 45),
                Text = "Choose an available port. Clipman will preserve server settings and databases."
            };
            var label = new Label { AutoSize = true, Location = new Point(12, 68), Text = "&Listening port:" };
            portField = new NumericUpDown
            {
                Location = new Point(120, 65),
                Size = new Size(120, 24),
                Minimum = 1024,
                Maximum = 49151,
                Value = Math.Max(1024, Math.Min(49151, suggestedPort))
            };
            label.UseMnemonic = true;
            var save = new Button
            {
                Text = "&Save and Restart",
                DialogResult = DialogResult.OK,
                Location = new Point(160, 108),
                Size = new Size(110, 30)
            };
            var cancel = new Button
            {
                Text = "Ca&ncel",
                DialogResult = DialogResult.Cancel,
                Location = new Point(278, 108),
                Size = new Size(100, 30)
            };
            AcceptButton = save;
            CancelButton = cancel;
            Controls.AddRange(new Control[] { explanation, label, portField, save, cancel });
            Shown += delegate { portField.Focus(); portField.Select(0, portField.Text.Length); };
        }
    }

    internal sealed class CertificateOptionsDialog : Form
    {
        private readonly CheckedListBox addressList;
        private readonly TextBox hostnameField;
        private string[] additionalHostnames = new string[0];

        public IEnumerable<string> SelectedAddresses
        {
            get { return addressList.CheckedItems.Cast<string>().ToArray(); }
        }

        public IEnumerable<string> AdditionalHostnames { get { return additionalHostnames; } }

        public CertificateOptionsDialog(IEnumerable<string> detectedAddresses)
        {
            Text = "Create HTTPS Certificate";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = false;
            ClientSize = new Size(560, 390);

            var explanation = new Label
            {
                AutoSize = false,
                Location = new Point(12, 12),
                Size = new Size(536, 48),
                Text = "Choose the detected addresses clients may use. Localhost, configured addresses, and the computer name are included automatically."
            };
            var addressesLabel = new Label { AutoSize = true, Location = new Point(12, 68), Text = "Detected &IP addresses:" };
            addressList = new CheckedListBox
            {
                Location = new Point(12, 91),
                Size = new Size(536, 170),
                CheckOnClick = true,
                AccessibleName = "Detected IP addresses"
            };
            foreach (var address in detectedAddresses)
            {
                addressList.Items.Add(address, true);
            }
            var hostnamesLabel = new Label { AutoSize = true, Location = new Point(12, 276), Text = "Additional &hostnames, comma-separated:" };
            hostnameField = new TextBox
            {
                Location = new Point(12, 299),
                Size = new Size(536, 24),
                AccessibleName = "Additional hostnames, comma-separated"
            };
            var save = new Button
            {
                Text = "&Create Certificate",
                Location = new Point(300, 342),
                Size = new Size(130, 32)
            };
            var cancel = new Button
            {
                Text = "&Cancel",
                DialogResult = DialogResult.Cancel,
                Location = new Point(438, 342),
                Size = new Size(110, 32)
            };
            save.Click += delegate
            {
                var values = hostnameField.Text
                    .Split(new[] { ',', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
                    .Select(value => value.Trim().TrimEnd('.'))
                    .Where(value => value.Length > 0)
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .ToArray();
                var invalid = values.FirstOrDefault(value =>
                    value.Length > 253 || value.Split('.').Any(label =>
                        label.Length == 0 || label.Length > 63 || !Regex.IsMatch(label, @"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$")));
                if (invalid != null)
                {
                    MessageBox.Show(this, "Invalid hostname: " + invalid, "Create HTTPS Certificate", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    hostnameField.Focus();
                    return;
                }
                additionalHostnames = values;
                DialogResult = DialogResult.OK;
                Close();
            };
            AcceptButton = save;
            CancelButton = cancel;
            Controls.AddRange(new Control[] { explanation, addressesLabel, addressList, hostnamesLabel, hostnameField, save, cancel });
            Shown += delegate { addressList.Focus(); };
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
                if (release == null)
                {
                    if (!installSilently) MessageBox.Show(owner, "Could not find a stable Clipman Server release.", "Clipman Server updates", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                var remoteText = VersionText(release.TagName);
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

                var asset = FindServerAsset(release, remoteText);
                if (asset == null || string.IsNullOrWhiteSpace(asset.BrowserDownloadUrl))
                {
                    if (!installSilently) MessageBox.Show(owner, "Clipman Server " + remote + " is available, but no ClipmanServer ZIP asset was found.", "Clipman Server updates", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                if (!IsValidSha256Digest(asset.Digest))
                {
                    if (!installSilently) MessageBox.Show(owner, "Clipman Server " + remote + " is available, but its ZIP does not have a valid GitHub SHA-256 digest.", "Clipman Server updates", MessageBoxButtons.OK, MessageBoxIcon.Information);
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

                StartUpdate(asset.BrowserDownloadUrl, asset.Digest, exitApp);
            }
            catch (Exception ex)
            {
                if (!installSilently)
                {
                    MessageBox.Show(owner, "Could not check for Clipman Server updates." + Environment.NewLine + Environment.NewLine + ex.Message, "Clipman Server updates", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
            }
        }

        private static void StartUpdate(string zipUrl, string expectedDigest, Action exitApp)
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
                    " --update-digest " + Quote(expectedDigest) +
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
            string expectedDigest;
            string exePath;
            string pidText;
            TryGetOptionValue(args, "--update-url", out zipUrl);
            TryGetOptionValue(args, "--update-digest", out expectedDigest);
            TryGetOptionValue(args, "--update-exe", out exePath);
            TryGetOptionValue(args, "--update-wait-pid", out pidText);

            try
            {
                if (string.IsNullOrWhiteSpace(zipUrl) || string.IsNullOrWhiteSpace(exePath) || !IsValidSha256Digest(expectedDigest))
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
                VerifySha256Digest(zip, expectedDigest);
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
                    .Where(r => r != null && !r.Draft && !r.Prerelease && VersionText(r.TagName).Length > 0)
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
                Draft = GetBoolean(map, "draft"),
                Prerelease = GetBoolean(map, "prerelease"),
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
                        BrowserDownloadUrl = GetString(asset, "browser_download_url"),
                        Digest = GetString(asset, "digest")
                    });
                }
            }
            return release;
        }

        private static GitHubAsset FindServerAsset(GitHubRelease release, string version)
        {
            var expectedName = "ClipmanServer-" + version + ".zip";
            return release == null || release.Assets == null
                ? null
                : release.Assets.FirstOrDefault(a =>
                    a != null &&
                    !string.IsNullOrWhiteSpace(a.BrowserDownloadUrl) &&
                    string.Equals(a.Name, expectedName, StringComparison.OrdinalIgnoreCase));
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

        private static bool IsValidSha256Digest(string digest)
        {
            var value = (digest ?? string.Empty).Trim();
            if (!value.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase) || value.Length != 71)
            {
                return false;
            }
            return value.Substring(7).All(Uri.IsHexDigit);
        }

        private static void VerifySha256Digest(string path, string expectedDigest)
        {
            if (!IsValidSha256Digest(expectedDigest))
            {
                throw new InvalidDataException("GitHub did not provide a valid SHA-256 digest for the server update.");
            }
            string actual;
            using (var stream = File.OpenRead(path))
            using (var sha256 = SHA256.Create())
            {
                actual = "sha256:" + BitConverter.ToString(sha256.ComputeHash(stream)).Replace("-", string.Empty).ToLowerInvariant();
            }
            if (!string.Equals(actual, expectedDigest.Trim(), StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("The downloaded server update failed its SHA-256 check.");
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
            var value = (tagName ?? string.Empty).Trim();
            const string prefix = "server-v";
            if (!value.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                return string.Empty;
            }
            var version = value.Substring(prefix.Length);
            Version parsed;
            return Version.TryParse(version, out parsed) ? version : string.Empty;
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

        private static bool GetBoolean(System.Collections.Generic.Dictionary<string, object> map, string key)
        {
            object value;
            return map != null && map.TryGetValue(key, out value) && value != null && Convert.ToBoolean(value);
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
            public bool Draft { get; set; }
            public bool Prerelease { get; set; }
            public System.Collections.Generic.List<GitHubAsset> Assets { get; set; }
        }

        private sealed class GitHubAsset
        {
            public string Name { get; set; }
            public string BrowserDownloadUrl { get; set; }
            public string Digest { get; set; }
        }
    }
}
